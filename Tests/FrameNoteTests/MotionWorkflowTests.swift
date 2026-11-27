import AppKit
@preconcurrency import AVFoundation
import SwiftUI
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class MotionWorkflowTests: XCTestCase {
    func testFrameIndexHandlesVariableFrameTimesAndBothEnds() {
        let times = [0.0, 0.04, 0.12, 0.15]
        XCTAssertEqual(VideoFrameIndex.adjacent(to: 0.04, direction: 1, times: times), 0.12)
        XCTAssertEqual(VideoFrameIndex.adjacent(to: 0.09, direction: -1, times: times), 0.04)
        XCTAssertEqual(VideoFrameIndex.adjacent(to: 0.12, direction: -1, times: times), 0.04)
        XCTAssertEqual(VideoFrameIndex.adjacent(to: 0, direction: -1, times: times), 0)
        XCTAssertEqual(VideoFrameIndex.adjacent(to: 0.15, direction: 1, times: times), 0.15)
    }

    @MainActor
    func testEditingDuringExportDiscardsStaleEvidence() async throws {
        let url = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReviewStore()
        store.openVideo(at: url)
        store.marks = [ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5),
                                  time: 0.2, endTime: 1.2, note: "Old request")]
        let old = Task { await store.prepareFeedback() }
        while !store.isPreparing { await Task.yield() }
        store.marks[0].note = "Latest request"
        let refreshed = await store.prepareFeedback()
        let oldResult = await old.value
        XCTAssertNil(oldResult, "An edited review must not publish its obsolete export.")
        let folder = try XCTUnwrap(refreshed, store.status)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(store.lastExport, folder)
        let notes = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains("Latest request"))
        XCTAssertFalse(notes.contains("Old request"))
    }

    @MainActor
    func testSlowPlaybackFrameSteppingAndSelectedLoopUseRealVideo() async throws {
        let url = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReviewStore()
        store.openVideo(at: url)
        try await waitUntil { store.duration > 0 && store.player?.currentItem?.status == .readyToPlay }
        XCTAssertEqual(store.frameRate, 30, accuracy: 0.1)
        store.seek(to: 0.5)
        try await waitUntil { abs((store.player?.currentTime().seconds ?? 0) - 0.5) < 0.01 }
        store.setPlaybackRate(0.25)
        store.togglePlayback()
        try await Task.sleep(for: .milliseconds(240))
        store.pauseForAnnotation()
        XCTAssertGreaterThan(store.currentTime, 0.52)
        XCTAssertLessThan(store.currentTime, 0.64, "Quarter speed should advance about 60 ms over 240 ms.")
        store.seek(to: 1)
        try await waitUntil { abs((store.player?.currentTime().seconds ?? 0) - 1) < 0.01 }
        store.stepFrame(1)
        try await waitUntil { (store.player?.currentTime().seconds ?? 0) > 1.02 }
        XCTAssertEqual(try XCTUnwrap(store.player?.currentTime().seconds), 1 + 1.0 / 30, accuracy: 0.008)
        store.stepFrame(-1)
        try await waitUntil { abs((store.player?.currentTime().seconds ?? 0) - 1) < 0.01 }
        XCTAssertFalse(store.isPlaying)
        store.setPlaybackRate(0.5)
        store.toggleLoop(range: 0.2...0.4)
        XCTAssertEqual(store.loopStart, 0.2)
        XCTAssertEqual(store.loopEnd, 0.4)
        var previous = store.currentTime, wrapped = false
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(25))
            if store.currentTime < previous - 0.08 { wrapped = true }
            previous = store.currentTime
        }
        XCTAssertTrue(wrapped, "The selected range should actually replay.")
        XCTAssertEqual(store.player?.rate, 0.5)
        store.pauseForAnnotation()
        store.toggleLoop(range: 0.2...0.4)
        XCTAssertFalse(store.loopEnabled)
    }

    @MainActor
    func testMotionExportContainsTrimmedClipAndTimestampedSequenceWithoutBlockingUI() async throws {
        let url = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ReviewStore()
        store.openVideo(at: url)
        store.marks = [ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.1, y: 0.2),
                                  end: UnitPoint2D(x: 0.7, y: 0.8), time: 0.5, endTime: 1.7, note: "The card jumps")]
        let export = Task { await store.prepareFeedback() }
        var intervals: [Double] = []
        let heartbeat = Task { @MainActor in
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
                let now = ProcessInfo.processInfo.systemUptime
                intervals.append((now - last) * 1000)
                last = now
            }
        }
        let result = await export.value
        heartbeat.cancel()
        let folder = try XCTUnwrap(result, store.status)
        defer { try? FileManager.default.removeItem(at: folder) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ReviewManifest.self, from: Data(contentsOf: folder.appendingPathComponent("feedback.json")))
        let evidence = try XCTUnwrap(manifest.motionEvidence?.first)
        XCTAssertEqual(evidence.sourceTimes.count, 4)
        XCTAssertEqual(evidence.sourceTimes.first ?? -1, 0.5, accuracy: 0.035)
        XCTAssertTrue(zip(evidence.sourceTimes, evidence.sourceTimes.dropFirst()).allSatisfy { $0 < $1 })
        let clip = AVURLAsset(url: folder.appendingPathComponent(evidence.clipFile))
        let clipDuration = try await clip.load(.duration).seconds
        XCTAssertEqual(clipDuration, 1.2, accuracy: 0.05)
        XCTAssertNotNil(NSImage(contentsOf: folder.appendingPathComponent(evidence.sequenceFile)))
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent == evidence.sequenceFile })
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent == evidence.clipFile })
        let notes = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(notes.contains(evidence.sequenceFile))
        XCTAssertTrue(notes.contains(evidence.clipFile))
        XCTAssertGreaterThan(intervals.count, 2)
        let maximum = intervals.max() ?? 0
        print(String(format: "FrameNote main-thread heartbeat during motion export: max %.1f ms (%d samples)", maximum, intervals.count))
        XCTAssertLessThan(maximum, 150, "Decoding, image encoding and clip export must leave the UI responsive.")
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_REVIEW_SNAPSHOT"] {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(evidence.sequenceFile), to: URL(fileURLWithPath: path + "-sequence-\(UUID().uuidString.prefix(4)).png"))
        }
    }

    @MainActor
    func testCopyAndPlaybackControlsRespondUnder150Milliseconds() throws {
        let store = ReviewStore()
        store.player = AVPlayer()
        store.duration = 8
        store.marks = (0..<60).map {
            ReviewMark(kind: .point, start: UnitPoint2D(x: 0.3, y: 0.4), time: Double($0) / 10, note: "Move this element \($0)")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var samples: [Double] = []
        for index in 0..<20 {
            let start = ProcessInfo.processInfo.systemUptime
            store.setPlaybackRate(index.isMultiple(of: 2) ? 0.25 : 0.5)
            store.togglePlayback()
            store.seek(to: Double(index) / 10)
            store.copyForAgent(pasteboard: pasteboard)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let worst = samples.max() ?? 0
        print(String(format: "FrameNote control + copy handler: max %.1f ms", worst))
        XCTAssertLessThan(worst, 150)
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("Move this element 59"))
        XCTAssertNil(store.lastExport, "Copy must not trigger synchronous media export.")
    }

    @MainActor
    func testZoomCentersChosenRegionAndPreservesPanningBetweenUpdates() async throws {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ReviewViewport(documentSize: CGSize(width: 2400, height: 1600),
                                                        imageSize: CGSize(width: 2400, height: 1600),
                                                        center: UnitPoint2D(x: 0.75, y: 0.7), zoom: 4) {
            Color.white.frame(width: 2400, height: 1600)
        })
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try XCTUnwrap(find(CenteredReviewScrollView.self, in: host))
        XCTAssertEqual(scroll.contentView.bounds.midX, 1800, accuracy: 4)
        XCTAssertEqual(scroll.contentView.bounds.midY, 1120, accuracy: 4)
        scroll.contentView.scroll(to: CGPoint(x: 800, y: 600))
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minX, 800, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 600, accuracy: 1)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the player")
    }

    @MainActor
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews { if let result = find(type, in: child) { return result } }
        return nil
    }
}

enum MotionFixture {
    static func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("framenote-motion-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Fixture", code: 1) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(CGColor(red: 0.06, green: 0.42, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 40 + i * 3, y: 80, width: 180, height: 150))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 30)) else {
                throw writer.error ?? NSError(domain: "Fixture", code: 2)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
}
