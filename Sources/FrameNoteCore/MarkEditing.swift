import Foundation
import CoreGraphics

public enum MarkEditHandle: Equatable, Sendable {
    case move, start, end, topRight, bottomLeft, secondStart, secondEnd
}

/// Geometry is normalized; the hit target stays the same size at every zoom level.
public enum MarkEditing {
    public static func handle(for mark: ReviewMark, at point: UnitPoint2D, size: CGSize, selected: Bool) -> MarkEditHandle? {
        func near(_ anchor: UnitPoint2D) -> Bool {
            hypot((point.x - anchor.x) * size.width, (point.y - anchor.y) * size.height) <= 10
        }
        if selected {
            if mark.kind == .focus, let end = mark.end {
                let lo = UnitPoint2D(x: min(mark.start.x, end.x), y: min(mark.start.y, end.y))
                let hi = UnitPoint2D(x: max(mark.start.x, end.x), y: max(mark.start.y, end.y))
                if near(lo) { return .start }
                if near(hi) { return .end }
                if near(UnitPoint2D(x: hi.x, y: lo.y)) { return .topRight }
                if near(UnitPoint2D(x: lo.x, y: hi.y)) { return .bottomLeft }
            } else if mark.end != nil {
                if near(mark.start) { return .start }
                if let end = mark.end, near(end) { return .end }
                if let second = mark.secondStart, near(second) { return .secondStart }
                if let second = mark.secondEnd, near(second) { return .secondEnd }
            }
        }
        if near(mark.start) { return .move }
        if mark.kind == .focus, let end = mark.end {
            return point.x >= min(mark.start.x, end.x) && point.x <= max(mark.start.x, end.x)
                && point.y >= min(mark.start.y, end.y) && point.y <= max(mark.start.y, end.y) ? .move : nil
        }
        if mark.kind == .guideHorizontal, abs(point.y - mark.start.y) * size.height <= 8 { return .move }
        if mark.kind == .guideVertical, abs(point.x - mark.start.x) * size.width <= 8 { return .move }
        func nearSegment(_ a: UnitPoint2D, _ b: UnitPoint2D) -> Bool {
            let dx = (b.x - a.x) * size.width, dy = (b.y - a.y) * size.height
            let px = (point.x - a.x) * size.width, py = (point.y - a.y) * size.height
            let t = min(1, max(0, (px * dx + py * dy) / max(1, dx * dx + dy * dy)))
            return hypot(px - t * dx, py - t * dy) <= 8
        }
        if let end = mark.end, nearSegment(mark.start, end) { return .move }
        if let a = mark.secondStart, let b = mark.secondEnd, nearSegment(a, b) { return .move }
        return nil
    }

    public static func edited(_ mark: ReviewMark, handle: MarkEditHandle, from origin: UnitPoint2D, to point: UnitPoint2D) -> ReviewMark {
        var result = mark
        if handle == .move {
            let points = [mark.start, mark.end, mark.secondStart, mark.secondEnd].compactMap { $0 }
            let dx = min(1 - (points.map(\.x).max() ?? 1), max(-(points.map(\.x).min() ?? 0), point.x - origin.x))
            let dy = min(1 - (points.map(\.y).max() ?? 1), max(-(points.map(\.y).min() ?? 0), point.y - origin.y))
            func moved(_ p: UnitPoint2D) -> UnitPoint2D { UnitPoint2D(x: p.x + dx, y: p.y + dy) }
            result.start = moved(mark.start); result.end = mark.end.map(moved)
            result.secondStart = mark.secondStart.map(moved); result.secondEnd = mark.secondEnd.map(moved)
        } else if mark.kind == .focus, let end = mark.end {
            var lo = UnitPoint2D(x: min(mark.start.x, end.x), y: min(mark.start.y, end.y))
            var hi = UnitPoint2D(x: max(mark.start.x, end.x), y: max(mark.start.y, end.y))
            switch handle {
            case .start: lo = point
            case .end: hi = point
            case .topRight: hi.x = point.x; lo.y = point.y
            case .bottomLeft: lo.x = point.x; hi.y = point.y
            default: break
            }
            result.start = UnitPoint2D(x: min(lo.x, hi.x), y: min(lo.y, hi.y))
            result.end = UnitPoint2D(x: max(lo.x, hi.x), y: max(lo.y, hi.y))
        } else {
            switch handle {
            case .start: result.start = point
            case .end: result.end = point
            case .secondStart: result.secondStart = point
            case .secondEnd: result.secondEnd = point
            default: break
            }
        }
        return result
    }
}
