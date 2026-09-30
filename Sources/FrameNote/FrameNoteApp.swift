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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: ContentView())
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func resizeWidget(to height: CGFloat) {
        var frame = self.frame
        guard abs(height - frame.height) > 0.5 else { return }
        let centerY = frame.midY
        frame.size.height = height
        frame.origin.y = centerY - height / 2
        if let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame {
            let highestVisibleOrigin = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
            frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), highestVisibleOrigin)
        }
        setFrame(frame, display: true, animate: true)
        makeKeyAndOrderFront(nil)
    }
}
