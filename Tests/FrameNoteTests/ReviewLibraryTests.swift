import AppKit
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class ReviewLibraryTests: XCTestCase {
    @MainActor
    func testSwitchingImmediatelyPreservesBothReviewsAndReopeningUpdatesSameEntry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let media = folder.appendingPathComponent("source.png")
        let image = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: media)
        let store = ReviewStore(restoreSavedDraft: true, draftFolder: folder)
        store.openImage(at: media)
        store.title = "First reference"
        store.marks = [ReviewMark(kind: .point, start: .init(x: 0.2, y: 0.3), note: "Keep this feedback")]
        store.openImage(at: media)
        store.title = "Second reference"
        await store.refreshLibrary()
        XCTAssertEqual(store.savedReviews.count, 2)
        let first = try XCTUnwrap(store.savedReviews.first { $0.draft.title == "First reference" })
        try FileManager.default.removeItem(at: media)
        let opened = await store.openSavedReview(first)
        XCTAssertTrue(opened)
        XCTAssertEqual(store.marks.first?.note, "Keep this feedback")
        store.title = "Updated first"
        await store.refreshLibrary()
        XCTAssertEqual(store.savedReviews.count, 2)
        XCTAssertEqual(store.savedReviews.first?.id, first.id)
        let reloaded = ReviewDrafts(folder: folder)
        let saved = try await reloaded.load()
        XCTAssertEqual(saved?.0.title, "Updated first")
        XCTAssertEqual(saved?.0.marks.first?.note, "Keep this feedback")
    }

    func testLegacyVideoMigratesOnceAndRetainsMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data([1, 2, 3])
        try bytes.write(to: folder.appendingPathComponent("media.mov"))
        let draft = ReviewDraft(title: "Legacy", marks: [], mediaFile: "media.mov", currentTime: 12)
        try JSONEncoder().encode(draft).write(to: folder.appendingPathComponent("draft.json"))
        let drafts = ReviewDrafts(folder: folder)
        let loaded = try await drafts.load()
        let migrated = try XCTUnwrap(loaded)
        XCTAssertNotNil(migrated.0.id)
        XCTAssertEqual(migrated.0.currentTime, 12)
        XCTAssertEqual(try Data(contentsOf: migrated.1), bytes)
        let first = try await drafts.list()
        let second = try await drafts.list()
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.id, second.first?.id)
    }
}
