import AppKit
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

            if appState.captureTransition != .none {
                CaptureTransitionOverlay(transition: appState.captureTransition,
                                         includeCamera: appState.configuration.includeCamera)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: routeKey(appState.route))
        .onAppear {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
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

private struct CaptureTransitionOverlay: View {
    let transition: CaptureTransition
    let includeCamera: Bool

    var body: some View {
        ZStack {
            EasemoTheme.bgPrimary.opacity(0.92)
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white)
                    .scaleEffect(1.2)
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(EasemoTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(EasemoTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }

    private var title: String {
        switch transition {
        case .preparing: return "Preparing recording…"
        case .finishing: return "Processing recording…"
        case .returning: return "Returning to setup…"
        case .none: return ""
        }
    }

    private var subtitle: String {
        switch transition {
        case .preparing where includeCamera:
            return "Your camera overlay is coming up. Start talking when it shows REC."
        case .preparing:
            return "Start talking when this screen hides."
        case .finishing:
            return "Opening the editor…"
        case .returning:
            return "Getting the camera and screen preview ready…"
        case .none:
            return ""
        }
    }
}
