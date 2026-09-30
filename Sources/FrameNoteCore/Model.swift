import Foundation

public enum MarkKind: String, Codable, CaseIterable, Identifiable {
    case point = "Pin"
    case arrow = "Arrow"
    case measure = "Measure gap"
    case guideHorizontal = "Horizontal guide"
    case guideVertical = "Vertical guide"
    case focus = "Focus area"
    case move = "Move here"
    case compareGaps = "Compare gaps"

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
    public var secondStart: UnitPoint2D?
    public var secondEnd: UnitPoint2D?
    public var time: Double?
    public var note: String

    public init(id: UUID = UUID(), kind: MarkKind, start: UnitPoint2D, end: UnitPoint2D? = nil,
                secondStart: UnitPoint2D? = nil, secondEnd: UnitPoint2D? = nil,
                time: Double? = nil, note: String) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.secondStart = secondStart
        self.secondEnd = secondEnd
        self.time = time
        self.note = note
    }

    public func distanceInPixels(width: Int, height: Int) -> Double? {
        guard let end else { return nil }
        let dx = (end.x - start.x) * Double(width)
        let dy = (end.y - start.y) * Double(height)
        return hypot(dx, dy)
    }

    public func secondDistanceInPixels(width: Int, height: Int) -> Double? {
        guard let secondStart, let secondEnd else { return nil }
        let dx = (secondEnd.x - secondStart.x) * Double(width)
        let dy = (secondEnd.y - secondStart.y) * Double(height)
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
    public var videoFile: String?
    public var loopStart: Double?
    public var loopEnd: Double?
    public var marks: [ReviewMark]

    public init(createdAt: Date, title: String, imageWidth: Int, imageHeight: Int,
                referenceImageFile: String?, videoFile: String? = nil,
                loopStart: Double? = nil, loopEnd: Double? = nil, marks: [ReviewMark]) {
        self.schemaVersion = 1
        self.createdAt = createdAt
        self.title = title
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.imageFile = "screenshot.png"
        self.annotatedImageFile = "annotated.png"
        self.referenceImageFile = referenceImageFile
        self.videoFile = videoFile
        self.loopStart = loopStart
        self.loopEnd = loopEnd
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
        if let videoFile = manifest.videoFile {
            lines[2] = "Source video: `\(videoFile)`"
        }
        if let start = manifest.loopStart, let end = manifest.loopEnd {
            lines.append("Loop: \(timecode(start))–\(timecode(end))")
        }
        lines += ["", "Image: \(manifest.imageWidth) × \(manifest.imageHeight) pixels", "", "## Feedback", ""]
        if manifest.marks.isEmpty {
            lines.append("No marks added.")
        }
        for (index, mark) in manifest.marks.enumerated() {
            let position = "(\(Int((mark.start.x * 100).rounded()))%, \(Int((mark.start.y * 100).rounded()))%)"
            let time = mark.time.map { " at \(timecode($0))" } ?? ""
            let distance = mark.kind == .measure
                ? mark.distanceInPixels(width: manifest.imageWidth, height: manifest.imageHeight).map { " · ≈\(Int($0.rounded())) px" } ?? ""
                : ""
            let note = mark.note.trimmingCharacters(in: .whitespacesAndNewlines)
            var detail = ""
            if mark.kind == .compareGaps,
               let first = mark.distanceInPixels(width: manifest.imageWidth, height: manifest.imageHeight),
               let second = mark.secondDistanceInPixels(width: manifest.imageWidth, height: manifest.imageHeight) {
                detail = " · A ≈\(Int(first.rounded())) px, B ≈\(Int(second.rounded())) px (Δ \(Int(abs(first - second).rounded())) px)"
            }
            var frame = manifest.videoFile == nil ? "" : " · `moment-\(String(format: "%02d", index + 1))-marked.png`"
            if mark.kind == .focus {
                let focusFile = manifest.videoFile == nil
                    ? String(format: "focus-%02d.png", index + 1)
                    : String(format: "moment-%02d-focus.png", index + 1)
                frame += " · Focus crop: `\(focusFile)`"
            }
            lines.append("\(index + 1). **\(mark.kind.rawValue)** at \(position)\(time)\(distance)\(detail)\(frame): \(note.isEmpty ? "Describe the change here." : note)")
        }
        lines += ["", "Marks use coordinates relative to the original screenshot. Review the image and notes together; measurements are screenshot pixels, not necessarily UI points.", ""]
        return lines.joined(separator: "\n")
    }

    private static func timecode(_ seconds: Double) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let minutes = totalMilliseconds / 60_000
        let wholeSeconds = (totalMilliseconds / 1000) % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d.%03d", minutes, wholeSeconds, milliseconds)
    }
}
