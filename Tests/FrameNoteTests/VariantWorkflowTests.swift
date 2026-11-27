import AppKit
import XCTest
import SwiftUI
import WebKit
@testable import FrameNote
@testable import FrameNoteCore

final class VariantWorkflowTests: XCTestCase {
    @MainActor
    func testWorkshopLoadsTwoNativePreviewsWithPlayableScripts() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        let mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5), note: "Make opening smoother")
        store.marks = [mark]
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 960, height: 740),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VariantWorkshop(store: store, markID: mark.id))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func previews(in view: NSView) -> [WKWebView] {
            if let web = view as? WKWebView { return [web] }
            return view.subviews.flatMap { previews(in: $0) }
        }
        var loaded: [WKWebView] = []
        for _ in 0..<100 {
            let views = previews(in: host)
            if views.count == 2 {
                var ready = true
                for view in views {
                    let value = try? await view.evaluateJavaScript("typeof applySettings === 'function' && document.body.classList.contains('open')")
                    if value as? Bool != true { ready = false }
                }
                if ready { loaded = views; break }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(loaded.count, 2, "Both WKWebView previews should load, execute their scripts, and replay")
        XCTAssertEqual(store.marks[0].variants?.count, 3)
        for preview in loaded {
            let value = try await preview.evaluateJavaScript("closePanel(); !document.body.classList.contains('open')")
            XCTAssertEqual(value as? Bool, true)
        }
    }

    @MainActor
    func testRefinementPreservesParentAndSelectionDoesNotApproveIssue() throws {
        let store = ReviewStore()
        let mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.2, y: 0.3), note: "Too slow")
        store.marks = [mark]
        store.ensureVariants(for: mark.id, mode: .motion)
        store.ensureVariants(for: mark.id, mode: .motion)
        XCTAssertEqual(store.marks[0].variants?.count, 3)
        var original = try XCTUnwrap(store.marks[0].variants?.first)
        let originalID = original.id
        original.durationMS = 100
        let refined = try XCTUnwrap(store.saveRefinement(original, for: mark.id))
        XCTAssertEqual(refined.version, "A.2")
        XCTAssertEqual(refined.parentID, originalID)
        XCTAssertEqual(store.marks[0].variants?.first?.durationMS, 140)
        store.selectVariant(refined.id, for: mark.id)
        XCTAssertFalse(store.marks[0].isApproved)
        let saved = try JSONEncoder().encode(store.marks[0])
        XCTAssertEqual(try JSONDecoder().decode(ReviewMark.self, from: saved), store.marks[0])
        store.undoAnnotations()
        XCTAssertNil(store.marks[0].selectedVariantID)
        store.redoAnnotations()
        XCTAssertEqual(store.marks[0].selectedVariantID, refined.id)
        let sibling = try XCTUnwrap(store.saveRefinement(original, for: mark.id))
        XCTAssertEqual(sibling.version, "A.3", "Refining an older version must not reuse a version number")
    }

    @MainActor
    func testClearAnnotationsRestoresCommentsAndPendingGapInOneUndo() {
        let store = ReviewStore()
        let mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0, y: 0), note: "Keep this")
        store.marks = [mark]
        store.pendingGapPreview = mark
        store.clearAnnotations()
        XCTAssertTrue(store.marks.isEmpty)
        XCTAssertNil(store.pendingGapPreview)
        store.undoAnnotations()
        XCTAssertEqual(store.marks, [mark])
        XCTAssertEqual(store.pendingGapPreview, mark)
        store.redoAnnotations()
        XCTAssertTrue(store.marks.isEmpty)
        XCTAssertNil(store.pendingGapPreview)
    }

    func testPrototypeEscapesFeedbackAndIncludesPlayableBehavior() {
        let variant = ReviewVariant.presets(for: .motion)[0]
        let html = variant.html(note: "</p><script>alert('x')</script>")
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("function replay"))
        XCTAssertTrue(html.contains("prefers-reduced-motion"))
        XCTAssertTrue(html.contains("Escape"))
        XCTAssertFalse(html.contains("https://"))
    }

    @MainActor
    func testExportContainsRunnableVariantsAndChosenImplementationBrief() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 20, height: 20).fill(); image.unlockFocus()
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5), note: "Edit in place")
        mark.variants = ReviewVariant.presets(for: .flow)
        let chosen = try XCTUnwrap(mark.variants?.last)
        mark.selectedVariantID = chosen.id
        let folder = try ReviewExporter.export(screenshot: image, reference: nil, title: "Variants", marks: [mark], into: root)
        let html = try String(contentsOf: folder.appendingPathComponent(chosen.filename), encoding: .utf8)
        XCTAssertTrue(html.contains("body class=\"inline\""))
        let markdown = try String(contentsOf: folder.appendingPathComponent("feedback.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Selected prototype C"))
        XCTAssertTrue(markdown.contains("Presentation: Inline editing"))
        let manifest = try JSONDecoder.iso8601.decode(ReviewManifest.self, from: Data(contentsOf: folder.appendingPathComponent("feedback.json")))
        XCTAssertEqual(manifest.marks[0].selectedVariantID, chosen.id)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
