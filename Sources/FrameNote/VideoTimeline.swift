import AppKit
import FrameNoteCore
import SwiftUI

struct VideoTimeline: NSViewRepresentable {
    let currentTime: Double
    let duration: Double
    let selection: ClosedRange<Double>?
    let selecting: Bool
    let marks: [ReviewMark]
    var onSeek: (Double) -> Void
    var onRange: (ClosedRange<Double>) -> Void

    func makeNSView(context: Context) -> VideoTimelineView { VideoTimelineView() }
    func updateNSView(_ view: VideoTimelineView, context: Context) {
        view.currentTime = currentTime
        view.duration = duration
        view.selection = selection
        view.selecting = selecting
        view.marks = marks
        view.onSeek = onSeek
        view.onRange = onRange
        view.needsDisplay = true
    }
}

// A single scrubber: drag normally to seek, or select a range and adjust its handles.
@MainActor final class VideoTimelineView: NSView {
    var currentTime: Double = 0
    var duration: Double = 0
    var selection: ClosedRange<Double>?
    var selecting = false
    var marks: [ReviewMark] = []
    var onSeek: (Double) -> Void = { _ in }
    var onRange: (ClosedRange<Double>) -> Void = { _ in }
    private var dragAnchor: Double?
    private var draft: ClosedRange<Double>?
    private var adjustingStart = false
    private var adjustingEnd = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: mid - 2, width: max(0, bounds.width - 16), height: 4), xRadius: 2, yRadius: 2).fill()
        for mark in marks {
            guard let time = mark.time else { continue }
            NSColor.systemBlue.withAlphaComponent(0.4).setFill()
            let a = x(time), b = x(mark.endTime ?? time)
            NSBezierPath(roundedRect: NSRect(x: a - 1, y: mid - 2, width: max(2, b - a), height: 4), xRadius: 2, yRadius: 2).fill()
        }
        if let range = draft ?? selection {
            let a = x(range.lowerBound), b = x(range.upperBound)
            NSColor.systemBlue.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: NSRect(x: a, y: mid - 9, width: max(1, b - a), height: 18), xRadius: 4, yRadius: 4).fill()
            NSColor.systemBlue.setFill()
            for edge in [a, b] {
                NSBezierPath(roundedRect: NSRect(x: edge - 3, y: mid - 9, width: 6, height: 18), xRadius: 3, yRadius: 3).fill()
            }
        }
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x(currentTime) - 1, y: mid - 7, width: 2, height: 14), xRadius: 1, yRadius: 1).fill()
    }

    private func x(_ time: Double) -> CGFloat {
        8 + min(1, max(0, time / max(duration, 0.001))) * max(1, bounds.width - 16)
    }
    private func time(_ event: NSEvent) -> Double {
        let location = convert(event.locationInWindow, from: nil)
        return min(1, max(0, (location.x - 8) / max(1, bounds.width - 16))) * duration
    }
    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        let t = time(event)
        let location = convert(event.locationInWindow, from: nil)
        adjustingStart = !selecting && selection.map { abs(location.x - x($0.lowerBound)) < 8 } == true
        adjustingEnd = !selecting && !adjustingStart && selection.map { abs(location.x - x($0.upperBound)) < 8 } == true
        dragAnchor = t
        if selecting { draft = t...t }
        else if !adjustingStart && !adjustingEnd { onSeek(t) }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let t = time(event)
        let minimum = min(0.1, duration)
        if selecting { draft = min(anchor, t)...max(anchor, t) }
        else if let selection, adjustingStart {
            draft = min(t, max(0, selection.upperBound - minimum))...selection.upperBound
        } else if let selection, adjustingEnd {
            draft = selection.lowerBound...max(t, min(duration, selection.lowerBound + minimum))
        } else { onSeek(t) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard dragAnchor != nil else { return }
        mouseDragged(with: event)
        if let draft {
            let minimum = min(0.1, duration)
            let start = min(draft.lowerBound, duration - minimum)
            onRange(start...max(draft.upperBound, start + minimum))
        }
        draft = nil; dragAnchor = nil; adjustingStart = false; adjustingEnd = false
        needsDisplay = true
    }
}
