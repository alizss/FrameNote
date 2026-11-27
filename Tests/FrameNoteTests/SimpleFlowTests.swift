import AppKit
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class SimpleFlowTests: XCTestCase {
    func testSocialHostsDoNotMatchLookalikeDomains() {
        XCTAssertTrue(SocialMediaDownload.isSocialPage(URL(string: "https://mobile.twitter.com/a/status/123")!))
        XCTAssertTrue(SocialMediaDownload.isSocialPage(URL(string: "https://x.com/a/status/123")!))
        XCTAssertFalse(SocialMediaDownload.isSocialPage(URL(string: "https://x.com.evil.example/a")!))
        XCTAssertFalse(SocialMediaDownload.isSocialPage(URL(string: "https://example.com/video.mp4")!))
    }

    @MainActor
    func testBriefCopiesAnalysisAndSourceWithoutPreparingExport() throws {
        let store = ReviewStore()
        store.title = "https://x.com/example/status/123"
        let id = store.ensureWholeReview()
        let index = try XCTUnwrap(store.marks.firstIndex { $0.id == id })
        store.marks[index].designAnalysis = "## Build\nA panel that expands on click."
        store.marks[index].note = "Adapt the transition."
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let start = ContinuousClock.now
        store.copyImplementationBrief(pasteboard: board)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(150))
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertTrue(text.contains("A panel that expands on click."))
        XCTAssertTrue(text.contains(store.title))
        XCTAssertTrue(text.contains("Adapt the transition."))
        XCTAssertNil(store.lastExport)
        XCTAssertFalse(store.isCopyingForAI)
    }

    @MainActor
    func testVisibleCopyPreviewMatchesClipboard() async throws {
        let store = ReviewStore()
        let image = NSImage(size: NSSize(width: 160, height: 100))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 160, height: 100).fill(); image.unlockFocus()
        store.screenshot = image
        _ = store.ensureWholeReview()
        let prepared = await store.prepareFeedback(fullExport: false)
        let folder = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: folder) }
        store.marks[0].note = "Use a compact navigation bar."
        XCTAssertEqual(store.lastExport, folder, "Text edits must keep prepared frames immediately copyable.")
        let preview = store.implementationBrief
        let urls = store.copyEvidenceURLs
        XCTAssertFalse(urls.isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let start = ContinuousClock.now
        await store.copyPreviewForAI(pasteboard: board)
        print("Prepared image + text copy: \(start.duration(to: .now))")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(board.string(forType: .string), preview)
        XCTAssertEqual(board.pasteboardItems?.count, urls.count)
        for (item, url) in zip(board.pasteboardItems ?? [], urls) {
            XCTAssertEqual(item.data(forType: .png), try Data(contentsOf: url))
        }
    }

    @MainActor
    func testVideoPreviewSkipsVideoExportAndCopiesPreparedFrames() async throws {
        let video = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: video) }
        let store = ReviewStore()
        store.openVideo(at: video)
        store.duration = 2
        _ = store.ensureWholeReview()
        let start = ContinuousClock.now
        let prepared = await store.prepareFeedback(fullExport: false)
        let folder = try XCTUnwrap(prepared)
        defer { try? FileManager.default.removeItem(at: folder) }
        print("Video copy preview preparation: \(start.duration(to: .now))")
        XCTAssertEqual(store.copyEvidenceURLs.count, 12)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".mov") || $0.hasSuffix("-sequence.png") })
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let copyStart = ContinuousClock.now
        await store.copyPreviewForAI(pasteboard: board)
        print("Prepared 12-frame + text copy: \(copyStart.duration(to: .now))")
        XCTAssertLessThan(copyStart.duration(to: .now), .milliseconds(100))
        XCTAssertEqual(board.pasteboardItems?.count, 12)
        XCTAssertEqual(board.string(forType: .string), store.implementationBrief)
        let full = await store.prepareFeedback(fullExport: true)
        let fullFolder = try XCTUnwrap(full)
        defer { try? FileManager.default.removeItem(at: fullFolder) }
        let fullFiles = try FileManager.default.contentsOfDirectory(atPath: fullFolder.path)
        XCTAssertTrue(fullFiles.contains { $0.hasSuffix("-clip.mov") })
        XCTAssertTrue(fullFiles.contains { $0.hasSuffix("-sequence.png") })
    }

    func testLiveSocialImport() async throws {
        guard let source = ProcessInfo.processInfo.environment["FRAMENOTE_TEST_SOCIAL_URL"],
              let url = URL(string: source) else { throw XCTSkip("Opt-in live public social URL") }
        let imported = try await InspirationImporter.shared.importReference(url)
        defer { try? FileManager.default.removeItem(at: imported.url) }
        XCTAssertTrue(imported.isVideo)
        XCTAssertGreaterThan(imported.duration, 0)
    }
}
