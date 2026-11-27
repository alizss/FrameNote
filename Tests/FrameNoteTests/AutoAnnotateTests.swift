import AppKit
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class AutoAnnotateTests: XCTestCase {
    /// Three chips with uneven gaps (12, 12, 20) on a grey page.
    private static func chipRow() -> NSImage {
        NSImage(size: NSSize(width: 460, height: 160), flipped: true) { rect in
            NSColor(white: 0.91, alpha: 1).setFill()
            rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
            for (x, label) in [(40.0, "Image"), (132.0, "Video"), (224.0, "Audio"), (324.0, "Files")] {
                let chip = NSRect(x: x, y: 60, width: 80, height: 36)
                NSColor.white.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 18, yRadius: 18).fill()
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(at: NSPoint(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2), withAttributes: attributes)
            }
            return true
        }
    }

    @MainActor
    func testAutoAnnotateAddsMeasuredMarksAndReplacesThemOnRescan() async throws {
        let store = ReviewStore()
        store.screenshot = Self.chipRow()
        let own = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.1, y: 0.1), note: "My own note")
        store.marks = [own]

        let found = await store.autoAnnotate()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(found), 1)
        let automatic = store.marks.filter { $0.auto == true }
        XCTAssertEqual(automatic.count, found)
        XCTAssertTrue(store.marks.contains { $0.id == own.id }, "Notes the person wrote must survive.")
        XCTAssertTrue(automatic.contains { $0.kind == .compareGaps && $0.note.contains("40 px") }, automatic.map(\.note).joined(separator: "\n"))
        XCTAssertNotNil(store.layoutOverlay)
        XCTAssertFalse(store.layoutOverlay?.elements.isEmpty ?? true)

        // Approving keeps a note; the rest are replaced rather than duplicated.
        let keptID = try XCTUnwrap(automatic.first).id
        store.marks[try XCTUnwrap(store.marks.firstIndex { $0.id == keptID })].isApproved = true
        _ = await store.autoAnnotate()
        XCTAssertEqual(store.marks.filter { $0.auto == true }.count, automatic.count, "A rescan must not pile up duplicates.")
        XCTAssertTrue(store.marks.contains { $0.id == keptID }, "Approved notes stay.")
        XCTAssertFalse(store.isAutoAnnotating)
    }

    @MainActor
    func testAutoAnnotateOnlyScansTheChosenArea() async throws {
        let store = ReviewStore()
        store.screenshot = Self.chipRow()
        // The area holds the first two chips only, whose gap is consistent.
        let found = await store.autoAnnotate(in: CGRect(x: 0, y: 0.2, width: 0.5, height: 0.6))
        XCTAssertEqual(found, 0)
        XCTAssertTrue(store.layoutOverlay?.elements.allSatisfy { $0.rect.maxX <= 0.55 } ?? false)
    }

    @MainActor
    func testWireframeIsPartOfTheSharedEvidence() async throws {
        let store = ReviewStore()
        store.screenshot = Self.chipRow()
        _ = await store.autoAnnotate()
        let prepared = await store.prepareFeedback()
        let folder = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("wireframe.png").path))
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent == "wireframe.png" })
        let markdown = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("wireframe.png"))
        XCTAssertTrue(markdown.contains("Auto-detected from pixels"))
    }
}
