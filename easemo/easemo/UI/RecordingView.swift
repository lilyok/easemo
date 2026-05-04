import SwiftUI

/// Recording screen: large record button, camera preview overlay, and a few
/// configuration toggles.
struct RecordingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPreviewReady = false
    @State private var dragStartCenter: CGPoint?

    private var coordinator: CaptureSessionCoordinator { appState.coordinator }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 24) {
                header
                Spacer()
                recordButton
                statusLine
                Spacer()
                controlsPanel
            }
            .padding(28)
            cameraOverlay
        }
        .task {
            // Pre-warm the camera so the first record start feels snappy.
            if appState.configuration.includeCamera, !isPreviewReady {
                try? await coordinator.cameraManager.startPreview()
                isPreviewReady = true
            }
        }
        .onChange(of: appState.configuration.includeCamera, perform: { newValue in
            Task {
                if newValue {
                    try? await coordinator.cameraManager.startPreview()
                    isPreviewReady = true
                } else {
                    coordinator.cameraManager.stopPreview()
                    isPreviewReady = false
                }
            }
        })
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.13),
                                Color(red: 0.05, green: 0.06, blue: 0.10)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("easemo")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Record. Compose. Ship demos faster.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
        }
    }

    private var recordButton: some View {
        Button(action: onRecordButtonTapped) {
            ZStack {
                Circle()
                    .fill(coordinator.isRecording ? Color.red : Color.white.opacity(0.9))
                    .frame(width: 96, height: 96)
                    .shadow(color: .red.opacity(coordinator.isRecording ? 0.55 : 0.0), radius: 18)
                if coordinator.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 64, height: 64)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(coordinator.isRecording ? "Stop recording" : "Start recording")
    }

    private var statusLine: some View {
        Text(appState.statusMessage.isEmpty ? "Press the button to start" : appState.statusMessage)
            .font(.system(.headline, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                Toggle("Include webcam", isOn: $appState.configuration.includeCamera)
                    .toggleStyle(.switch)
                    .tint(.accentColor)

                Toggle("Record microphone", isOn: $appState.configuration.includeMicrophone)
                    .toggleStyle(.switch)
                    .tint(.accentColor)
            }

            if appState.configuration.includeCamera {
                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("Shape")
                            .foregroundStyle(.white.opacity(0.85))
                        ForEach(OverlayShape.allCases) { shape in
                            Button(shape.displayName) {
                                appState.overlay.shape = shape
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(shape == appState.overlay.shape ? .white : .white.opacity(0.15))
                            .foregroundStyle(shape == appState.overlay.shape ? .black : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                    .frame(width: 250, alignment: .leading)

                    Picker("Position", selection: overlayPositionBinding) {
                        ForEach(OverlayPosition.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .frame(width: 200)
                }

                HStack {
                    Text("Size")
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: $appState.overlay.widthFraction, in: 0.1...0.4)
                    Text(String(format: "%2.0f%%", appState.overlay.widthFraction * 100))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text("Tip: drag the webcam preview to place it anywhere.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(20)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
        .frame(maxWidth: 540)
    }

    @ViewBuilder
    private var cameraOverlay: some View {
        if appState.configuration.includeCamera, appState.overlay.isVisible {
            GeometryReader { proxy in
                let canvas = proxy.size
                let frame = appState.overlay.frame(in: canvas, cameraAspect: 16.0/9.0)
                if appState.overlay.shape == .circle {
                    CameraPreviewView(session: coordinator.cameraManager.session,
                                      shape: appState.overlay.shape)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 2))
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(radius: 12)
                        .gesture(overlayDragGesture(in: canvas, frame: frame))
                } else {
                    CameraPreviewView(session: coordinator.cameraManager.session,
                                      shape: appState.overlay.shape)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.6), lineWidth: 2))
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(radius: 12)
                        .gesture(overlayDragGesture(in: canvas, frame: frame))
                }
            }
            .ignoresSafeArea()
        }
    }

    private var overlayPositionBinding: Binding<OverlayPosition> {
        Binding(
            get: { appState.overlay.position },
            set: { newValue in
                appState.overlay.position = newValue
                appState.overlay.customCenter = nil
            }
        )
    }

    private func overlayDragGesture(in canvas: CGSize, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let frameCenter = CGPoint(
                    x: frame.midX / max(canvas.width, 1),
                    y: frame.midY / max(canvas.height, 1)
                )
                let base = dragStartCenter ?? appState.overlay.customCenter ?? frameCenter
                if dragStartCenter == nil {
                    dragStartCenter = base
                }
                let moved = CGPoint(
                    x: base.x + (value.translation.width / max(canvas.width, 1)),
                    y: base.y + (value.translation.height / max(canvas.height, 1))
                )
                appState.overlay.customCenter = CGPoint(
                    x: min(max(moved.x, 0), 1),
                    y: min(max(moved.y, 0), 1)
                )
            }
            .onEnded { _ in
                dragStartCenter = nil
            }
    }

    private func onRecordButtonTapped() {
        Task {
            if coordinator.isRecording {
                await appState.stopRecording()
            } else {
                await appState.startRecording()
            }
        }
    }
}
