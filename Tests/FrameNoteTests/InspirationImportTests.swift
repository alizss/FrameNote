import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class InspirationImportTests: XCTestCase {
    func testDownloadedVideoWithTemporarySuffixUsesResponseMediaType() async throws {
        let fixture = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let source = URL(string: "https://example.com/download?id=123")!
        let imported = try await InspirationImporter.shared.importMedia(source, download: { request in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: fixture, to: temporary)
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/quicktime"])!)
        })
        defer { try? FileManager.default.removeItem(at: imported.url) }
        XCTAssertTrue(imported.isVideo)
        XCTAssertEqual(imported.url.pathExtension, "mov")
        XCTAssertGreaterThan(imported.duration, 0)
    }

    @MainActor
    func testRemoteMP4ImportsPlaysAndExportsEvidence() async throws {
        guard let address = ProcessInfo.processInfo.environment["FRAMENOTE_TEST_VIDEO_URL"], let url = URL(string: address) else {
            throw XCTSkip("Set FRAMENOTE_TEST_VIDEO_URL to check a live media URL")
        }
        let store = ReviewStore()
        try await store.importInspiration(url, source: address)
        let local = try XCTUnwrap(store.videoURL)
        defer { try? FileManager.default.removeItem(at: local) }
        for _ in 0..<100 {
            if store.player?.currentItem?.status == .readyToPlay && store.duration > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(store.player?.currentItem?.status, .readyToPlay)
        XCTAssertGreaterThan(store.duration, 0)
        XCTAssertEqual(store.title, address)
        XCTAssertTrue(store.marks[0].note.isEmpty)
        XCTAssertEqual(store.marks[0].inspirations?.first?.value, address)
        // Extract every analysis frame from the real clip without sending it to an AI service.
        let report = try await DesignerAssistant.analyze(key: "unused-test-key", screenshot: nil,
            videoURL: local, start: 0, end: store.duration, duration: store.duration,
            focus: nil, note: "Study the motion", inspirations: [], send: { request in
                let data = Data("{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Review prepared\"}]}]}".utf8)
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        XCTAssertEqual(report, "Review prepared")
        let prepared = await store.prepareFeedback()
        let folder = try XCTUnwrap(prepared, store.status)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent.hasSuffix("-sequence.png") })
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent.hasSuffix("-clip.mov") })
    }

    @MainActor
    func testAnimatedGIFBecomesVideoWithPreservedDuration() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: input) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, "com.compuserve.gif" as CFString, 3, nil))
        for (index, delay) in [0.1, 0.2, 0.3].enumerated() {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.setFillColor(CGColor(gray: Double(index) / 3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let imported = try await InspirationImporter.shared.importMedia(input)
        defer { try? FileManager.default.removeItem(at: imported.url) }
        XCTAssertTrue(imported.isVideo)
        XCTAssertEqual(imported.duration, 0.6, accuracy: 0.04)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: imported.url))
        let frame = try generator.copyCGImage(at: CMTime(seconds: 0.35, preferredTimescale: 600), actualTime: nil)
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 40)
        let store = ReviewStore()
        store.openVideo(at: imported.url)
        store.marks = [ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.05, y: 0.05), end: UnitPoint2D(x: 0.95, y: 0.95), time: 0, endTime: imported.duration, note: "Study this motion reference")]
        let prepared = await store.prepareFeedback()
        let folder = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent.hasSuffix("-sequence.png") })
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent.hasSuffix("-clip.mov") })
    }

    @MainActor
    func testImageImportSeedsReferenceCommentAndSharesInstructions() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let store = ReviewStore()
        try await store.importInspiration(input, source: "Example reference")
        XCTAssertNotNil(store.screenshot)
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.title, "Example reference")
        XCTAssertTrue(store.marks[0].note.isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        store.copyForAgent(pasteboard: board)
        XCTAssertTrue(board.string(forType: .string)?.contains("timestamped motion sequence") == true)
    }

    @MainActor
    func testSelectingCommentAnimatesZoomToArea() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        store.screenshot = NSImage(size: NSSize(width: 1000, height: 600), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.2, y: 0.2), end: UnitPoint2D(x: 0.4, y: 0.4), note: "Look here")
        store.marks = [mark]
        let window = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 1180, height: 800), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, detailedEditing: true))
        host.sizingOptions = []; window.contentView = host; window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let found = view as? T { return found }
            return view.subviews.compactMap { find(type, in: $0) }.first
        }
        try await Task.sleep(for: .milliseconds(250))
        let input = try XCTUnwrap(find(AnnotationInputView.self, in: host))
        let location = input.convert(NSPoint(x: input.bounds.width * 0.3, y: input.bounds.height * 0.3), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent { NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)! }
        input.mouseDown(with: event(.leftMouseDown)); input.mouseUp(with: event(.leftMouseUp))
        let scroll = try XCTUnwrap(find(CenteredReviewScrollView.self, in: host))
        for _ in 0..<60 {
            if scroll.currentZoom > 2.8 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThan(scroll.currentZoom, 2)
        XCTAssertEqual(store.marks, [mark], "Focusing should not create or modify annotations")
    }
}
