import AppKit
import AVFoundation
import Combine
import Foundation
import FrameNoteCore
import UniformTypeIdentifiers

@MainActor
final class ReviewStore: ObservableObject {
    private let autosaveEnabled: Bool
    private let drafts: ReviewDrafts
    private var draftTask: Task<Void, Never>?
    private var restoringDraft = false
    private var libraryID = UUID()
    private var saveTask: Task<Void, Never>?
    @Published private(set) var savedReviews: [SavedReview] = []

    init(restoreSavedDraft: Bool = false, draftFolder: URL? = nil) {
        drafts = ReviewDrafts(folder: draftFolder)
        autosaveEnabled = restoreSavedDraft
        if restoreSavedDraft { Task { await restoreDraftIfAvailable() } }
    }

    @Published var screenshot: NSImage? { didSet { invalidateFeedback() } }
    @Published var videoURL: URL? { didSet { invalidateFeedback() } }
    @Published var player: AVPlayer?
    @Published var videoSize = CGSize(width: 16, height: 9)
    @Published var duration = 0.0
    @Published var currentTime = 0.0
    @Published var marks: [ReviewMark] = [] {
        didSet {
            guard marks != oldValue else { return }
            if !restoringAnnotations {
                undoStack.append(AnnotationSnapshot(marks: oldValue, overlay: layoutOverlay, showWireframe: showWireframe, pendingGap: pendingGapPreview))
                if undoStack.count > 100 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            // Whole-reference prose is not painted into the preview frames.
            // Keep them ready while the user types; a full export still rebuilds its manifest.
            if preparedPreviewOnly, lastExport != nil {
                func visualMarks(_ values: [ReviewMark]) -> [ReviewMark] {
                    values.map { value in
                        var mark = value
                        if mark.wholeMedia == true { mark.note = ""; mark.designAnalysis = nil }
                        return mark
                    }
                }
                if visualMarks(marks) == visualMarks(oldValue) {
                    preparedMarkdown = nil
                    scheduleDraftSave()
                    return
                }
            }
            invalidateFeedback()
        }
    }
    /// The detected layout drawn over the picture after Auto-annotate.
    @Published private(set) var layoutOverlay: LayoutOverlay? {
        didSet { if layoutOverlay != oldValue { invalidateFeedback() } }
    }
    @Published var showWireframe = true
    @Published private(set) var isAutoAnnotating = false
    @Published var pendingGapPreview: ReviewMark? {
        didSet { if pendingGapPreview != oldValue { invalidateFeedback() } }
    }
    @Published var title = "UI feedback" {
        didSet { if title != oldValue { invalidateFeedback() } }
    }
    @Published var tool: MarkKind = .point {
        didSet { if tool != .compareGaps { pendingGapPreview = nil } }
    }
    @Published var loopEnabled = false {
        didSet { if loopEnabled != oldValue { invalidateFeedback() } }
    }
    @Published var loopStart = 0.0 { didSet { if loopStart != oldValue { invalidateFeedback() } } }
    @Published var loopEnd = 0.0 { didSet { if loopEnd != oldValue { invalidateFeedback() } } }
    @Published var status = "Choose a screenshot or capture a window to start."
    @Published var isCapturing = false
    @Published var isRecording = false
    @Published var recordingStartedAt: Date?
    @Published var isPlaying = false
    @Published var lastExport: URL?
    @Published private(set) var shareFiles: [URL] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var isCopyingForAI = false
    @Published private(set) var reviewRevision = 0
    @Published private(set) var mediaRevision = 0
    @Published private(set) var openedReviewGeneration = 0
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var analyzingMarkIDs: Set<UUID> = []
    @Published private(set) var analysisErrors: [UUID: String] = [:]
    private let exportWorker = FeedbackExportWorker()
    private var exportTask: Task<PreparedFeedback, Error>?
    private var mediaGeneration = UUID()
    private var seekGeneration = 0
    private var pendingSeek: Double?
    private var seekInFlight = false
    private var preparedMarkdown: String?
    private var preparedClipboardImages: [Data] = []
    private var preparedPreviewOnly = false
    private var preparedFeedbackWasShared = false
    private struct AnnotationSnapshot {
        var marks: [ReviewMark]
        var overlay: LayoutOverlay?
        var showWireframe: Bool
        var pendingGap: ReviewMark?
    }
    private var annotationSnapshot: AnnotationSnapshot {
        AnnotationSnapshot(marks: marks, overlay: layoutOverlay, showWireframe: showWireframe, pendingGap: pendingGapPreview)
    }
    private var undoStack: [AnnotationSnapshot] = []
    private var redoStack: [AnnotationSnapshot] = []
    private var restoringAnnotations = false
    private var annotationGeneration = UUID()

    var canUndoAnnotations: Bool { !undoStack.isEmpty }
    var canRedoAnnotations: Bool { !redoStack.isEmpty }

    func undoAnnotations() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotationSnapshot)
        restoringAnnotations = true
        marks = previous.marks
        layoutOverlay = previous.overlay
        showWireframe = previous.showWireframe
        pendingGapPreview = previous.pendingGap
        restoringAnnotations = false
    }

    func redoAnnotations() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotationSnapshot)
        restoringAnnotations = true
        marks = next.marks
        layoutOverlay = next.overlay
        showWireframe = next.showWireframe
        pendingGapPreview = next.pendingGap
        restoringAnnotations = false
    }

    func clearAnnotations() {
        guard !marks.isEmpty || layoutOverlay != nil || pendingGapPreview != nil else { return }
        if marks.isEmpty { undoStack.append(annotationSnapshot); redoStack.removeAll() }
        annotationGeneration = UUID()
        marks = []
        pendingGapPreview = nil
        layoutOverlay = nil
        showWireframe = true
        status = "Annotations cleared. Undo restores them."
    }

    func ensureVariants(for markID: UUID, mode: VariantMode) {
        guard let index = marks.firstIndex(where: { $0.id == markID }),
              !(marks[index].variants ?? []).contains(where: { $0.mode == mode }) else { return }
        var updated = marks[index]
        updated.variants = (updated.variants ?? []) + ReviewVariant.presets(for: mode)
        marks[index] = updated
    }

    @discardableResult
    func saveRefinement(_ draft: ReviewVariant, for markID: UUID) -> ReviewVariant? {
        guard let index = marks.firstIndex(where: { $0.id == markID }),
              let source = marks[index].variants?.first(where: { $0.id == draft.id }) else { return nil }
        var refined = draft
        refined.id = UUID()
        refined.parentID = source.id
        refined.revision = (marks[index].variants ?? []).filter { $0.mode == source.mode && $0.family == source.family }
            .map(\.revision).max()! + 1
        var updated = marks[index]
        updated.variants = (updated.variants ?? []) + [refined]
        marks[index] = updated
        return refined
    }

    func selectVariant(_ variantID: UUID, for markID: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == markID }),
              marks[index].variants?.contains(where: { $0.id == variantID }) == true else { return }
        marks[index].selectedVariantID = variantID
        status = "Prototype chosen. Copy the implementation brief or export the review."
    }

    private func resetAnnotationHistory() {
        annotationGeneration = UUID()
        layoutOverlay = nil
        undoStack.removeAll(); redoStack.removeAll()
        analyzingMarkIDs.removeAll(); analysisErrors.removeAll()
    }


    private let recorder = ScreenRecorder()
    private var timeObserver: Any?
    private var frameIndexTask: Task<Void, Never>?
    private var frameTimes: [Double] = []

    func importInspiration(_ url: URL, source: String) async throws {
        let imported = try await InspirationImporter.shared.importReference(url)
        if Task.isCancelled { try? FileManager.default.removeItem(at: imported.url); throw CancellationError() }
        if imported.isVideo { openVideo(at: imported.url) } else { openImage(at: imported.url) }
        title = source
        if imported.isVideo { duration = imported.duration }
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5),
            time: imported.isVideo ? 0 : nil, endTime: imported.isVideo ? imported.duration : nil,
            note: "")
        if let sourceURL = URL(string: source), ["http", "https"].contains(sourceURL.scheme ?? "") {
            mark.inspirations = [InspirationAttachment(kind: .url, value: source)]
        }
        mark.wholeMedia = true
        marks = [mark]
        status = imported.isVideo ? "Inspiration ready. Analyze the whole video or copy it for your AI tool; no annotation is required." : "Inspiration ready. Add what you like, then copy instructions and attach the image."
    }

    func importScreenshot() {
        guard let url = chooseImage() else { return }
        openImage(at: url)
    }

    func openImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            status = "Could not read that image. Choose a PNG or JPEG."
            return
        }
        beginNewReference()
        screenshot = image
        clearVideo()
        marks = []
        resetAnnotationHistory()
        lastExport = nil
        status = "Screenshot ready. Select a tool and mark the image."
        if !restoringDraft { openedReviewGeneration += 1 }
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(at: url)
    }

    func openVideo(at url: URL) {
        beginNewReference()
        loadVideo(url)
        screenshot = nil
        marks = []
        resetAnnotationHistory()
        lastExport = nil
        status = "Clip ready. Play it, pause on an issue, then add a note."
        if !restoringDraft { openedReviewGeneration += 1 }
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
            beginNewReference()
            screenshot = image
            clearVideo()
            marks = []
            resetAnnotationHistory()
            lastExport = nil
            status = "Window captured. Select a tool and mark the image."
            openedReviewGeneration += 1
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
            beginNewReference()
            clearVideo()
            screenshot = nil
            marks = []
            resetAnnotationHistory()
            lastExport = nil
            currentTime = 0
            duration = 0
            recordingStartedAt = Date()
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
            recordingStartedAt = nil
            loadVideo(url)
            status = "Recording ready. Scrub to a moment, then click the picture to add feedback."
            openedReviewGeneration += 1
        } catch {
            isRecording = false
            recordingStartedAt = nil
            status = "Recording failed: \(error.localizedDescription)"
        }
    }

    func setPlaybackRate(_ rate: Float) {
        guard [Float(0.25), 0.5, 1].contains(rate) else { return }
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    func togglePlayback() {
        guard player != nil else { return }
        if isPlaying { pauseForAnnotation() }
        else {
            if loopEnabled, currentTime < loopStart || currentTime >= loopEnd { seek(to: loopStart) }
            else if duration > 0, currentTime >= duration - 0.01 { seek(to: 0) }
            isPlaying = true
            player?.playImmediately(atRate: playbackRate)
        }
    }

    func pauseForAnnotation() {
        player?.pause()
        isPlaying = false
        if !seekInFlight, let time = player?.currentTime().seconds, time.isFinite, player?.currentItem != nil {
            currentTime = time
        }
    }

    func stepFrame(_ direction: Int) {
        pauseForAnnotation()
        loopEnabled = false
        let target = VideoFrameIndex.adjacent(to: currentTime, direction: direction, times: frameTimes)
            ?? (currentTime + (direction > 0 ? 1 : -1) / max(frameRate, 1))
        seek(to: target)
    }

    private func clearVideo() {
        mediaGeneration = UUID()
        mediaRevision += 1
        frameIndexTask?.cancel(); frameTimes = []
        isPlaying = false
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        videoURL = nil
        duration = 0; currentTime = 0; frameRate = 30
        pendingSeek = nil; seekInFlight = false; seekGeneration += 1
        loopEnabled = false
    }

    private func loadVideo(_ url: URL) {
        clearVideo()
        videoURL = url
        let generation = mediaGeneration
        let newPlayer = AVPlayer(url: url)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        player = newPlayer
        let asset = AVURLAsset(url: url)
        frameIndexTask = Task {
            let times = try? await VideoFrameIndex.load(url)
            guard !Task.isCancelled, generation == mediaGeneration else { return }
            frameTimes = times ?? []
        }
        Task {
            let loadedDuration = try? await asset.load(.duration)
            let track = try? await asset.loadTracks(withMediaType: .video).first
            let size = try? await track?.load(.naturalSize)
            let transform = try? await track?.load(.preferredTransform)
            let fps = try? await track?.load(.nominalFrameRate)
            guard generation == mediaGeneration else { return }
            if let loadedDuration, loadedDuration.seconds.isFinite {
                duration = loadedDuration.seconds
                if let root = marks.firstIndex(where: { $0.wholeMedia == true && ($0.endTime ?? 0) <= 0 }) {
                    marks[root].endTime = duration
                }
            }
            if let size, let transform {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                if rect.width != 0, rect.height != 0 { videoSize = CGSize(width: abs(rect.width), height: abs(rect.height)) }
            }
            if let fps, fps > 0 { frameRate = Double(fps) }
        }
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.mediaGeneration == generation, !self.seekInFlight else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if self.loopEnabled, self.isPlaying, self.loopEnd > self.loopStart,
                   seconds >= self.loopEnd || seconds < self.loopStart - 0.05 {
                    self.seek(to: self.loopStart)
                } else if seconds >= self.duration - 0.005, self.duration > 0 {
                    self.isPlaying = false
                }
            }
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let bounded = min(max(seconds, 0), max(duration, 0))
        currentTime = bounded
        pendingSeek = bounded
        chaseSeek()
    }

    private func chaseSeek() {
        guard !seekInFlight, let target = pendingSeek, let player, player.currentItem != nil else { return }
        pendingSeek = nil
        seekInFlight = true
        let generation = mediaGeneration
        seekGeneration += 1
        let seekID = seekGeneration
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mediaGeneration == generation, self.seekGeneration == seekID else { return }
                self.seekInFlight = false
                if self.pendingSeek != nil { self.chaseSeek() }
                else if self.isPlaying { self.player?.playImmediately(atRate: self.playbackRate) }
            }
        }
    }

    func toggleLoop(range: ClosedRange<Double>? = nil) {
        guard duration > 0 else { return }
        if loopEnabled { loopEnabled = false; return }
        if let range {
            loopStart = min(max(0, range.lowerBound), duration)
            loopEnd = min(max(loopStart, range.upperBound), duration)
        } else {
            loopStart = min(max(0, currentTime - 1.5), max(0, duration - 3))
            loopEnd = min(duration, loopStart + 3)
        }
        guard loopEnd > loopStart else { return }
        loopEnabled = true
        seek(to: loopStart)
        isPlaying = true
        player?.playImmediately(atRate: playbackRate)
    }

    func addMark(start: UnitPoint2D, end: UnitPoint2D?) {
        guard screenshot != nil || videoURL != nil else { return }
        if videoURL != nil { pauseForAnnotation() }
        let time = videoURL == nil ? nil : currentTime
        if tool == .point, let end, abs(end.x - start.x) > 0.005, abs(end.y - start.y) > 0.005 {
            marks.append(ReviewMark(kind: .focus, start: start, end: end, time: time, note: ""))
            return
        }
        if tool == .point || tool == .guideHorizontal || tool == .guideVertical {
            marks.append(ReviewMark(kind: tool, start: start, time: time, note: ""))
            status = "\(tool.rawValue) added. Write a comment beside the selection."
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
        status = "\(tool.rawValue) added. Write a comment beside the selection."
    }

    /// Measures the layout of the picture (or of one area of it) and annotates what a designer would flag.
    /// Videos are analysed at the paused frame. Returns the number of problems found, or nil if nothing could be scanned.
    @discardableResult
    func autoAnnotate(in region: CGRect? = nil) async -> Int? {
        guard !isAutoAnnotating, screenshot != nil || videoURL != nil else { return nil }
        pauseForAnnotation()
        let still = screenshot.map { UncheckedImage(image: $0.cgImage(forProposedRect: nil, context: nil, hints: nil)) }
        let video = videoURL
        let time = video == nil ? nil : currentTime
        let generation = mediaGeneration
        let annotationToken = annotationGeneration
        isAutoAnnotating = true
        status = region == nil ? "Scanning the layout…" : "Scanning the selected area…"
        defer { isAutoAnnotating = false }

        let analysis: LayoutAnalysis? = await Task.detached(priority: .userInitiated) {
            if let image = still?.image { return LayoutAnalyzer.analyze(image, region: region, options: .still) }
            guard let video, let time else { return nil }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            guard let frame = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
            else { return nil }
            return LayoutAnalyzer.analyze(frame, region: region, options: .videoFrame)
        }.value

        guard generation == mediaGeneration, annotationToken == annotationGeneration else { return nil }
        guard let analysis else {
            status = "Could not read this picture to scan it."
            return nil
        }
        applyAnalysis(analysis, time: time, region: region)
        return analysis.findings.count
    }

    private func applyAnalysis(_ analysis: LayoutAnalysis, time: Double?, region: CGRect?) {
        func sameMoment(_ other: Double?) -> Bool {
            switch (time, other) {
            case (nil, nil): true
            case let (a?, b?): abs(a - b) < 0.05
            default: false
            }
        }
        func inside(_ mark: ReviewMark) -> Bool {
            guard let region else { return true }
            return region.contains(CGPoint(x: mark.start.x, y: mark.start.y))
        }
        // A rescan replaces earlier automatic notes for the same place, but never touches anything the person approved or wrote.
        var updated = marks.filter { !($0.auto == true && !$0.isApproved && sameMoment($0.time) && inside($0)) }
        // An approved note already covers the same spot, so do not raise it again.
        func covered(_ mark: ReviewMark) -> Bool {
            updated.contains { kept in
                kept.auto == true && sameMoment(kept.time) && kept.kind == mark.kind
                    && abs(kept.start.x - mark.start.x) < 0.01 && abs(kept.start.y - mark.start.y) < 0.01
            }
        }
        updated += analysis.findings.map { ReviewMark(finding: $0, time: time) }.filter { !covered($0) }
        marks = updated   // one assignment: one undo step
        layoutOverlay = LayoutOverlay(analysis, time: time)
        showWireframe = true
        let count = analysis.findings.count
        if analysis.truncated {
            status = "This picture is too detailed to measure fully. Select a smaller area and try again."
        } else if analysis.elements.isEmpty {
            status = "No interface elements found here. Try a screenshot of an app or page."
        } else if count == 0 {
            status = "Scanned \(analysis.elements.count) elements. No spacing, alignment or contrast problems found."
        } else {
            status = "Found \(count) possible problem\(count == 1 ? "" : "s") in \(analysis.elements.count) elements. Review the numbered marks."
        }
    }

    func convertMark(_ id: UUID, to kind: MarkKind) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        var mark = marks[index]
        mark.convert(to: kind)
        marks[index] = mark
    }

    func addInspirationURL(_ text: String, to markID: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, let index = marks.firstIndex(where: { $0.id == markID }) else { return false }
        marks[index].inspirations = (marks[index].inspirations ?? []) +
            [InspirationAttachment(kind: .url, value: trimmed)]
        return true
    }

    func addInspirationFile(_ source: URL, to markID: UUID) throws {
        guard let index = marks.firstIndex(where: { $0.id == markID }) else { return }
        let extensionName = source.pathExtension.lowercased()
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "tiff", "webp", "gif"]
        let kind: InspirationAttachment.Kind
        if imageExtensions.contains(extensionName) { kind = .image }
        else if ["mov", "mp4", "m4v"].contains(extensionName) { kind = .video }
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameNote/Inspiration", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(UUID().uuidString).\(extensionName)")
        try FileManager.default.copyItem(at: source, to: target)
        marks[index].inspirations = (marks[index].inspirations ?? []) +
            [InspirationAttachment(kind: kind, value: target.path, displayName: source.lastPathComponent)]
    }

    func pasteInspirationImage(to markID: UUID, pasteboard: NSPasteboard = .general) throws {
        let data: Data?
        if let png = pasteboard.data(forType: .png) { data = png }
        else if let tiff = pasteboard.data(forType: .tiff), let image = NSImage(data: tiff),
                let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        } else { data = nil }
        guard let data else { throw DesignerAssistantError.missingEvidence }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameNote/Inspiration", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: target, options: .atomic)
        guard let index = marks.firstIndex(where: { $0.id == markID }) else { return }
        marks[index].inspirations = (marks[index].inspirations ?? []) +
            [InspirationAttachment(kind: .image, value: target.path, displayName: "Pasted image")]
    }

    func removeInspiration(_ attachmentID: UUID, from markID: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == markID }) else { return }
        marks[index].inspirations?.removeAll { $0.id == attachmentID }
    }

    @discardableResult
    func ensureWholeReview() -> UUID {
        if let mark = marks.first(where: { $0.wholeMedia == true && $0.aiGenerated != true }) { return mark.id }
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5),
            time: videoURL == nil ? nil : 0, endTime: videoURL == nil ? nil : duration,
            note: "")
        mark.wholeMedia = true
        marks.append(mark)
        return mark.id
    }

    func applyWholeReview(_ report: WholeReviewAnalysis, to markID: UUID, duration: Double, isVideo: Bool) {
        var updated = marks.filter { $0.aiGenerated != true || $0.isApproved }
        guard let root = updated.firstIndex(where: { $0.id == markID }) else { return }
        updated[root].designAnalysis = report.summary
        updated += report.marks(duration: duration, isVideo: isVideo)
        marks = updated
    }

    func analyzeDesign(for markID: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == markID }) else { return }
        let connection = AIConnection.load()
        if let error = connection.configurationError {
            analysisErrors[markID] = error
            return
        }
        let key = connection.key
        let mark = marks[index]
        let annotationToken = annotationGeneration
        let focus: CGRect? = mark.end.map { end in
            CGRect(x: min(mark.start.x, end.x), y: min(mark.start.y, end.y),
                   width: abs(mark.start.x - end.x), height: abs(mark.start.y - end.y))
        }
        let image = screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let video = videoURL
        let videoDuration = duration
        let analysisStart = video == nil ? nil : mark.time.map { mark.endTime == nil ? max(0, $0 - 1.5) : $0 }
        let analysisEnd = video == nil ? nil : mark.time.map { mark.endTime ?? min(videoDuration, $0 + 1.5) }
        analyzingMarkIDs.insert(markID)
        analysisErrors[markID] = nil
        status = "Analyzing with \(connection.provider.title)…"
        Task {
            do {
                if connection.provider.isCLI { _ = try await connection.check() }
                if mark.wholeMedia == true && mark.aiGenerated != true {
                    let report = try await DesignerAssistant.analyzeWhole(key: key, screenshot: image, videoURL: video,
                        duration: videoDuration, note: mark.note, connection: connection)
                    guard annotationToken == annotationGeneration, let currentIndex = marks.firstIndex(where: { $0.id == markID }) else {
                        analyzingMarkIDs.remove(markID); return
                    }
                    guard marks[currentIndex].note == mark.note else { analyzingMarkIDs.remove(markID); return }
                    applyWholeReview(report, to: markID, duration: videoDuration, isVideo: video != nil)
                    analyzingMarkIDs.remove(markID)
                    status = "Review ready from \(connection.provider.title). AI observations have been added automatically."
                    return
                }
                let result = try await DesignerAssistant.analyze(
                    key: key, screenshot: image, videoURL: video, start: analysisStart,
                    end: analysisEnd, duration: videoDuration, focus: focus,
                    note: mark.note, inspirations: mark.inspirations ?? [], connection: connection)
                guard annotationToken == annotationGeneration, let currentIndex = marks.firstIndex(where: { $0.id == markID }) else {
                    analyzingMarkIDs.remove(markID); return
                }
                let current = marks[currentIndex]
                if current.start == mark.start && current.end == mark.end &&
                    current.time == mark.time && current.endTime == mark.endTime {
                    marks[currentIndex].designAnalysis = result
                }
            } catch {
                if annotationToken == annotationGeneration {
                    analysisErrors[markID] = error.localizedDescription
                    status = "Analysis failed. Check the connection or retry."
                }
            }
            analyzingMarkIDs.remove(markID)
        }
    }

    private func invalidateFeedback() {
        if let folder = lastExport, !preparedFeedbackWasShared {
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
        }
        preparedFeedbackWasShared = false
        reviewRevision += 1
        exportTask?.cancel(); exportTask = nil
        lastExport = nil; shareFiles = []; preparedMarkdown = nil; preparedClipboardImages = []
        isPreparing = false
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        guard autosaveEnabled, !restoringDraft, screenshot != nil || videoURL != nil else { return }
        draftTask?.cancel()
        draftTask = Task {
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard !Task.isCancelled else { return }
            persistCurrentReview()
        }
    }

    private func beginNewReference() {
        guard !restoringDraft else { return }
        draftTask?.cancel()
        persistCurrentReview()
        libraryID = UUID()
    }

    private func persistCurrentReview() {
        guard autosaveEnabled, !restoringDraft, screenshot != nil || videoURL != nil else { return }
        let image = screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let video = videoURL, id = libraryID
        let title = title, marks = marks, time = currentTime
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            do {
                try await drafts.save(title: title, marks: marks, screenshot: image,
                                      videoURL: video, currentTime: time, generation: id)
            } catch { status = "Could not save this review: \(error.localizedDescription)" }
        }
    }

    func refreshLibrary() async {
        draftTask?.cancel()
        persistCurrentReview()
        await saveTask?.value
        do { savedReviews = try await drafts.list() }
        catch { status = "Could not load the library: \(error.localizedDescription)" }
    }

    func openSavedReview(_ review: SavedReview) async -> Bool {
        guard FileManager.default.fileExists(atPath: review.media.path),
              review.media.pathExtension == "mov" || NSImage(contentsOf: review.media) != nil else {
            status = "Could not open this reference. Its saved media is missing or unreadable."
            return false
        }
        draftTask?.cancel()
        persistCurrentReview()
        await saveTask?.value
        restore(review.draft, media: review.media)
        openedReviewGeneration += 1
        persistCurrentReview()
        return true
    }

    private func restoreDraftIfAvailable() async {
        guard screenshot == nil, videoURL == nil, !isRecording else { return }
        do {
            guard let (draft, media) = try await drafts.load() else { return }
            guard screenshot == nil, videoURL == nil, !isRecording else { return }
            restore(draft, media: media)
        } catch { status = "Could not restore the previous review: \(error.localizedDescription)" }
    }

    private func restore(_ draft: ReviewDraft, media: URL) {
        restoringDraft = true
        libraryID = draft.id ?? UUID()
        if media.pathExtension == "mov" { openVideo(at: media) }
        else { openImage(at: media) }
        title = draft.title
        marks = draft.marks
        resetAnnotationHistory()
        restoringDraft = false
        status = "Review restored. Continue where you left off."
        if media.pathExtension == "mov" {
            let generation = mediaGeneration
            Task {
                for _ in 0..<50 {
                    guard generation == mediaGeneration else { return }
                    if duration > 0 { seek(to: min(draft.currentTime, duration)); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    func export() {
        guard screenshot != nil || videoURL != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Save here"
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task {
            guard let folder = await prepareFeedback(fullExport: true) else { return }
            retainPreparedFeedback()
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: folder, to: parent.appendingPathComponent(folder.lastPathComponent))
                }.value
                status = "Saved a copy of your feedback."
            } catch { status = "Export failed: \(error.localizedDescription)" }
        }
    }

    @discardableResult
    func prepareFeedback(fullExport: Bool = true) async -> URL? {
        if let lastExport {
            if !fullExport || !preparedPreviewOnly { return lastExport }
            invalidateFeedback()
        }
        guard screenshot != nil || videoURL != nil else { return nil }
        let revision = reviewRevision
        isPreparing = true
        status = fullExport ? "Preparing export…" : "Preparing frames…"
        if exportTask == nil {
            let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FrameNote/Shared Reviews", isDirectory: true)
            let request = ExportRequest(
                screenshot: screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                reference: nil,
                title: title, marks: marks, videoURL: videoURL,
                loopStart: loopEnabled ? loopStart : nil, loopEnd: loopEnabled ? loopEnd : nil, parent: parent,
                wireframe: videoURL == nil ? layoutOverlay : nil)
            exportTask = Task { try await exportWorker.prepare(request, previewOnly: !fullExport) }
        }
        do {
            guard let task = exportTask else { return nil }
            let prepared = try await task.value
            guard revision == reviewRevision else { return nil }
            preparedClipboardImages = prepared.clipboardImages
            preparedPreviewOnly = prepared.previewOnly
            lastExport = prepared.folder
            shareFiles = prepared.files
            preparedMarkdown = prepared.markdown
            exportTask = nil; isPreparing = false
            if fullExport && prepared.previewOnly { return await prepareFeedback(fullExport: true) }
            status = "Ready to copy."
            return prepared.folder
        } catch {
            guard revision == reviewRevision else { return nil }
            exportTask = nil; isPreparing = false
            if !(error is CancellationError) { status = "Sharing failed: \(error.localizedDescription)" }
            return nil
        }
    }

    func copyImage(at url: URL, pasteboard: NSPasteboard = .general) async {
        retainPreparedFeedback()
        status = "Copying image…"
        guard let data = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value else {
                status = "Could not copy that image."; return
        }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        status = "Image copied. Paste it into your chat."
    }

    var implementationBrief: String {
        let root = marks.first { $0.wholeMedia == true && $0.aiGenerated != true }
        var lines = ["# Implementation brief", "", "Use this reference to implement the described UI in the current project. Inspect the existing code and reuse its components and conventions.", "", "Reference: \(title)"]
        if let note = root?.note, !note.isEmpty { lines += ["", "## Goal", note] }
        if let summary = root?.designAnalysis, !summary.isEmpty {
            lines += ["", summary]
        } else {
            lines += ["", "Analysis is not available yet. Inspect the source before deciding what to implement."]
        }
        for mark in marks where mark.aiGenerated == true {
            let time = mark.time.map { String(format: " [%.2fs]", $0) } ?? ""
            lines += ["", "- " + mark.note + time]
        }
        lines += ["", "## Implementation requirements",
                  "- Recreate the visible hierarchy, layout, states, and interaction sequence; adapt content to this project.",
                  "- Treat inferred measurements and motion timing as estimates. Do not invent unseen behavior.",
                  "- Keep local interaction feedback within 150 ms; show progress for longer work.",
                  "- Support keyboard navigation and reduced motion. Verify the completed flow.",
                  "", "Evidence: analysis uses sampled frames, without audio. A source URL may require access; local files are only accessible on this Mac."]
        if let videoURL { lines += ["Local video: " + videoURL.path] }
        return lines.joined(separator: "\n")
    }

    func copyImplementationBrief(pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(implementationBrief, forType: .string)
        status = "Instructions copied."
    }

    /// The preview and clipboard share this exact selection, including the sixteen-image limit.
    var copyEvidenceURLs: [URL] {
        PreparedFeedback.copyImageURLs(in: shareFiles)
    }

    func copyPreviewForAI(pasteboard: NSPasteboard = .general) async {
        guard !isCopyingForAI, lastExport != nil else { return }
        isCopyingForAI = true
        defer { isCopyingForAI = false }
        let text = implementationBrief
        let data = preparedClipboardImages
        guard data.count == copyEvidenceURLs.count, !data.isEmpty else {
            status = "Could not copy the preview. Wait for images to finish preparing and try again."
            return
        }
        let first = NSPasteboardItem()
        first.setString(text, forType: .string)
        first.setData(data[0], forType: .png)
        let items = [first] + data.dropFirst().map { png in
            let item = NSPasteboardItem(); item.setData(png, forType: .png); return item
        }
        pasteboard.clearContents()
        let copied = pasteboard.writeObjects(items)
        if copied { retainPreparedFeedback() }
        status = copied ? "Copied text + \(data.count) images shown above. If your AI pastes text only, drag these images into it." : "Could not write to the clipboard. Try again."
    }

    func copyForAgent(pasteboard: NSPasteboard = .general) {
        retainPreparedFeedback()
        let manifest = ReviewManifest(createdAt: Date(), title: title,
            imageWidth: screenshot.flatMap { $0.representations.first?.pixelsWide } ?? Int(videoSize.width),
            imageHeight: screenshot.flatMap { $0.representations.first?.pixelsHigh } ?? Int(videoSize.height),
            referenceImageFile: nil, videoFile: videoURL?.lastPathComponent,
            loopStart: loopEnabled ? loopStart : nil, loopEnd: loopEnabled ? loopEnd : nil, marks: marks)
        var brief = preparedMarkdown ?? ReviewMarkdown.generate(manifest)
        if let lastExport { brief += "\nEvidence folder: \(lastExport.path)" }
        brief += "\nFor motion review, attach the timestamped motion sequence image alongside these instructions; include the clip when the receiving tool supports video. Review the evidence before changing the UI. Approved comments are accepted; only act on open comments."
        pasteboard.clearContents()
        pasteboard.setString(brief, forType: .string)
        status = "Instructions copied. Paste into chat, then attach the evidence below."
    }

    func copyForAI(pasteboard: NSPasteboard = .general) async {
        guard !isCopyingForAI else { return }
        isCopyingForAI = true
        defer { isCopyingForAI = false }
        if let video = videoURL, duration <= 0,
           let actual = try? await AVURLAsset(url: video).load(.duration).seconds,
           videoURL == video, actual.isFinite, actual > 0 { duration = actual }
        if marks.isEmpty { ensureWholeReview() }
        var folder = await prepareFeedback(fullExport: true)
        if folder == nil { folder = await prepareFeedback(fullExport: true) }
        copyForAgent(pasteboard: pasteboard)
        guard folder != nil else { status = "Instructions copied. Evidence could not be prepared; retry or attach your source media."; return }
        let brief = pasteboard.string(forType: .string) ?? ""
        let images = shareFiles.filter { $0.lastPathComponent.hasSuffix("-sequence.png") }
        let chosen = images.isEmpty ? shareFiles.filter { $0.lastPathComponent == "annotated.png" || $0.lastPathComponent.hasSuffix("-marked.png") } : images
        let data = await Task.detached(priority: .userInitiated) { chosen.prefix(8).compactMap { try? Data(contentsOf: $0) } }.value
        let first = NSPasteboardItem()
        first.setString(brief, forType: .string)
        if let png = data.first { first.setData(png, forType: .png) }
        var items = [first]
        for png in data.dropFirst() { let item = NSPasteboardItem(); item.setData(png, forType: .png); items.append(item) }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        retainPreparedFeedback()
        status = "Copied instructions + \(data.count) image(s). Paste into your AI tool. If it pastes text only, use Edit details → Files & feedback for the images."
    }

    func retainPreparedFeedback() { if lastExport != nil { preparedFeedbackWasShared = true } }

    func revealExport() {
        retainPreparedFeedback()
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }
}

/// CGImage is immutable once created; this lets it cross into a background task.
private struct UncheckedImage: @unchecked Sendable { let image: CGImage? }
