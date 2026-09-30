import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class ReviewInteractionTests: XCTestCase {
    @MainActor
    func testReviewAcceptsPinTypingAndMeasuredDragWithoutMovingWindow() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        let panel = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 360, height: 154),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 360, height: 154)
        panel.contentMaxSize = panel.contentMinSize
        let host = NSHostingView(rootView: ContentView(store: store))
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(250))

        store.screenshot = Self.exampleImage()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThanOrEqual(panel.frame.width, 760)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 500)

        let input = try XCTUnwrap(Self.inputView(in: host))
        XCTAssertGreaterThan(input.bounds.width, 500, "The preview should use the expanded workspace.")
        let originalFrame = panel.frame
        let location = NSPoint(x: input.bounds.width * 0.25, y: input.bounds.height * 0.3)
        let hostPoint = input.convert(location, to: host)
        XCTAssertTrue(host.hitTest(hostPoint) === input, "Annotation surface must receive the click.")
        input.mouseDown(with: Self.event(.leftMouseDown, at: location, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: location, in: input))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.marks.first).start.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.marks.first).start.y, 0.3, accuracy: 0.001)

        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView,
                                  "Placing a mark should focus its comment field.")
        editor.insertText("Match the spacing here.", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.marks.first?.note, "Match the spacing here.")

        store.tool = .measure
        try await Task.sleep(for: .milliseconds(100))
        let start = NSPoint(x: input.bounds.width * 0.25, y: input.bounds.height * 0.6)
        let end = NSPoint(x: input.bounds.width * 0.75, y: input.bounds.height * 0.6)
        input.mouseDown(with: Self.event(.leftMouseDown, at: start, in: input))
        input.mouseDragged(with: Self.event(.leftMouseDragged, at: end, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: end, in: input))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 2)
        let measurement = try XCTUnwrap(store.marks.last)
        XCTAssertEqual(measurement.kind, .measure)
        XCTAssertEqual(try XCTUnwrap(measurement.distanceInPixels(width: 1000, height: 600)), 500, accuracy: 0.01)
        XCTAssertEqual(panel.frame, originalFrame, "Drawing must not drag the widget.")

        // A synthetic fixture only: useful for checking the actual hosted review layout.
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_REVIEW_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor
    func testAnnotationSurfaceWinsHitTestingAboveNativeVideoPlayer() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        store.videoURL = URL(fileURLWithPath: "/tmp/framenote-input-test.mov")
        store.videoSize = CGSize(width: 1000, height: 600)
        store.player = AVPlayer()
        let panel = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 1040, height: 700),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store))
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(250))
        let input = try XCTUnwrap(Self.inputView(in: host))
        let location = NSPoint(x: input.bounds.midX, y: input.bounds.midY)
        XCTAssertTrue(host.hitTest(input.convert(location, to: host)) === input)
        input.mouseDown(with: Self.event(.leftMouseDown, at: location, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: location, in: input))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertNotNil(store.marks.first?.time)
    }

    @MainActor
    private static func inputView(in view: NSView) -> AnnotationInputView? {
        if let view = view as? AnnotationInputView { return view }
        for child in view.subviews {
            if let match = inputView(in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor
    private static func exampleImage() -> NSImage {
        NSImage(size: NSSize(width: 1000, height: 600), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .semibold),
                                                      .foregroundColor: NSColor.black]
            ("Account settings" as NSString).draw(at: NSPoint(x: 70, y: 495), withAttributes: title)
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 70, y: 135, width: 850, height: 305), xRadius: 16, yRadius: 16).fill()
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22),
                                                     .foregroundColor: NSColor.black]
            ("Profile details" as NSString).draw(at: NSPoint(x: 100, y: 370), withAttributes: body)
            ("Name     Alex Morgan" as NSString).draw(at: NSPoint(x: 100, y: 290), withAttributes: body)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 710, y: 55, width: 210, height: 55), xRadius: 10, yRadius: 10).fill()
            ("Save changes" as NSString).draw(at: NSPoint(x: 740, y: 70), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
            return true
        }
    }
}
