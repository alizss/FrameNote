import SwiftUI

@main
struct FrameNoteApp: App {
    var body: some Scene {
        WindowGroup("FrameNote") {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}
