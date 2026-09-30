import AppKit
import SwiftUI

@MainActor
@main
final class FrameNoteAppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?

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
