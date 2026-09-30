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

    func testTimeRangePersistsAndAppearsOnlyDuringSelectedInterval() throws {
        let mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.2, y: 0.3),
                              end: UnitPoint2D(x: 0.7, y: 0.8), time: 2.5, endTime: 6.0,
                              note: "This transition jumps")
        XCTAssertFalse(mark.isVisible(at: 2))
        XCTAssertTrue(mark.isVisible(at: 2.5))
        XCTAssertTrue(mark.isVisible(at: 4))
        XCTAssertTrue(mark.isVisible(at: 6))
        XCTAssertFalse(mark.isVisible(at: 7))
        let data = try JSONEncoder().encode(mark)
        XCTAssertEqual(try JSONDecoder().decode(ReviewMark.self, from: data), mark)
        let manifest = ReviewManifest(createdAt: Date(), title: "Motion", imageWidth: 1000,
                                      imageHeight: 600, referenceImageFile: nil, videoFile: "clip.mov", marks: [mark])
        XCTAssertTrue(ReviewMarkdown.generate(manifest).contains("00:02.500–00:06.000"))
        // Existing feedback files without endTime still decode as single-frame comments.
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "endTime")
        let old = try JSONDecoder().decode(ReviewMark.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.endTime)
        XCTAssertFalse(old.isVisible(at: 4))
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
