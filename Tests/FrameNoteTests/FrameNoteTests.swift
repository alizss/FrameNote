import AppKit
import XCTest
@testable import FrameNoteCore

final class FrameNoteTests: XCTestCase {
    func testMeasurementsUseOriginalScreenshotPixels() throws {
        let mark = ReviewMark(
            kind: .measure,
            start: UnitPoint2D(x: 0.25, y: 0.5),
            end: UnitPoint2D(x: 0.75, y: 0.5),
            note: "Match this gap"
        )
        XCTAssertEqual(mark.distanceInPixels(width: 1000, height: 600), 500)
        let manifest = ReviewManifest(
            createdAt: Date(timeIntervalSince1970: 0),
            title: "Spacing review",
            imageWidth: 1000,
            imageHeight: 600,
            referenceImageFile: nil,
            marks: [mark]
        )
        let decoded = try JSONDecoder().decode(ReviewManifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.marks, [mark])
        XCTAssertTrue(ReviewMarkdown.generate(decoded).contains("≈500 px"))
        XCTAssertTrue(ReviewMarkdown.generate(decoded).contains("Match this gap"))
    }

    func testPointsStayInsideCapturedImage() {
        XCTAssertEqual(UnitPoint2D(x: -2, y: 1.5), UnitPoint2D(x: 0, y: 1))
    }

    @MainActor
    func testExportContainsAnnotatedImageAndStructuredFeedback() throws {
        let image = NSImage(size: NSSize(width: 80, height: 50), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5), note: "Center this")
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let folder = try ReviewExporter.export(screenshot: image, reference: nil,
                                               title: "Test review", marks: [mark], into: parent)
        let original = try Data(contentsOf: folder.appendingPathComponent("screenshot.png"))
        let annotated = try Data(contentsOf: folder.appendingPathComponent("annotated.png"))
        let json = try Data(contentsOf: folder.appendingPathComponent("feedback.json"))
        let feedback = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertNotEqual(original, annotated)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ReviewManifest.self, from: json).marks, [mark])
        XCTAssertTrue(feedback.contains("Center this"))
    }
}
