import AppKit
import SwiftUI

@MainActor
@main
final class FrameNoteAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?
    private var hoverMonitor: Any?
    private var localHoverMonitor: Any?
    private var pointerInsideStatusItem = false

    static func main() {
        let application = NSApplication.shared
        let delegate = FrameNoteAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: ContentView())
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.delegate = self
        panel.contentMinSize = NSSize(width: 380, height: 280)
        panel.contentMaxSize = panel.contentMinSize
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        self.panel = panel
        installMenuBarItem()
    }

    private func installMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "FrameNote")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.addTrackingArea(NSTrackingArea(rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            button.toolTip = "FrameNote — start or continue a review"
            button.setAccessibilityLabel("FrameNote")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.autosaveName = "FrameNote"
        statusItem = item
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusHover() }
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.updateStatusHover() }
            return event
        }
    }

    private func updateStatusHover() {
        guard let button = statusItem?.button, let window = button.window else { return }
        let inside = window.convertToScreen(button.convert(button.bounds, to: nil)).contains(NSEvent.mouseLocation)
        defer { pointerInsideStatusItem = inside }
        if inside && !pointerInsideStatusItem && panel?.isVisible != true { showWidget(nil) }
    }

    @objc func mouseEntered(with event: NSEvent) {
        guard panel?.isVisible != true else { return }
        showWidget(nil)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            let visible = panel?.isVisible == true && panel?.isMiniaturized != true
            let toggle = NSMenuItem(title: visible ? "Hide FrameNote" : "Show FrameNote",
                                    action: visible ? #selector(hideWidget(_:)) : #selector(showWidget(_:)),
                                    keyEquivalent: "")
            toggle.target = self
            menu.addItem(toggle)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "Quit FrameNote", action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
            quit.target = NSApp
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: sender)
        } else if panel?.isVisible == true && panel?.isMiniaturized != true && panel?.presentation != .review {
            hideWidget(nil)
        } else {
            showWidget(nil)
        }
    }

    @objc func showWidget(_ sender: Any?) {
        NSApp.activate()
        if panel?.isMiniaturized == true { panel?.deminiaturize(nil) }
        if let button = statusItem?.button, let window = button.window {
            panel?.compactAnchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        NotificationCenter.default.post(name: .frameNoteShowLauncher, object: nil)
        if panel?.presentation == .launcher { panel?.positionCompactAtAnchor() }
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc func hideWidget(_ sender: Any?) {
        panel?.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === panel { hideWidget(nil); return false }
        return true
    }

    // AppKit excludes NSPanel from its last-window count. ScreenCaptureKit's
    // recording-indicator windows close on Stop while our widget is still open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let frameNoteShowLauncher = Notification.Name("FrameNote.showLauncher")
}

enum FrameNotePresentation { case launcher, recording, review }

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private(set) var presentation: FrameNotePresentation = .launcher
    private var savedReviewFrame: NSRect?
    var compactAnchor: NSRect?

    func setPresentation(_ next: FrameNotePresentation) {
        guard next != presentation else { return }
        let previous = presentation, oldFrame = frame
        if previous == .review { savedReviewFrame = oldFrame }
        presentation = next
        let reviewing = next == .review
        if delegate != nil {
            styleMask = reviewing ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
            titleVisibility = .hidden
            titlebarAppearsTransparent = true
            titlebarSeparatorStyle = .none
            toolbar = nil
            backgroundColor = reviewing ? .windowBackgroundColor : .clear
            isOpaque = reviewing
        }
        level = reviewing ? .normal : .floating
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? oldFrame
        let size: NSSize
        switch next {
        case .launcher: size = NSSize(width: 380, height: 280)
        case .recording: size = NSSize(width: 340, height: 104)
        case .review:
            let saved = savedReviewFrame?.size ?? NSSize(width: 1180, height: 800)
            size = NSSize(width: min(saved.width, visible.width), height: min(saved.height, visible.height))
        }
        // Relax the old limits before shrinking, so a review's minimum height cannot enlarge the widget.
        contentMinSize = NSSize(width: 1, height: 1)
        contentMaxSize = visible.size
        var target: NSRect
        if reviewing {
            let origin = savedReviewFrame?.origin ?? NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
            target = NSRect(origin: origin, size: size)
        } else if previous == .launcher || previous == .recording {
            // Keep the top-left corner still when the draggable launcher becomes the timer.
            target = NSRect(x: oldFrame.minX, y: oldFrame.maxY - size.height, width: size.width, height: size.height)
        } else if let anchor = compactAnchor {
            target = NSRect(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 8, width: size.width, height: size.height)
        } else {
            target = NSRect(x: oldFrame.midX - size.width / 2, y: oldFrame.midY - size.height / 2, width: size.width, height: size.height)
        }
        target.origin = clamped(target, to: visible)
        setFrame(target, display: true, animate: false)
        if reviewing {
            contentMinSize = NSSize(width: min(760, visible.width), height: min(620, visible.height - 28))
        } else {
            contentMinSize = size; contentMaxSize = size
        }
        makeKeyAndOrderFront(nil)
    }

    func positionCompactAtAnchor() {
        guard presentation == .launcher, let anchor = compactAnchor else { return }
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        var target = frame
        target.origin = NSPoint(x: anchor.midX - frame.width / 2, y: anchor.minY - frame.height - 8)
        setFrameOrigin(clamped(target, to: visible))
    }

    private func clamped(_ rect: NSRect, to visible: NSRect) -> NSPoint {
        NSPoint(x: min(max(rect.minX, visible.minX), visible.maxX - rect.width),
                y: min(max(rect.minY, visible.minY), visible.maxY - rect.height))
    }
}
