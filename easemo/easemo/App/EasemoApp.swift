import SwiftUI

/// Application entry point.
///
/// `easemo` is a lightweight, fully-local macOS screen recording and editing
/// tool. The app revolves around a single shared `AppState` that drives both
/// the recording flow and the post-recording editing/export flow.
@main
struct EasemoApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("easemo") {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // No "New" window
        }
    }
}
