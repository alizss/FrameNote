import AppKit
import AVFoundation
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class SeamlessReviewTests: XCTestCase {
    @MainActor
    func testClipboardAcceptsRemoteURLAndCopiedVideoFile() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("https://example.com/demo.mp4", forType: .URL)
        XCTAssertEqual(try ClipboardMedia.read(board).url.absoluteString, "https://example.com/demo.mp4")
        board.clearContents()
        let file = URL(fileURLWithPath: "/tmp/demo.mp4")
        board.writeObjects([file as NSURL])
        XCTAssertEqual(try ClipboardMedia.read(board).url, file)
        XCTAssertFalse(try ClipboardMedia.read(board).temporary)
        board.clearContents()
        let bytes = Data([1, 2, 3, 4])
        board.setData(bytes, forType: NSPasteboard.PasteboardType("public.mpeg-4"))
        let raw = try ClipboardMedia.read(board)
        defer { try? FileManager.default.removeItem(at: raw.url) }
        XCTAssertTrue(raw.temporary)
        XCTAssertEqual(try Data(contentsOf: raw.url), bytes)
    }

    func testWebpageResolvesVideoMetadataAndRelativeMedia() async throws {
        let fixture = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let page = URL(string: "https://example.com/gallery/item")!
        let html = "<meta content='/motion.mov?x=1&amp;y=2' property='og:video'><video src='/second.mp4'></video>"
        let candidates = MediaPageResolver.candidates(in: html, base: page)
        XCTAssertEqual(candidates.first?.absoluteString, "https://example.com/motion.mov?x=1&y=2")
        let imported = try await InspirationImporter.shared.importMedia(page, download: { request in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")
            let isPage = request.url == page
            if isPage { try Data(html.utf8).write(to: temporary) }
            else { try FileManager.default.copyItem(at: fixture, to: temporary) }
            return (temporary, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": isPage ? "text/html" : "video/quicktime"])!)
        })
        defer { try? FileManager.default.removeItem(at: imported.url) }
        XCTAssertTrue(imported.isVideo)
        XCTAssertGreaterThan(imported.duration, 0)
    }

    @MainActor
    func testWholeReviewCreatesObservationsAndUndoRestoresPriorReview() throws {
        let report = try JSONDecoder().decode(WholeReviewAnalysis.self, from: Data("""
        {"summary":"Panel opens and shifts the page.","findings":[
          {"note":"Keep the background stable.","startTime":0.3,"endTime":0.8,"rect":[0.1,0.2,0.3,0.4]},
          {"note":"Timing unclear between samples.","startTime":1.0},
          {"note":"Invalid time must not be pinned.","startTime":99}
        ]}
        """.utf8))
        let store = ReviewStore()
        let id = store.ensureWholeReview()
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertFalse(store.marks[0].isVisible(at: nil))
        let before = store.marks
        store.applyWholeReview(report, to: id, duration: 2, isVideo: true)
        XCTAssertEqual(store.marks.count, 3)
        XCTAssertEqual(store.marks[0].designAnalysis, report.summary)
        XCTAssertTrue(store.marks[1].aiGenerated == true)
        XCTAssertEqual(store.marks[1].kind, .focus)
        XCTAssertTrue(store.marks[2].wholeMedia == true)
        XCTAssertFalse(store.marks.contains { $0.time == 99 })
        store.undoAnnotations()
        XCTAssertEqual(store.marks, before)
    }

    @MainActor
    func testCopyForAIPutsInstructionsAndImageOnSameClipboardItem() async throws {
        let store = ReviewStore()
        store.screenshot = NSImage(size: NSSize(width: 80, height: 50), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); if let folder = store.lastExport { try? FileManager.default.removeItem(at: folder) } }
        await store.copyForAI(pasteboard: board)
        XCTAssertTrue(board.string(forType: .string)?.contains("Study this reference") == true)
        XCTAssertNotNil(board.data(forType: .png))
        XCTAssertNotNil(NSImage(pasteboard: board))
        XCTAssertEqual(store.marks.count, 1)
    }

    func testWholeVideoAnalysisUsesOneRequestAndDenseTimestampedEvidence() async throws {
        let fixture = try await MotionFixture.makeVideo()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let report = try await DesignerAssistant.analyzeWhole(key: "test", screenshot: nil, videoURL: fixture, duration: 2, note: "Understand the motion", send: { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let input = body["input"] as! [[String: Any]]
            let content = input[0]["content"] as! [[String: Any]]
            XCTAssertGreaterThan(content.filter { $0["type"] as? String == "input_image" }.count, 4)
            XCTAssertTrue((content[0]["text"] as? String)?.contains("sampled still frames") == true)
            let answer = "{\"summary\":\"The panel opens.\",\"findings\":[{\"note\":\"Use less movement.\",\"startTime\":0.5}]}"
            let data = try JSONSerialization.data(withJSONObject: ["output": [["type": "message", "content": [["type": "output_text", "text": answer]]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertEqual(report.summary, "The panel opens.")
        XCTAssertEqual(report.findings.count, 1)
    }
}
