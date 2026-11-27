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

    func testApprovalSurvivesExportAndLegacyNotesRemainOpen() throws {
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5), note: "Spacing is correct")
        let legacy = try JSONEncoder().encode(mark)
        XCTAssertFalse(try JSONDecoder().decode(ReviewMark.self, from: legacy).isApproved)
        mark.isApproved = true
        let restored = try JSONDecoder().decode(ReviewMark.self, from: JSONEncoder().encode(mark))
        XCTAssertTrue(restored.isApproved)
        let manifest = ReviewManifest(createdAt: Date(), title: "Review", imageWidth: 80,
                                      imageHeight: 50, referenceImageFile: nil, marks: [restored])
        XCTAssertTrue(ReviewMarkdown.generate(manifest).contains("Approved — no change needed"))
        mark.isApproved = false
        XCTAssertFalse(mark.isApproved)
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

    @MainActor
    func testExportKeepsInspirationWithItsComment() throws {
        let image = NSImage(size: NSSize(width: 40, height: 30), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill(); return true
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let inspiration = parent.appendingPathComponent("example.png")
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: inspiration)
        var mark = ReviewMark(kind: .focus, start: UnitPoint2D(x: 0.1, y: 0.1),
                              end: UnitPoint2D(x: 0.8, y: 0.8), note: "Improve the opening motion")
        mark.inspirations = [InspirationAttachment(kind: .url, value: "https://example.com/motion"),
                             InspirationAttachment(kind: .image, value: inspiration.path)]
        mark.designAnalysis = "Reduce the extra dismissal step."
        let folder = try ReviewExporter.export(screenshot: image, reference: nil,
                                               title: "Motion", marks: [mark], into: parent)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(ReviewManifest.self,
            from: Data(contentsOf: folder.appendingPathComponent("feedback.json")))
        let exported = try XCTUnwrap(manifest.marks.first)
        XCTAssertEqual(exported.inspirations?.first?.value, "https://example.com/motion")
        let file = try XCTUnwrap(exported.inspirations?.last?.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        let feedback = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(feedback.contains(file))
        XCTAssertTrue(feedback.contains("Reduce the extra dismissal step."))
    }

    func testChangingMarkTypeKeepsCommentAndGivesShapesGeometry() throws {
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5), time: 2, endTime: 3, note: "Tighten this")
        mark.convert(to: .focus)
        XCTAssertEqual(mark.kind, .focus)
        XCTAssertNotNil(mark.end)
        XCTAssertEqual(mark.note, "Tighten this")
        XCTAssertEqual(mark.time, 2)
        XCTAssertEqual(mark.endTime, 3)

        mark.convert(to: .arrow)
        XCTAssertEqual(mark.kind, .arrow)
        XCTAssertNotNil(mark.end)

        mark.convert(to: .point)
        XCTAssertEqual(mark.kind, .point)
        XCTAssertNil(mark.end)
        XCTAssertEqual(mark.start.x, 0.5, accuracy: 0.001)

        mark.convert(to: .compareGaps)
        XCTAssertEqual(mark.kind, .point, "Compare gaps needs two drawn gaps")
    }
}
