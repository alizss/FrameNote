import AppKit
@preconcurrency import AVFoundation
import Foundation

/// A separate actor owns decoding, rendering and file work. None runs on the UI actor.
public actor FeedbackExportWorker {
    public init() {}

    public func prepare(_ request: ExportRequest, previewOnly: Bool = false) async throws -> PreparedFeedback {
        try FileManager.default.createDirectory(at: request.parent, withIntermediateDirectories: true)
        let folder = try await export(request, previewOnly: previewOnly)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                return name == "reference.png" || name == "feedback.md" || name == "wireframe.png" || name.hasPrefix("inspiration-") || name.hasPrefix("variant-")
                    || (request.videoURL == nil && name == "annotated.png")
                    || (request.videoURL != nil && (name.hasSuffix("-marked.png") || name.contains("-sample-") || name.hasSuffix("-sequence.png") || name.hasSuffix("-clip.mov") || name == request.videoURL?.lastPathComponent))
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return PreparedFeedback(folder: folder, files: files,
                                markdown: try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8),
                                previewOnly: previewOnly,
                                clipboardImages: try PreparedFeedback.copyImageURLs(in: files).map { try Data(contentsOf: $0) })
    }

    public func export(_ request: ExportRequest, previewOnly: Bool = false) async throws -> URL {
        let folder = try ReviewExporter.exportImages(request, previewOnly: previewOnly)
        do {
            if let videoURL = request.videoURL {
                try await addMotionEvidence(videoURL: videoURL, marks: request.marks, folder: folder, previewOnly: previewOnly)
            }
            try Task.checkCancellation()
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    private func addMotionEvidence(videoURL: URL, marks: [ReviewMark], folder: URL, previewOnly: Bool) async throws {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 640, height: 640)
        var evidence: [MotionEvidence] = []
        for (index, mark) in marks.enumerated() {
            try Task.checkCancellation()
            guard let start = mark.time, let end = mark.endTime, end > start,
                  start >= 0, start < duration else { continue }
            let upper = min(end, duration)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let fps = Double((try? await track?.load(.nominalFrameRate)) ?? 30)
            let last = max(start, upper - 1 / max(fps, 1))
            let count = mark.wholeMedia == true ? 12 : 4
            let times = (0..<count).map { start + (last - start) * Double($0) / Double(count - 1) }
            var frames: [(CGImage, Double)] = []
            for time in times {
                try Task.checkCancellation()
                let frame = try VideoEvidence.frame(from: generator, at: CMTime(seconds: time, preferredTimescale: 60000))
                frames.append((frame.image, frame.time.seconds))
            }
            let stem = String(format: "moment-%02d", index + 1)
            for (sampleIndex, frame) in frames.enumerated() {
                try autoreleasepool {
                    let name = String(format: "%@-sample-%02d-%.0fms.png", stem, sampleIndex + 1, frame.1 * 1000)
                    try ReviewExporter.annotatedPNG(source: frame.0, marks: [mark], numberOffset: index)
                        .write(to: folder.appendingPathComponent(name))
                }
            }
            if previewOnly { continue }
            let sequenceName = "\(stem)-sequence.png"
            try storyboard(frames: frames, mark: mark, number: index + 1)
                .write(to: folder.appendingPathComponent(sequenceName))
            let clipName = "\(stem)-clip.mov"
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.unreadableImage
            }
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                           end: CMTime(seconds: upper, preferredTimescale: 60000))
            let clipURL = folder.appendingPathComponent(clipName)
            let cancellation = ClipCancellation(session)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if #available(macOS 15, *) {
                    try await session.export(to: clipURL, as: .mov)
                } else {
                    session.outputURL = clipURL
                    session.outputFileType = .mov
                    await session.export()
                    if let error = session.error { throw error }
                    guard session.status == .completed else { throw ExportError.imageEncodingFailed }
                }
                try Task.checkCancellation()
            } onCancel: { cancellation.cancel() }
            evidence.append(MotionEvidence(markID: mark.id, sequenceFile: sequenceName,
                                           clipFile: clipName, sourceTimes: frames.map(\.1)))
        }
        let jsonURL = folder.appendingPathComponent("feedback.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ReviewManifest.self, from: Data(contentsOf: jsonURL))
        manifest.motionEvidence = evidence.isEmpty ? nil : evidence
        if !evidence.isEmpty { manifest.schemaVersion = 2 }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: jsonURL, options: .atomic)
        try ReviewMarkdown.generate(manifest).write(to: folder.appendingPathComponent("feedback.md"), atomically: true, encoding: .utf8)
    }

    private func storyboard(frames: [(CGImage, Double)], mark: ReviewMark, number: Int) throws -> Data {
        let cellWidth = 640, cellHeight = 400, gutter = 20, top = 74
        let columns = frames.count > 4 ? 3 : 2
        let rows = (frames.count + columns - 1) / columns
        let width = cellWidth * columns + gutter * (columns + 1), height = cellHeight * rows + gutter * (rows + 1) + top
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw ExportError.imageEncodingFailed }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        let textStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black]
        ("Comment \(number) · Motion sequence · source timestamps" as NSString)
            .draw(at: NSPoint(x: gutter, y: height - 32), withAttributes: textStyle)
        (mark.note as NSString).draw(in: NSRect(x: gutter, y: height - 66, width: width - 40, height: 26), withAttributes: textStyle)
        for (i, frame) in frames.enumerated() {
            try autoreleasepool {
            let marked = try ReviewExporter.annotatedPNG(source: frame.0, marks: [mark], numberOffset: number - 1)
            guard let image = NSImage(data: marked) else { throw ExportError.imageEncodingFailed }
            let x = gutter + (i % columns) * (cellWidth + gutter)
            let y = height - top - gutter - (i / columns + 1) * cellHeight - (i / columns) * gutter
            let scale = min(Double(cellWidth) / Double(frame.0.width), Double(cellHeight - 32) / Double(frame.0.height))
            let w = Double(frame.0.width) * scale, h = Double(frame.0.height) * scale
            image.draw(in: NSRect(x: Double(x) + (Double(cellWidth) - w) / 2, y: Double(y) + 32, width: w, height: h))
            (String(format: "%d · %.3f s", i + 1, frame.1) as NSString)
                .draw(at: NSPoint(x: x, y: y + 6), withAttributes: textStyle)
        }
            }
        context.flushGraphics()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw ExportError.imageEncodingFailed }
        return data
    }
}

public struct PreparedFeedback: Sendable {
    public let folder: URL
    public let files: [URL]
    public let markdown: String
    public let previewOnly: Bool
    public let clipboardImages: [Data]

    public static func copyImageURLs(in files: [URL]) -> [URL] {
        let samples = files.filter { $0.lastPathComponent.contains("-sample-") }
        if !samples.isEmpty { return Array(samples.prefix(16)) }
        let sequences = files.filter { $0.lastPathComponent.hasSuffix("-sequence.png") }
        let images = sequences.isEmpty ? files.filter {
            $0.lastPathComponent == "annotated.png" || $0.lastPathComponent.hasSuffix("-marked.png")
        } : sequences
        return Array(images.prefix(16))
    }
}

// AVFoundation explicitly supports cancellation from another queue. The reference is immutable.
private final class ClipCancellation: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}
