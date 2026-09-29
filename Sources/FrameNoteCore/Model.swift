import Foundation

public enum MarkKind: String, Codable, CaseIterable, Identifiable {
    case point = "Point"
    case arrow = "Arrow"
    case measure = "Measure"

    public var id: String { rawValue }
}

public struct UnitPoint2D: Codable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}

public struct ReviewMark: Codable, Identifiable, Equatable {
    public var id: UUID
    public var kind: MarkKind
    public var start: UnitPoint2D
    public var end: UnitPoint2D?
    public var note: String

    public init(id: UUID = UUID(), kind: MarkKind, start: UnitPoint2D, end: UnitPoint2D? = nil, note: String) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.note = note
    }

    public func distanceInPixels(width: Int, height: Int) -> Double? {
        guard let end else { return nil }
        let dx = (end.x - start.x) * Double(width)
        let dy = (end.y - start.y) * Double(height)
        return hypot(dx, dy)
    }
}

public struct ReviewManifest: Codable {
    public var schemaVersion: Int
    public var createdAt: Date
    public var title: String
    public var imageWidth: Int
    public var imageHeight: Int
    public var imageFile: String
    public var annotatedImageFile: String
    public var referenceImageFile: String?
    public var marks: [ReviewMark]

    public init(createdAt: Date, title: String, imageWidth: Int, imageHeight: Int,
                referenceImageFile: String?, marks: [ReviewMark]) {
        self.schemaVersion = 1
        self.createdAt = createdAt
        self.title = title
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageFile = "screenshot.png"
        self.annotatedImageFile = "annotated.png"
        self.referenceImageFile = referenceImageFile
        self.marks = marks
    }
}

public enum ReviewMarkdown {
    public static func generate(_ manifest: ReviewManifest) -> String {
        var lines = [
            "# \(manifest.title)",
            "",
            "Source: `screenshot.png`  ·  Marked view: `annotated.png`",
        ]
        if manifest.referenceImageFile != nil {
            lines.append("Reference: `reference.png`")
        }
        lines += ["", "Image: \(manifest.imageWidth) × \(manifest.imageHeight) pixels", "", "## Feedback", ""]
        if manifest.marks.isEmpty {
            lines.append("No marks added.")
        }
        for (index, mark) in manifest.marks.enumerated() {
            let position = "(\(Int((mark.start.x * 100).rounded()))%, \(Int((mark.start.y * 100).rounded()))%)"
            let distance = mark.kind == .measure
                ? mark.distanceInPixels(width: manifest.imageWidth, height: manifest.imageHeight).map { " · ≈\(Int($0.rounded())) px" } ?? ""
                : ""
            let note = mark.note.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(index + 1). **\(mark.kind.rawValue)** at \(position)\(distance): \(note.isEmpty ? "Describe the change here." : note)")
        }
        lines += ["", "Marks use coordinates relative to the original screenshot. Review the image and notes together; measurements are screenshot pixels, not necessarily UI points.", ""]
        return lines.joined(separator: "\n")
    }
}
