import AppKit
import FrameNoteCore
import SwiftUI

// Own the mouse sequence above AVPlayerView so both clicks and drags reach
// annotation tools, rather than the native player or window-background drag.
@MainActor
final class AnnotationInputView: NSView {
    var onStart: () -> Void = {}
    var onChange: (UnitPoint2D, UnitPoint2D) -> Void = { _, _ in }
    var onFinish: (UnitPoint2D, UnitPoint2D) -> Void = { _, _ in }
    private var start: UnitPoint2D?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = normalizedPoint(for: event)
        start = point
        onStart()
        onChange(point, point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onChange(start, normalizedPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        onFinish(start, normalizedPoint(for: event))
    }

    private func normalizedPoint(for event: NSEvent) -> UnitPoint2D {
        let point = convert(event.locationInWindow, from: nil)
        return UnitPoint2D(x: point.x / max(bounds.width, 1),
                           y: point.y / max(bounds.height, 1))
    }
}

struct AnnotationInputSurface: NSViewRepresentable {
    var onStart: () -> Void
    var onChange: (UnitPoint2D, UnitPoint2D) -> Void
    var onFinish: (UnitPoint2D, UnitPoint2D) -> Void

    func makeNSView(context: Context) -> AnnotationInputView { AnnotationInputView() }
    func updateNSView(_ view: AnnotationInputView, context: Context) {
        view.onStart = onStart
        view.onChange = onChange
        view.onFinish = onFinish
    }
}

struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
