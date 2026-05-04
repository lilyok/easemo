import SwiftUI

/// Recording screen: record control, floating draggable webcam, and input settings.
struct RecordingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isPreviewReady = false
    @State private var dragStartCenter: CGPoint?

    private var coordinator: CaptureSessionCoordinator { appState.coordinator }

    private var isPreparing: Bool {
        appState.statusMessage == "Preparing…"
    }

    var body: some View {
        ZStack {
            easemoBackground
            VStack(spacing: 0) {
                header
                    .padding(.top, 8)
                Spacer(minLength: 16)
                recordStack
                Spacer(minLength: 16)
                controlsPanel
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
            cameraOverlay
        }
        .task {
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

    private var easemoBackground: some View {
        ZStack {
            EasemoTheme.bgPrimary
            LinearGradient(
                colors: [EasemoTheme.bgGradientTop, EasemoTheme.bgGradientBottom],
                startPoint: .top,
                endPoint: .bottom
            )
            .opacity(0.85)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("easemo")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(EasemoTheme.textPrimary)
            Text("Record. Compose. Ship demos faster.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(EasemoTheme.textSecondary)
        }
        .multilineTextAlignment(.center)
    }

    private var recordStack: some View {
        VStack(spacing: 20) {
            recordControlButton
            recordingActionRow
        }
    }

    private var recordControlButton: some View {
        Button(action: onRecordButtonTapped) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                    .frame(width: 112, height: 112)
                Circle()
                    .fill(EasemoTheme.recordGlow.opacity(coordinator.isRecording ? 0.45 : 0.28))
                    .frame(width: 104, height: 104)
                    .blur(radius: coordinator.isRecording ? 14 : 10)
                Circle()
                    .fill(coordinator.isRecording ? EasemoTheme.recordRedDim : EasemoTheme.recordRed)
                    .frame(width: 80, height: 80)
                    .shadow(color: EasemoTheme.recordGlow.opacity(0.9), radius: coordinator.isRecording ? 10 : 16, y: 0)
                if coordinator.isRecording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 26, height: 26)
                } else {
                    Circle()
                        .fill(EasemoTheme.recordRed)
                        .frame(width: 56, height: 56)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(coordinator.isRecording ? "Stop recording" : "Start recording")
    }

    private var recordingActionRow: some View {
        Group {
            if coordinator.isRecording {
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(EasemoTheme.recordRed)
                            .frame(width: 8, height: 8)
                        Text("\(AppState.formatElapsed(coordinator.elapsedSeconds)) Recording")
                            .font(.system(size: 15, weight: .medium).monospacedDigit())
                            .foregroundStyle(EasemoTheme.textPrimary)
                    }
                    Button("Stop", action: { Task { await appState.stopRecording() } })
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(EasemoTheme.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(EasemoTheme.sliderTrackInactive)
                        .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous)
                                .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                        )
                }
            } else {
                VStack(spacing: 8) {
                    Button(action: { Task { await appState.startRecording() } }) {
                        Text("Start Recording")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: 280)
                            .padding(.vertical, 12)
                            .background(EasemoTheme.accentGradient)
                            .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous))
                            .shadow(color: EasemoTheme.accentPurple.opacity(0.35), radius: 14, y: 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPreparing)
                    .opacity(isPreparing ? 0.55 : 1)

                    if isPreparing {
                        Text("Preparing…")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(EasemoTheme.textMuted)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: coordinator.isRecording)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Inputs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EasemoTheme.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                HStack(spacing: 28) {
                    labeledToggle(title: "Webcam", isOn: $appState.configuration.includeCamera)
                    labeledToggle(title: "Microphone", isOn: $appState.configuration.includeMicrophone)
                }
            }

            if appState.configuration.includeCamera {
                Divider()
                    .background(EasemoTheme.panelBorder)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Webcam")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(EasemoTheme.textMuted)
                        .textCase(.uppercase)
                        .tracking(0.6)

                    HStack(spacing: 12) {
                        Text("Shape")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(EasemoTheme.textSecondary)
                        HStack(spacing: 0) {
                            ForEach(OverlayShape.allCases) { shape in
                                shapeSegment(shape)
                            }
                        }
                        .padding(3)
                        .background(EasemoTheme.sliderTrackInactive)
                        .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Size")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(EasemoTheme.textSecondary)
                            Spacer()
                            Text(String(format: "%.0f%%", appState.overlay.widthFraction * 100))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                                .foregroundStyle(EasemoTheme.textMuted)
                        }
                        Slider(value: $appState.overlay.widthFraction, in: 0.1...0.4)
                            .tint(EasemoTheme.accentPurple)
                    }

                    Text("Drag the webcam preview to position it on the screen.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(EasemoTheme.textMuted)
                }
            }
        }
        .padding(20)
        .easemoPanelStyle()
        .frame(maxWidth: 560)
    }

    private func shapeSegment(_ shape: OverlayShape) -> some View {
        let selected = appState.overlay.shape == shape
        return Button {
            appState.overlay.shape = shape
        } label: {
            Text(shape.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? EasemoTheme.textPrimary : EasemoTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Group {
                        if selected {
                            RoundedRectangle(cornerRadius: EasemoTheme.radiusInput - 2, style: .continuous)
                                .fill(EasemoTheme.accentPurple.opacity(0.35))
                                .overlay(
                                    RoundedRectangle(cornerRadius: EasemoTheme.radiusInput - 2, style: .continuous)
                                        .stroke(EasemoTheme.accentPurple.opacity(0.9), lineWidth: 1)
                                )
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }

    private func labeledToggle(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(EasemoTheme.textPrimary)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(EasemoTheme.accentPurple)
        }
    }

    @ViewBuilder
    private var cameraOverlay: some View {
        if appState.configuration.includeCamera, appState.overlay.isVisible {
            GeometryReader { proxy in
                let canvas = proxy.size
                let frame = appState.overlay.frame(in: canvas, cameraAspect: 16.0 / 9.0)
                if appState.overlay.shape == .circle {
                    CameraPreviewView(session: coordinator.cameraManager.session,
                                      shape: appState.overlay.shape)
                        .frame(width: frame.width, height: frame.height)
                        .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5))
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                        .gesture(overlayDragGesture(in: canvas, frame: frame))
                } else {
                    CameraPreviewView(session: coordinator.cameraManager.session,
                                      shape: appState.overlay.shape)
                        .frame(width: frame.width, height: frame.height)
                        .overlay(
                            RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous)
                                .stroke(Color.white.opacity(0.35), lineWidth: 1.5)
                        )
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                        .gesture(overlayDragGesture(in: canvas, frame: frame))
                }
            }
            .ignoresSafeArea()
        }
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
