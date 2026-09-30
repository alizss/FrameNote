import SwiftUI

@main
struct FrameNoteApp: App {
    var body: some Scene {
        WindowGroup("FrameNote") {
            ContentView()
        }
        .defaultSize(width: 620, height: 480)
        .windowResizability(.contentMinSize)
    }
}
