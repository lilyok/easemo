import SwiftUI

private let mainWindowID = "main"

/// Application entry point.
///
/// `easemo` is a lightweight, fully-local macOS screen recording and editing
/// tool. The app revolves around a single shared `AppState` that drives both
/// the recording flow and the post-recording editing/export flow.
@main
struct EasemoApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("easemo", id: mainWindowID) {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        .commands {
            MainWindowCommands()
        }
    }
}

/// Keeps the single app window discoverable after the user closes it.
private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .windowArrangement) {
            Button("Open Main Window") {
                openWindow(id: mainWindowID)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}
