import AppKit
import SwiftUI

@MainActor
@main
final class FrameNoteAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItem: NSStatusItem?

    static func main() {
        let application = NSApplication.shared
        let delegate = FrameNoteAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 154),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: ContentView())
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.contentMinSize = NSSize(width: 360, height: 154)
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
        panel.makeKeyAndOrderFront(nil)
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
            button.toolTip = "FrameNote — click to show or hide"
            button.setAccessibilityLabel("FrameNote")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        item.autosaveName = "FrameNote"
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            let visible = panel?.isVisible == true
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
        } else if panel?.isVisible == true {
            hideWidget(nil)
        } else {
            showWidget(nil)
        }
    }

    @objc func showWidget(_ sender: Any?) {
        NSApp.activate()
        panel?.makeKeyAndOrderFront(nil)
    }

    @objc func hideWidget(_ sender: Any?) {
        panel?.orderOut(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWidget(nil)
        return true
    }

    // AppKit excludes NSPanel from its last-window count. ScreenCaptureKit's
    // recording-indicator windows close on Stop while our widget is still open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private var isReviewMode = false
    private var savedReviewSize = NSSize(width: 1040, height: 700)

    func setReviewMode(_ reviewing: Bool) {
        guard reviewing != isReviewMode else { return }
        if isReviewMode { savedReviewSize = frame.size }
        isReviewMode = reviewing
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? frame
        let targetSize = reviewing
            ? NSSize(width: min(savedReviewSize.width, visible.width),
                     height: min(savedReviewSize.height, visible.height))
            : NSSize(width: 360, height: 154)
        if reviewing {
            contentMaxSize = visible.size
            contentMinSize = NSSize(width: min(760, visible.width), height: min(500, visible.height))
        } else {
            contentMinSize = targetSize
            contentMaxSize = targetSize
        }
        var target = NSRect(x: center.x - targetSize.width / 2,
                            y: center.y - targetSize.height / 2,
                            width: targetSize.width, height: targetSize.height)
        target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        setFrame(target, display: true, animate: false)
        makeKeyAndOrderFront(nil)
    }
}
