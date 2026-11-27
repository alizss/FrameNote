import AppKit
import SwiftUI
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class AnnotationEditingTests: XCTestCase {
    func testMovementClampsWholeShapeAndPreservesCommentMetadata() {
        var mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.2, y: 0.3), end: UnitPoint2D(x: 0.6, y: 0.7), time: 2, endTime: 3, note: "Keep spacing")
        mark.isApproved = true
        let moved = MarkEditing.edited(mark, handle: .move, from: UnitPoint2D(x: 0.3, y: 0.4), to: UnitPoint2D(x: 1, y: 1))
        XCTAssertEqual(moved.start.x, 0.6, accuracy: 0.001)
        XCTAssertEqual(moved.end?.x, 1)
        XCTAssertEqual(moved.start.y, 0.6, accuracy: 0.001)
        XCTAssertEqual(moved.end?.y, 1)
        XCTAssertEqual(moved.note, mark.note)
        XCTAssertEqual(moved.id, mark.id)
        XCTAssertEqual(moved.time, 2)
        XCTAssertEqual(moved.endTime, 3)
        XCTAssertTrue(moved.isApproved)
    }

    func testAllBoxCornersResizeAndLineBodyIsSelectable() {
        let mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.6, y: 0.7), end: UnitPoint2D(x: 0.2, y: 0.3), note: "Reversed box")
        XCTAssertEqual(MarkEditing.handle(for: mark, at: UnitPoint2D(x: 0.6, y: 0.3), size: CGSize(width: 1000, height: 1000), selected: true), .topRight)
        let resized = MarkEditing.edited(mark, handle: .topRight, from: UnitPoint2D(x: 0.6, y: 0.3), to: UnitPoint2D(x: 0.8, y: 0.1))
        XCTAssertEqual(resized.start, UnitPoint2D(x: 0.2, y: 0.1))
        XCTAssertEqual(resized.end, UnitPoint2D(x: 0.8, y: 0.7))
        let arrow = ReviewMark(kind: .arrow, start: UnitPoint2D(x: 0.2, y: 0.2), end: UnitPoint2D(x: 0.8, y: 0.8), note: "Arrow")
        XCTAssertEqual(MarkEditing.handle(for: arrow, at: UnitPoint2D(x: 0.5, y: 0.5), size: CGSize(width: 800, height: 600), selected: false), .move)
        XCTAssertNil(MarkEditing.handle(for: arrow, at: UnitPoint2D(x: 0.1, y: 0.8), size: CGSize(width: 800, height: 600), selected: true))
    }

    @MainActor
    func testNativeDragsMoveAndResizeExistingAnnotationWithOneUndoEach() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        store.screenshot = NSImage(size: NSSize(width: 1000, height: 600), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.2, y: 0.2), end: UnitPoint2D(x: 0.6, y: 0.6), note: "Existing box")
        store.marks = [mark]
        let window = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 1180, height: 800), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, automaticallyFocusComments: false, detailedEditing: true))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        func findInput(_ view: NSView) -> AnnotationInputView? {
            if let input = view as? AnnotationInputView { return input }
            return view.subviews.compactMap { findInput($0) }.first
        }
        let input = try XCTUnwrap(findInput(host))
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
            let location = input.convert(NSPoint(x: x * input.bounds.width, y: y * input.bounds.height), to: nil)
            return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        input.mouseDown(with: event(.leftMouseDown, 0.4, 0.4))
        input.mouseUp(with: event(.leftMouseUp, 0.4, 0.4))
        try await Task.sleep(for: .milliseconds(150))
        input.mouseDown(with: event(.leftMouseDown, 0.4, 0.4))
        input.mouseDragged(with: event(.leftMouseDragged, 0.5, 0.5))
        input.mouseUp(with: event(.leftMouseUp, 0.5, 0.5))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks[0].start.x, 0.3, accuracy: 0.002)
        XCTAssertEqual(store.marks[0].end?.x ?? 0, 0.7, accuracy: 0.002)
        store.undoAnnotations()
        XCTAssertEqual(store.marks, [mark])
        store.redoAnnotations()
        try await Task.sleep(for: .milliseconds(100))
        input.mouseDown(with: event(.leftMouseDown, 0.7, 0.7))
        input.mouseDragged(with: event(.leftMouseDragged, 0.85, 0.8))
        input.mouseUp(with: event(.leftMouseUp, 0.85, 0.8))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks[0].end?.x ?? 0, 0.85, accuracy: 0.002)
        XCTAssertEqual(store.marks[0].end?.y ?? 0, 0.8, accuracy: 0.002)
        store.undoAnnotations()
        XCTAssertEqual(store.marks[0].end?.x ?? 0, 0.7, accuracy: 0.002)
        let defaults = UserDefaults.standard
        let oldDetails = defaults.object(forKey: "reviewDetailsOpen")
        let oldComments = defaults.object(forKey: "reviewCommentsOpen")
        defer {
            if let oldDetails { defaults.set(oldDetails, forKey: "reviewDetailsOpen") } else { defaults.removeObject(forKey: "reviewDetailsOpen") }
            if let oldComments { defaults.set(oldComments, forKey: "reviewCommentsOpen") } else { defaults.removeObject(forKey: "reviewCommentsOpen") }
        }
        let expanded = input.bounds.size
        defaults.set(false, forKey: "reviewDetailsOpen")
        defaults.set(false, forKey: "reviewCommentsOpen")
        try await Task.sleep(for: .milliseconds(250))
        let enlarged = try XCTUnwrap(findInput(host))
        XCTAssertGreaterThan(enlarged.bounds.width, expanded.width, "Hiding the comments should expand the canvas")
        XCTAssertGreaterThan(enlarged.bounds.height, expanded.height, "Collapsing feedback and sharing should expand the canvas")
        XCTAssertEqual(store.marks.count, 1)
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_EDITING_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
