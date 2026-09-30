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
        let heightChange = height - frame.height
        guard abs(heightChange) > 0.5 else { return }
        frame.origin.y -= heightChange
        frame.size.height = height
        setFrame(frame, display: true, animate: true)
    }
}
