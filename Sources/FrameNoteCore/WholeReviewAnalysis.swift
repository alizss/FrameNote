import Foundation

public struct WholeReviewAnalysis: Codable, Sendable {
    public var summary: String
    public var findings: [AIReviewFinding]

    public func marks(duration: Double, isVideo: Bool) -> [ReviewMark] {
        findings.prefix(8).compactMap { finding in
            guard !finding.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = isVideo ? finding.startTime.flatMap { $0.isFinite && $0 >= 0 && $0 < duration ? $0 : nil } : nil
            // An unlocated video observation belongs in the summary, not at an invented timestamp.
            if isVideo && start == nil { return nil }
            let end = finding.endTime.flatMap { value in start.flatMap { value.isFinite && value > $0 ? min(duration, value) : nil } }
            let rect = finding.rect.flatMap { values -> [Double]? in
                guard values.count == 4, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                      values[2] > 0, values[3] > 0, values[0] + values[2] <= 1, values[1] + values[3] <= 1 else { return nil }
                return values
            }
            var mark = ReviewMark(kind: rect == nil ? .point : .focus,
                start: rect.map { UnitPoint2D(x: $0[0], y: $0[1]) } ?? UnitPoint2D(x: 0.5, y: 0.5),
                end: rect.map { UnitPoint2D(x: $0[0] + $0[2], y: $0[1] + $0[3]) },
                time: start, endTime: end, note: finding.note)
            mark.aiGenerated = true
            // No rectangle supplied: a timeline comment, without an invented pin on the picture.
            mark.wholeMedia = rect == nil ? true : nil
            return mark
        }
    }
}

public struct AIReviewFinding: Codable, Sendable {
    public var note: String
    public var startTime: Double?
    public var endTime: Double?
    /// Normalized x, y, width, height, top-left origin. Omit when uncertain.
    public var rect: [Double]?
}
