import SwiftUI

/// Routes between the recording and editing screens based on `AppState.route`.
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            switch appState.route {
            case .recording:
                RecordingView()
                    .transition(.opacity)
            case .editing(let result):
                EditingView(recording: result)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: routeKey(appState.route))
        .alert("Something went wrong",
               isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } })) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }

    /// Stable hashable key so SwiftUI's `animation(_:value:)` can detect route
    /// transitions even though `RecordingResult` does not conform to Hashable.
    private func routeKey(_ route: AppRoute) -> Int {
        switch route {
        case .recording: return 0
        case .editing:   return 1
        }
    }
}
