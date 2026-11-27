import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Security
import FrameNoteCore

enum OpenAIKeyStore {
    private static let service = "dev.framenote.openai"
    private static let account = "design-assistant"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}

enum DesignerAssistantError: LocalizedError {
    case missingEvidence, invalidResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .missingEvidence: "Could not extract the selected image or video frames."
        case .invalidResponse: "The design assistant returned an unreadable response."
        case .server(let message): message
        }
    }
}

enum DesignerAssistant {
    private static let model = "gpt-5"
    typealias SendRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static func analyze(key: String, screenshot: CGImage?, videoURL: URL?,
                        start: Double?, end: Double?, duration: Double,
                        focus: CGRect?, note: String,
                        inspirations: [InspirationAttachment],
                        connection: AIConnection? = nil,
                        send: @escaping SendRequest = { try await URLSession.shared.data(for: $0) }) async throws -> String {
        let evidence = try await evidenceImages(screenshot: screenshot, videoURL: videoURL,
                                                start: start, end: end, duration: duration,
                                                inspirations: inspirations)
        guard !evidence.isEmpty else { throw DesignerAssistantError.missingEvidence }
        let focusDescription = focus.map {
            "Selected rectangle: x=\(Int($0.minX * 100))%, y=\(Int($0.minY * 100))%, width=\(Int($0.width * 100))%, height=\(Int($0.height * 100))%."
        } ?? "The user selected a point or a whole interaction."
        let interval = start.map { "Start \(String(format: "%.2f", $0))s, end \(String(format: "%.2f", end ?? $0))s." } ?? "Still image."
        let links = inspirations.filter { $0.kind == .url }.map(\.value).joined(separator: "\n")
        let context = "Review a UI interaction. \(focusDescription) \(interval) User note: \(note.isEmpty ? "They feel something is wrong but cannot yet explain it." : note) Inspiration URLs: \(links.isEmpty ? "none" : links). Frames are labeled with their timestamps. Do not claim to have opened URLs; use them as context only. Ground findings in visible evidence and mark uncertainty."
        if let connection {
            return try await response(key: key, prompt: "Assess interaction clarity, visual hierarchy, spacing, and motion together. Give a concise response with headings: What feels off, Evidence, Suggested changes, Visual suggestion. Suggest 2 or 3 concrete changes grounded in visible evidence. Describe a layout or 3 keyframes in words. If only one frame is present, say motion cannot be judged. " + context,
                                      images: evidence, connection: connection, send: send)
        }
        let perspectives: [(String, String)] = [
            ("Interaction clarity", "Assess the selected interaction's purpose, discoverability, feedback, and extra steps. Identify specific visible moments. Return up to 3 observations and actionable changes."),
            ("Motion", "Assess timing, continuity, spatial movement, easing cues, and the opening or collapse transition. Compare the timestamped frames. Return up to 3 observations and actionable changes. If only one frame is present, say motion cannot be judged."),
            ("Visual design", "Assess hierarchy, spacing, affordances, and consistency in the selected area. Suggest a simple visual alternative or 3-frame storyboard in words. Return up to 3 observations and changes.")
        ]
        var reports = Array(repeating: "", count: perspectives.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, perspective) in perspectives.enumerated() {
                group.addTask {
                    let answer = try await response(key: key, prompt: "You are the \(perspective.0) reviewer. \(perspective.1) \(context)", images: evidence, send: send)
                    return (index, answer)
                }
            }
            for try await (index, answer) in group { reports[index] = answer }
        }
        let synthesis = "Combine these independent UI reviews into a concise, useful response for someone who has trouble explaining what feels wrong. Use headings: What feels off, Evidence, Suggested changes, Visual suggestion. Give 2 or 3 concrete changes. State uncertainty. The visual suggestion should describe a layout or 3 keyframes that a designer can draw. Do not repeat points.\n\n" + zip(perspectives, reports).map { "\($0.0.0):\n\($0.1)" }.joined(separator: "\n\n")
        return try await response(key: key, prompt: synthesis, images: [], send: send)
    }

    static func analyzeWhole(key: String, screenshot: CGImage?, videoURL: URL?, duration: Double,
                             note: String, connection: AIConnection? = nil, send: @escaping SendRequest = { try await URLSession.shared.data(for: $0) }) async throws -> WholeReviewAnalysis {
        let evidence = try await evidenceImages(screenshot: screenshot, videoURL: videoURL,
            start: 0, end: duration, duration: duration, inspirations: [], sampleCount: 24)
        guard !evidence.isEmpty else { throw DesignerAssistantError.missingEvidence }
        let prompt = """
        Create an implementation brief that a coding agent can follow to recreate or adapt this UI reference. User goal: \(note)
        The evidence contains ordered, timestamped sampled frames covering the whole clip, or a still image.
        Identify the visible interaction sequence, state changes, hierarchy, and motion. Distinguish an inspiration to learn from from a UI defect to fix. Explain what to adapt and why. For each useful observation, suggest a concrete next step.
        Ground every finding in evidence. These are sampled still frames, not continuous video or audio. Do not invent clicks, exact easing, exact motion durations, hidden states, or source code. Acknowledge transitions missed between samples.
        Return ONLY a JSON object: {"summary":"Markdown sections: Build, Layout and styling, Interaction states, Motion sequence, Acceptance checks. Give concrete implementation instructions, separating observed evidence from estimates","findings":[{"note":"Observation, evidence, and actionable suggestion","startTime":0.0,"endTime":1.0,"rect":[0.1,0.2,0.3,0.4]}]}.
        Use up to 6 findings. Video timestamps must be within 0...\(duration) seconds and supported by the labeled frames. For a still image, omit timestamps. The optional rect is x,y,width,height normalized to 0...1 from the top-left; omit it if the location is uncertain. Omit endTime unless a visible interval supports it. For video, keep unlocated observations in the summary. All JSON strings must escape newlines.
        """
        let result = try await response(key: key, prompt: prompt, images: evidence, connection: connection, send: send)
        let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        guard let data = cleaned.data(using: .utf8), let report = try? JSONDecoder().decode(WholeReviewAnalysis.self, from: data),
              !report.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DesignerAssistantError.invalidResponse }
        return report
    }

    private static func evidenceImages(screenshot: CGImage?, videoURL: URL?,
                                       start: Double?, end: Double?, duration: Double,
                                       inspirations: [InspirationAttachment], sampleCount: Int = 4) async throws -> [(String, Data)] {
        try await Task.detached(priority: .userInitiated) { () async throws -> [(String, Data)] in
            var images: [(String, Data)] = []
            if let screenshot { images.append(("Current screenshot", try jpeg(screenshot))) }
            if let videoURL {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1280, height: 1280)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let safeEnd = max(0, duration - 0.01)
                let first = min(max(0, start ?? 0), safeEnd)
                let last = min(safeEnd, max(first, end ?? min(safeEnd, first + 2)))
                let count = min(24, max(4, sampleCount))
                let times = last - first < 0.05 ? [first] : (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
                var seenTimes = Set<Int64>()
                for time in times {
                    try Task.checkCancellation()
                    let frame = try VideoEvidence.frame(from: generator, at: CMTime(seconds: time, preferredTimescale: 60000))
                    guard seenTimes.insert(frame.time.convertScale(60000, method: .default).value).inserted else { continue }
                    images.append((String(format: "Frame at %.2f seconds", frame.time.seconds), try jpeg(frame.image)))
                }
            }
            for attachment in inspirations.filter({ $0.kind == .image }).prefix(2) {
                guard let image = NSImage(contentsOfFile: attachment.value),
                      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                images.append(("Inspiration image", try jpeg(cgImage)))
            }
            for attachment in inspirations.filter({ $0.kind == .video }).prefix(1) {
                let asset = AVURLAsset(url: URL(fileURLWithPath: attachment.value))
                guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { continue }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 960, height: 960)
                for fraction in [0.1, 0.5, 0.9] {
                    let time = duration * fraction
                    guard let frame = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 60000), actualTime: nil) else { continue }
                    images.append((String(format: "Inspiration clip at %.2f seconds", time), try jpeg(frame)))
                }
            }
            return images
        }.value
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw DesignerAssistantError.missingEvidence
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw DesignerAssistantError.missingEvidence }
        return data as Data
    }

    private static func response(key: String, prompt: String, images: [(String, Data)], connection: AIConnection? = nil, send: SendRequest) async throws -> String {
        let config = connection ?? AIConnection(provider: .openAI, model: model, endpoint: AIProvider.openAI.defaultEndpoint, executablePath: "", key: key)
        return try await AITransport.respond(connection: config, prompt: prompt, images: images, send: send)
    }
}
