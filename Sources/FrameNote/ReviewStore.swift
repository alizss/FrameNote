import AppKit
import AVFoundation
import Combine
import Foundation
import FrameNoteCore
import UniformTypeIdentifiers

@MainActor
final class ReviewStore: ObservableObject {
    @Published var screenshot: NSImage?
    @Published var reference: NSImage?
    @Published var videoURL: URL?
    @Published var player: AVPlayer?
    @Published var videoSize = CGSize(width: 16, height: 9)
    @Published var duration = 0.0
    @Published var currentTime = 0.0
    @Published var marks: [ReviewMark] = [] {
        didSet { if marks != oldValue { lastExport = nil } }
    }
    @Published var pendingGapPreview: ReviewMark? {
        didSet { if pendingGapPreview != oldValue { lastExport = nil } }
    }
    @Published var title = "UI feedback" {
        didSet { if title != oldValue { lastExport = nil } }
    }
    @Published var tool: MarkKind = .point {
        didSet { if tool != .compareGaps { pendingGapPreview = nil } }
    }
    @Published var compare = false
    @Published var comparisonFraction = 0.5
    @Published var loopEnabled = false {
        didSet { if loopEnabled != oldValue { lastExport = nil } }
    }
    @Published var loopStart = 0.0
    @Published var loopEnd = 0.0
    @Published var status = "Choose a screenshot or capture a window to start."
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var lastExport: URL?

    private let recorder = ScreenRecorder()
    private var timeObserver: Any?

    func importScreenshot() {
        guard let url = chooseImage() else { return }
        openImage(at: url)
    }

    func openImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            status = "Could not read that image. Choose a PNG or JPEG."
            return
        }
        screenshot = image
        clearVideo()
        reference = nil
        marks = []
        lastExport = nil
        compare = false
        status = "Screenshot ready. Select a tool and mark the image."
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(at: url)
    }

    func openVideo(at url: URL) {
        loadVideo(url)
        screenshot = nil
        reference = nil
        marks = []
        lastExport = nil
        status = "Clip ready. Play it, pause on an issue, then add a note."
    }

    func importReference() {
        guard let url = chooseImage() else { return }
        guard let image = NSImage(contentsOf: url) else {
            status = "Could not read the reference image."
            return
        }
        reference = image
        compare = true
        lastExport = nil
        status = "Drag the compare slider to inspect before and after."
    }

    private func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func captureWindow() {
        guard !isCapturing else { return }
        isCapturing = true
        status = "Click the window you want to capture. Press Escape to cancel."
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("framenote-\(UUID().uuidString).png")
        Task {
            let result: Int32 = await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-w", "-x", destination.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return -1
                }
            }.value
            defer {
                try? FileManager.default.removeItem(at: destination)
                isCapturing = false
            }
            guard result == 0, let image = NSImage(contentsOf: destination) else {
                status = result == 0 ? "Capture cancelled." : "Capture failed. Check Screen Recording permission for FrameNote."
                return
            }
            screenshot = image
            clearVideo()
            marks = []
            lastExport = nil
            compare = false
            status = "Window captured. Select a tool and mark the image."
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard !isRecording, !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        status = "Starting screen recording…"
        do {
            try await recorder.start()
            clearVideo()
            screenshot = nil
            marks = []
            reference = nil
            lastExport = nil
            currentTime = 0
            duration = 0
            isRecording = true
            status = "Recording screen. FrameNote controls are excluded from the clip."
        } catch {
            status = "Could not start recording: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        guard isRecording else { return }
        isCapturing = true
        defer { isCapturing = false }
        status = "Saving recording…"
        do {
            let url = try await recorder.stop()
            isRecording = false
            loadVideo(url)
            status = "Recording ready. Scrub to a moment, then click the picture to add feedback."
        } catch {
            isRecording = false
            status = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func clearVideo() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        videoURL = nil
        duration = 0
        currentTime = 0
        loopEnabled = false
    }

    private func loadVideo(_ url: URL) {
        clearVideo()
        videoURL = url
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        let asset = AVURLAsset(url: url)
        Task {
            if let loadedDuration = try? await asset.load(.duration), loadedDuration.seconds.isFinite {
                duration = loadedDuration.seconds
            }
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                if rect.width != 0, rect.height != 0 { videoSize = CGSize(width: abs(rect.width), height: abs(rect.height)) }
            }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                currentTime = seconds
                if loopEnabled, loopEnd > loopStart, seconds >= loopEnd {
                    seek(to: loopStart)
                }
            }
        }
    }

    func seek(to seconds: Double) {
        let bounded = min(max(seconds, 0), max(duration, 0))
        currentTime = bounded
        player?.seek(to: CMTime(seconds: bounded, preferredTimescale: 600),
                     toleranceBefore: CMTime(value: 1, timescale: 30),
                     toleranceAfter: CMTime(value: 1, timescale: 30))
    }

    func toggleLoop() {
        guard duration > 0 else { return }
        if loopEnabled {
            loopEnabled = false
        } else {
            loopStart = min(max(0, currentTime - 1.5), max(0, duration - 3))
            loopEnd = min(duration, loopStart + 3)
            loopEnabled = true
            seek(to: loopStart)
            player?.play()
        }
    }

    func addMark(start: UnitPoint2D, end: UnitPoint2D?) {
        guard screenshot != nil || videoURL != nil else { return }
        if videoURL != nil { player?.pause() }
        let time = videoURL == nil ? nil : currentTime
        if tool == .point || tool == .guideHorizontal || tool == .guideVertical {
            marks.append(ReviewMark(kind: tool, start: start, time: time, note: ""))
            status = "\(tool.rawValue) added. Add a note in the feedback panel."
            return
        }
        guard let end else { return }
        if tool == .compareGaps {
            if let firstGap = pendingGapPreview {
                marks.append(ReviewMark(kind: .compareGaps, start: firstGap.start, end: firstGap.end,
                                        secondStart: start, secondEnd: end, time: time, note: ""))
                pendingGapPreview = nil
                status = "Both gaps are marked. Add a note or compare their pixel sizes."
            } else {
                pendingGapPreview = ReviewMark(kind: .compareGaps, start: start, end: end, time: time, note: "")
                status = "Gap A marked. Drag across gap B to compare."
            }
            return
        }
        marks.append(ReviewMark(kind: tool, start: start, end: end, time: time, note: ""))
        status = "\(tool.rawValue) added. Add a note in the feedback panel."
    }

    func export() {
        guard screenshot != nil || videoURL != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the feedback report."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try ReviewExporter.export(
                screenshot: screenshot,
                reference: reference,
                title: title,
                marks: marks,
                videoURL: videoURL,
                loopStart: loopEnabled ? loopStart : nil,
                loopEnd: loopEnabled ? loopEnd : nil,
                into: parent
            )
            lastExport = folder
            status = "Exported feedback to \(folder.lastPathComponent)."
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    func copyForAgent() {
        guard let lastExport else {
            status = "Export the review first, then copy a ready-to-paste agent brief."
            return
        }
        let manifest = ReviewManifest(
            createdAt: Date(), title: title,
            imageWidth: screenshot.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width } ?? Int(videoSize.width),
            imageHeight: screenshot.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil)?.height } ?? Int(videoSize.height),
            referenceImageFile: reference == nil ? nil : "reference.png",
            videoFile: videoURL?.lastPathComponent,
            loopStart: loopEnabled ? loopStart : nil,
            loopEnd: loopEnabled ? loopEnd : nil,
            marks: marks
        )
        let brief = ReviewMarkdown.generate(manifest)
            + "\nEvidence folder: \(lastExport.path)\nOpen the marked moments and original recording before changing the UI."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(brief, forType: .string)
        status = "Agent brief copied with the review folder path."
    }

    func revealExport() {
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }
}
