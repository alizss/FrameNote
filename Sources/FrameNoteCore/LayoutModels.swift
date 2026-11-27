import CoreGraphics
import Foundation

/// A box found in a screenshot. Rectangles are normalized (0…1, top-left origin) against the full source image.
public struct LayoutElement: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// A surface (button, chip, card) that holds other elements.
        case container
        /// Text, an icon or any other content.
        case content
    }

    public var id: Int
    public var kind: Kind
    public var rect: CGRect
    public var parent: Int?
}

/// An edge or centre line shared by several elements.
public struct LayoutGuide: Equatable, Sendable {
    public enum Axis: String, Sendable { case vertical, horizontal }
    public var axis: Axis
    /// Normalized position across the source image.
    public var position: Double
    public var count: Int
}

public struct LayoutSegment: Equatable, Sendable {
    public var from: CGPoint
    public var to: CGPoint
}

/// One UI/UX problem, measured from the pixels.
public struct LayoutFinding: Equatable, Sendable, Identifiable {
    public enum Category: String, Sendable { case padding, spacing, alignment, sizing, contrast }

    public var id = UUID()
    public var category: Category
    /// 3 is clearly wrong, 1 is a polish detail.
    public var severity: Int
    public var title: String
    /// Written for the person (or coding agent) who has to fix it: what is wrong, the numbers, and the fix.
    public var note: String
    /// Normalized area to highlight.
    public var rect: CGRect
    /// For uneven spacing: the reference gap and the gap that deviates.
    public var gapA: LayoutSegment?
    public var gapB: LayoutSegment?
}

public struct LayoutAnalysis: Sendable {
    public var elements: [LayoutElement]
    public var guides: [LayoutGuide]
    public var findings: [LayoutFinding]
    /// The region that was scanned, normalized to the source image.
    public var region: CGRect
    /// True when the picture was too detailed to measure completely.
    public var truncated: Bool

    public static let empty = LayoutAnalysis(elements: [], guides: [], findings: [],
                                             region: CGRect(x: 0, y: 0, width: 1, height: 1), truncated: false)
}

/// The wireframe drawn over a screenshot or video frame.
public struct LayoutOverlay: Equatable, Sendable {
    /// Video time the overlay belongs to; nil for still images.
    public var time: Double?
    public var elements: [LayoutElement]
    public var guides: [LayoutGuide]

    public init(time: Double?, elements: [LayoutElement], guides: [LayoutGuide]) {
        self.time = time; self.elements = elements; self.guides = guides
    }

    public init(_ analysis: LayoutAnalysis, time: Double?) {
        self.init(time: time, elements: analysis.elements, guides: analysis.guides)
    }

    public func isVisible(at currentTime: Double?) -> Bool {
        guard let time, let currentTime else { return true }
        return abs(time - currentTime) < 0.18
    }
}
