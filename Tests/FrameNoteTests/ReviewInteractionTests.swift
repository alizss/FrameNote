import AppKit
import AVKit
import SwiftUI
import XCTest
@testable import FrameNote
@testable import FrameNoteCore

final class ReviewInteractionTests: XCTestCase {
    @MainActor
    func testSimpleReferencePreparesVisibleCopyEvidenceWithoutAnnotationTools() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        store.screenshot = Self.exampleImage()
        let host = NSHostingView(rootView: ContentView(store: store))
        let panel = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1000, height: 700),
                             styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNil(Self.inputView(in: host))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks.first?.wholeMedia, true)
        XCTAssertNotNil(store.lastExport)
        XCTAssertFalse(store.copyEvidenceURLs.isEmpty)
        XCTAssertFalse(store.isPreparing)
        store.marks[0].note = "Adapt the navigation"
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotNil(store.lastExport, "The visible copy evidence must refresh after an edit")
        XCTAssertFalse(store.isPreparing)
        let clipboard = NSPasteboard.withUniqueName()
        store.copyForAgent(pasteboard: clipboard)
        XCTAssertTrue(clipboard.string(forType: .string)?.contains("Adapt the navigation") == true)
    }

    @MainActor
    func testReviewAcceptsPinTypingAndMeasuredDragWithoutMovingWindow() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        let panel = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 360, height: 154),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = NSSize(width: 360, height: 154)
        panel.contentMaxSize = panel.contentMinSize
        let host = NSHostingView(rootView: ContentView(store: store, automaticallyFocusComments: false, detailedEditing: true))
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(250))

        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent("review-test-\(UUID().uuidString).tiff")
        try Self.exampleImage().tiffRepresentation!.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        store.openImage(at: imageURL)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertGreaterThanOrEqual(panel.frame.width, 760)
        XCTAssertGreaterThanOrEqual(panel.frame.height, 500)

        let input = try XCTUnwrap(Self.inputView(in: host))
        XCTAssertGreaterThan(input.bounds.width, 500, "The preview should use the expanded workspace.")
        let originalFrame = panel.frame
        let location = NSPoint(x: input.bounds.width * 0.25, y: input.bounds.height * 0.3)
        let hostPoint = input.convert(location, to: host.superview)
        XCTAssertTrue(host.hitTest(hostPoint) === input, "Annotation surface must receive the click.")
        input.mouseDown(with: Self.event(.leftMouseDown, at: location, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: location, in: input))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.marks.first).start.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.marks.first).start.y, 0.3, accuracy: 0.001)

        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView,
                                  "Placing a mark should focus its comment field.")
        editor.insertText("Match the spacing here.", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.marks.first?.note, "Match the spacing here.")

        store.tool = .measure
        try await Task.sleep(for: .milliseconds(100))
        let start = NSPoint(x: input.bounds.width * 0.25, y: input.bounds.height * 0.6)
        let end = NSPoint(x: input.bounds.width * 0.75, y: input.bounds.height * 0.6)
        input.mouseDown(with: Self.event(.leftMouseDown, at: start, in: input))
        input.mouseDragged(with: Self.event(.leftMouseDragged, at: end, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: end, in: input))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 2)
        let measurement = try XCTUnwrap(store.marks.last)
        XCTAssertEqual(measurement.kind, .measure)
        XCTAssertEqual(try XCTUnwrap(measurement.distanceInPixels(width: 1000, height: 600)), 500, accuracy: 0.01)
        XCTAssertEqual(panel.frame, originalFrame, "Drawing must not drag the widget.")

        // A synthetic fixture only: useful for checking the actual hosted review layout.
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_REVIEW_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            panel.setFrame(NSRect(x: 60, y: 60, width: 760, height: 640), display: true)
            try await Task.sleep(for: .milliseconds(150))
            if let narrow = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: narrow)
                try narrow.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-narrow.png"))
            }
            store.recordingStartedAt = Date().addingTimeInterval(-65)
            store.isRecording = true
            try await Task.sleep(for: .milliseconds(150))
            if let timer = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: timer)
                try timer.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-recording.png"))
            }
        }
    }

    @MainActor
    func testAnnotationSurfaceWinsHitTestingAboveNativeVideoPlayer() async throws {
        _ = NSApplication.shared
        let store = ReviewStore()
        store.videoURL = URL(fileURLWithPath: "/tmp/framenote-input-test.mov")
        store.videoSize = CGSize(width: 1000, height: 600)
        store.player = AVPlayer()
        store.duration = 10
        let panel = FloatingPanel(contentRect: NSRect(x: 60, y: 60, width: 1040, height: 700),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView(store: store, automaticallyFocusComments: false, detailedEditing: true))
        host.sizingOptions = []
        panel.contentView = host
        panel.makeKeyAndOrderFront(nil)
        defer { panel.close() }
        try await Task.sleep(for: .milliseconds(250))
        let input = try XCTUnwrap(Self.inputView(in: host))
        let start = NSPoint(x: input.bounds.width * 0.1, y: input.bounds.height * 0.15)
        let end = NSPoint(x: input.bounds.width * 0.35, y: input.bounds.height * 0.4)
        let hitResult = host.hitTest(input.convert(start, to: host.superview))
        XCTAssertTrue(hitResult === input)
        input.mouseDown(with: Self.event(.leftMouseDown, at: start, in: input))
        input.mouseDragged(with: Self.event(.leftMouseDragged, at: end, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: end, in: input))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks.first?.kind, .focus)
        XCTAssertNotNil(store.marks.first?.time)
        let id = try XCTUnwrap(store.marks.first?.id)
        let editor = try XCTUnwrap(panel.firstResponder as? NSTextView)
        editor.insertText("The menu jumps here.", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.marks.first?.note, "The menu jumps here.")

        let timeline = try XCTUnwrap(Self.find(VideoTimelineView.self, in: host))
        timeline.selecting = true
        let a = NSPoint(x: 8 + (timeline.bounds.width - 16) * 0.2, y: 15)
        let b = NSPoint(x: 8 + (timeline.bounds.width - 16) * 0.6, y: 15)
        timeline.mouseDown(with: Self.event(.leftMouseDown, at: a, in: timeline))
        timeline.mouseDragged(with: Self.event(.leftMouseDragged, at: b, in: timeline))
        timeline.mouseUp(with: Self.event(.leftMouseUp, at: b, in: timeline))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.marks.count, 1, "Time selection should attach to the selected area comment.")
        XCTAssertEqual(store.marks.first?.id, id)
        XCTAssertEqual(try XCTUnwrap(store.marks.first?.time), 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(store.marks.first?.endTime), 6, accuracy: 0.01)
        XCTAssertEqual(store.marks.first?.note, "The menu jumps here.")

        // Resize the end handle and keep the same spatial selection and comment.
        let c = NSPoint(x: 8 + (timeline.bounds.width - 16) * 0.8, y: 15)
        timeline.mouseDown(with: Self.event(.leftMouseDown, at: b, in: timeline))
        timeline.mouseDragged(with: Self.event(.leftMouseDragged, at: c, in: timeline))
        timeline.mouseUp(with: Self.event(.leftMouseUp, at: c, in: timeline))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(try XCTUnwrap(store.marks.first?.endTime), 8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(store.marks.first?.end?.x), 0.35, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(store.marks.first?.end?.y), 0.4, accuracy: 0.001)

        // Clicking an existing area reopens it without creating duplicate notes.
        input.mouseDown(with: Self.event(.leftMouseDown, at: start, in: input))
        input.mouseUp(with: Self.event(.leftMouseUp, at: start, in: input))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertNotNil(panel.firstResponder as? NSTextView)
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_REVIEW_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-video.png"))
        }
    }

    @MainActor
    func testSharingPreparesEvidenceWithoutSaveDialogAndRefreshesEditedNotes() async throws {
        let store = ReviewStore()
        store.screenshot = Self.exampleImage()
        store.marks = [ReviewMark(kind: .point, start: UnitPoint2D(x: 0.2, y: 0.3), note: "Move this field")]
        let pasteboard = NSPasteboard.withUniqueName()
        var folders: [URL] = []
        defer {
            pasteboard.releaseGlobally()
            for folder in folders { try? FileManager.default.removeItem(at: folder) }
        }
        store.copyForAgent(pasteboard: pasteboard)
        XCTAssertNil(store.lastExport, "Copying instructions should not wait for media export.")
        let prepared = await store.prepareFeedback()
        XCTAssertNotNil(prepared)
        let first = try XCTUnwrap(store.lastExport)
        folders.append(first)
        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("Move this field"))
        XCTAssertTrue(store.shareFiles.contains { $0.lastPathComponent == "annotated.png" })
        let reused = await store.prepareFeedback()
        XCTAssertEqual(reused, first, "Unchanged reviews should reuse their prepared files.")
        let image = try XCTUnwrap(store.shareFiles.first { $0.lastPathComponent == "annotated.png" })
        await store.copyImage(at: image, pasteboard: pasteboard)
        XCTAssertTrue(pasteboard.canReadObject(forClasses: [NSImage.self], options: nil))
        store.marks[0].note = "Keep this field"
        store.marks[0].isApproved = true
        XCTAssertNil(store.lastExport)
        let refreshed = await store.prepareFeedback()
        XCTAssertNotNil(refreshed)
        store.copyForAgent(pasteboard: pasteboard)
        let second = try XCTUnwrap(store.lastExport)
        folders.append(second)
        XCTAssertNotEqual(first, second)
        let brief = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(brief.contains("Keep this field"))
        XCTAssertTrue(brief.contains("Approved — no change needed"))
        XCTAssertFalse(brief.contains("Move this field"))
        if let path = ProcessInfo.processInfo.environment["FRAMENOTE_REVIEW_SNAPSHOT"] {
            let panel = NSPanel(contentRect: NSRect(x: 60, y: 60, width: 960, height: 120),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: FeedbackShareView(store: store).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.light))
            panel.contentView = host
            panel.makeKeyAndOrderFront(nil)
            defer { panel.close() }
            try await Task.sleep(for: .milliseconds(200))
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-share.png"))
            }
        }
    }

    @MainActor
    func testAnnotationUndoRedoAndInspirationStayWithComment() throws {
        let store = ReviewStore()
        store.screenshot = Self.exampleImage()
        store.addMark(start: UnitPoint2D(x: 0.2, y: 0.3), end: nil)
        XCTAssertEqual(store.marks.count, 1)
        let id = try XCTUnwrap(store.marks.first?.id)
        XCTAssertTrue(store.addInspirationURL("https://example.com/interaction", to: id))
        XCTAssertEqual(store.marks.first?.inspirations?.count, 1)
        store.undoAnnotations()
        XCTAssertNil(store.marks.first?.inspirations)
        store.redoAnnotations()
        XCTAssertEqual(store.marks.first?.inspirations?.first?.value, "https://example.com/interaction")
        store.marks.removeAll { $0.id == id }
        XCTAssertTrue(store.marks.isEmpty)
        store.undoAnnotations()
        XCTAssertEqual(store.marks.first?.id, id)
    }

    @MainActor
    func testDesignAssistantUsesThreePerspectivesAndCombinesResults() async throws {
        let image = try XCTUnwrap(Self.exampleImage().cgImage(forProposedRect: nil, context: nil, hints: nil))
        let recorder = AssistantRequestRecorder()
        let answer = try await DesignerAssistant.analyze(
            key: "test-key", screenshot: image, videoURL: nil,
            start: nil, end: nil, duration: 0,
            focus: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            note: "The collapse feels awkward", inspirations: [],
            send: { request in try await recorder.respond(to: request) })
        XCTAssertEqual(answer, "Try a direct close and a shorter transition.")
        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.prefix(3).allSatisfy { $0.hasImage && !$0.stored })
        XCTAssertFalse(calls[3].hasImage)
        XCTAssertTrue(calls[3].prompt.contains("Interaction clarity"))
        XCTAssertTrue(calls[3].prompt.contains("Motion"))
        XCTAssertTrue(calls[3].prompt.contains("Visual design"))
    }

    @MainActor
    func testReviewDraftRestoresCommentAndMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("framenote-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try XCTUnwrap(Self.exampleImage().cgImage(forProposedRect: nil, context: nil, hints: nil))
        var mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.2, y: 0.3), note: "Keep this")
        mark.inspirations = [InspirationAttachment(kind: .url, value: "https://example.com")]
        let drafts = ReviewDrafts(folder: folder)
        try await drafts.save(title: "Restored review", marks: [mark], screenshot: image,
                              videoURL: nil, currentTime: 0, generation: UUID())
        let loaded = try await drafts.load()
        let restored = try XCTUnwrap(loaded)
        XCTAssertEqual(restored.0.title, "Restored review")
        XCTAssertEqual(restored.0.marks, [mark])
        XCTAssertNotNil(NSImage(contentsOf: restored.1))
    }

    @MainActor
    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func inputView(in view: NSView) -> AnnotationInputView? {
        if let view = view as? AnnotationInputView { return view }
        for child in view.subviews {
            if let match = inputView(in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in view: NSView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                           timestamp: 0, windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @MainActor
    private static func exampleImage() -> NSImage {
        NSImage(size: NSSize(width: 1000, height: 600), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 32, weight: .semibold),
                                                      .foregroundColor: NSColor.black]
            ("Account settings" as NSString).draw(at: NSPoint(x: 70, y: 495), withAttributes: title)
            NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 70, y: 135, width: 850, height: 305), xRadius: 16, yRadius: 16).fill()
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22),
                                                     .foregroundColor: NSColor.black]
            ("Profile details" as NSString).draw(at: NSPoint(x: 100, y: 370), withAttributes: body)
            ("Name     Alex Morgan" as NSString).draw(at: NSPoint(x: 100, y: 290), withAttributes: body)
            NSColor.systemBlue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 710, y: 55, width: 210, height: 55), xRadius: 10, yRadius: 10).fill()
            ("Save changes" as NSString).draw(at: NSPoint(x: 740, y: 70), withAttributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.white])
            return true
        }
    }
}

private actor AssistantRequestRecorder {
    struct Call: Sendable { let prompt: String; let hasImage: Bool; let stored: Bool }
    private(set) var calls: [Call] = []

    func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try XCTUnwrap((json["input"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(input["content"] as? [[String: Any]])
        let prompt = content.compactMap { $0["text"] as? String }.joined(separator: " ")
        calls.append(Call(prompt: prompt, hasImage: content.contains { $0["type"] as? String == "input_image" },
                          stored: json["store"] as? Bool ?? true))
        let result = prompt.contains("Combine these independent UI reviews")
            ? "Try a direct close and a shorter transition." : "Observation from \(prompt.prefix(32))"
        let payload: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": result]]]]]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200,
                                                     httpVersion: nil, headerFields: nil))
        return (data, response)
    }
}
