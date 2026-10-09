import AppKit
import CoreGraphics
import SwiftUI

/// Recording screen: live screen preview, webcam overlay, and input settings.
struct RecordingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        RecordingWorkspace(
            screenPreview: appState.coordinator.screenPreview,
            cameraManager: appState.coordinator.cameraManager
        )
            .environmentObject(appState)
            .preferredColorScheme(.dark)
    }
}

private struct RecordingWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var screenPreview: ScreenPreviewManager
    let cameraManager: CameraManager
    @State private var cameraReady = false
    @State private var dragStartCenter: CGPoint?
    @State private var isDisplayPickerOpen = false

    private var coordinator: CaptureSessionCoordinator { appState.coordinator }

    private var isPreparing: Bool {
        appState.captureTransition == .preparing || appState.statusMessage == "Preparing…"
    }

    private var selectedDisplay: CaptureDisplay? {
        screenPreview.displays.first(where: { $0.id == appState.configuration.selectedDisplayID })
            ?? screenPreview.displays.first(where: \.isMain)
            ?? screenPreview.displays.first
    }

    private var previewAspect: CGFloat {
        selectedDisplay?.aspectRatio ?? (16.0 / 9.0)
    }

    var body: some View {
        ZStack {
            easemoBackground
            VStack(spacing: 12) {
                header
                    .padding(.top, 8)
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 12) {
                        screenPreviewCanvas
                        recordStack
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ScrollView {
                        controlsPanel
                            .padding(.bottom, 16)
                    }
                    .frame(width: 340)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .task {
            startScreenPreviewIfNeeded()
            // Keep the camera session running on this screen so Webcam off/on only hides the overlay.
            try? await cameraManager.startPreview()
            cameraReady = cameraManager.state == .preview
            syncLiveWebcamBlurPreview()
        }
        .onChange(of: appState.configuration.includeCamera, perform: { newValue in
            if newValue {
                Task {
                    try? await cameraManager.startPreview()
                    cameraReady = cameraManager.state == .preview
                }
            }
            syncLiveWebcamBlurPreview()
        })
        .onChange(of: appState.configuration.selectedDisplayID, perform: { newValue in
            screenPreview.startPreview(displayID: newValue)
        })
        .onChange(of: coordinator.isRecording, perform: { recording in
            syncLiveWebcamBlurPreview()
            if recording {
                screenPreview.stopPreview()
            }
        })
        .onAppear(perform: syncLiveWebcamBlurPreview)
        .onDisappear {
            screenPreview.stopPreview()
        }
        .onChange(of: appState.configuration.blurBackgroundBehindWebcam, perform: { _ in syncLiveWebcamBlurPreview() })
    }

    private func startScreenPreviewIfNeeded() {
        guard !coordinator.isRecording else { return }
        screenPreview.refreshDisplays()
        syncSelectedDisplay()
        screenPreview.startPreview(displayID: appState.configuration.selectedDisplayID)
    }

    private func syncSelectedDisplay() {
        let resolved = CaptureDisplayResolver.resolveID(
            preferred: appState.configuration.selectedDisplayID,
            available: screenPreview.displays.map(\.id),
            main: CGMainDisplayID()
        )
        if appState.configuration.selectedDisplayID != resolved {
            appState.configuration.selectedDisplayID = resolved
        }
    }

    private func syncLiveWebcamBlurPreview() {
        let shouldBlur = appState.configuration.includeCamera
            && appState.configuration.blurBackgroundBehindWebcam
            && cameraManager.state != .idle
        cameraManager.setBlurBackgroundEnabled(shouldBlur)
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
        HStack(spacing: 10) {
            Text("easemo")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(EasemoTheme.textPrimary)
            Text("Record. Compose. Ship demos faster.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(EasemoTheme.textSecondary)
            Spacer(minLength: 0)
        }
    }

    private var screenPreviewCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                .fill(Color.black.opacity(0.55))
            ScreenPreviewView(manager: screenPreview)
            if !screenPreview.hasFrame {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text(screenPreview.lastError ?? "Loading screen preview…")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(EasemoTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            cameraOverlay
            if coordinator.isRecording {
                RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                    .fill(Color.black.opacity(0.35))
                Text("Recording selected screen")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(EasemoTheme.textPrimary)
            }
        }
        .aspectRatio(previewAspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                .stroke(EasemoTheme.panelBorder, lineWidth: 1)
        )
        .shadow(
            color: EasemoTheme.panelShadow.color,
            radius: EasemoTheme.panelShadow.radius,
            x: EasemoTheme.panelShadow.x,
            y: EasemoTheme.panelShadow.y
        )
        .accessibilityLabel("Screen preview")
    }

    private var recordStack: some View {
        VStack(spacing: 16) {
            recordControlButton
            recordingActionRow
        }
    }

    private var recordControlButton: some View {
        Button(action: onRecordButtonTapped) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 3)
                    .frame(width: 88, height: 88)
                Circle()
                    .fill(EasemoTheme.recordGlow.opacity(coordinator.isRecording ? 0.45 : 0.28))
                    .frame(width: 80, height: 80)
                    .blur(radius: coordinator.isRecording ? 14 : 10)
                Circle()
                    .fill(coordinator.isRecording ? EasemoTheme.recordRedDim : EasemoTheme.recordRed)
                    .frame(width: 62, height: 62)
                    .shadow(color: EasemoTheme.recordGlow.opacity(0.9), radius: coordinator.isRecording ? 10 : 16, y: 0)
                if coordinator.isRecording {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 20, height: 20)
                } else {
                    Circle()
                        .fill(EasemoTheme.recordRed)
                        .frame(width: 42, height: 42)
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
                    Button(action: {
                        appState.markCaptureTransition(.preparing)
                        Task { await appState.startRecording() }
                    }) {
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
                Text("Screen")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EasemoTheme.textMuted)
                    .textCase(.uppercase)
                    .tracking(0.6)
                screenPicker
            }

            Divider()
                .background(EasemoTheme.panelBorder)

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

                labeledToggle(title: "Blur webcam background", isOn: $appState.configuration.blurBackgroundBehindWebcam)
                    .disabled(coordinator.isRecording)
                    .opacity(coordinator.isRecording ? 0.45 : 1)
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

                    Text("Drag the webcam on the preview to position it on the recorded screen.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(EasemoTheme.textMuted)
                }
            }
        }
        .padding(20)
        .easemoPanelStyle()
        .frame(maxWidth: .infinity)
    }

    private var screenPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text("Record")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(EasemoTheme.textPrimary)
                    .padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ForcedLightLabel(
                            text: selectedDisplay?.menuTitle ?? "Looking for displays…",
                            font: .systemFont(ofSize: 13, weight: .medium)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(EasemoTheme.sliderTrackInactive)
                    .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous)
                            .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !coordinator.isRecording, !screenPreview.displays.isEmpty else { return }
                        isDisplayPickerOpen.toggle()
                    }
                    .opacity(coordinator.isRecording || screenPreview.displays.isEmpty ? 0.45 : 1)

                    if isDisplayPickerOpen {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(screenPreview.displays) { display in
                                ForcedLightLabel(
                                    text: display.menuTitle,
                                    font: .systemFont(ofSize: 13, weight: .medium)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    display.id == selectedDisplay?.id
                                        ? EasemoTheme.accentPurple.opacity(0.35)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    appState.configuration.selectedDisplayID = display.id
                                    isDisplayPickerOpen = false
                                }
                            }
                        }
                        .background(EasemoTheme.bgPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous)
                                .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                        )
                    }
                }
            }
            Text("Records the full selected display. Cropped regions (QuickTime’s area selection) are not available yet. Mission Control Spaces are not separate screens.")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(EasemoTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private func labeledToggle(title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(EasemoTheme.textPrimary)
            FirstClickSwitch(isOn: isOn)
                .frame(width: 38, height: 22)
        }
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "On" : "Off")
    }

    private var isCameraOverlayShown: Bool {
        appState.configuration.includeCamera
            && appState.overlay.isVisible
            && !coordinator.isRecording
    }

    @ViewBuilder
    private var cameraOverlay: some View {
        // Keep the preview layer mounted. Tearing it down on Webcam off leaves a black
        // layer when the same running session is attached again.
        if cameraReady {
            GeometryReader { proxy in
                let canvas = proxy.size
                let frame = appState.overlay.frame(in: canvas, cameraAspect: 16.0 / 9.0)
                AdaptiveCameraPreviewView(session: cameraManager.session,
                                          cameraManager: cameraManager,
                                          shape: appState.overlay.shape)
                    .frame(width: frame.width, height: frame.height)
                    .overlay {
                        if isCameraOverlayShown {
                            overlayStroke
                        }
                    }
                    .position(x: frame.midX, y: frame.midY)
                    .shadow(color: .black.opacity(isCameraOverlayShown ? 0.45 : 0), radius: 10, y: 4)
                    .gesture(overlayDragGesture(in: canvas, frame: frame))
            }
            .opacity(isCameraOverlayShown ? 1 : 0)
            .allowsHitTesting(isCameraOverlayShown)
        }
    }

    @ViewBuilder
    private var overlayStroke: some View {
        if appState.overlay.shape == .circle {
            Circle().stroke(Color.white.opacity(0.45), lineWidth: 1.5)
        } else {
            RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
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
        if coordinator.isRecording {
            appState.markCaptureTransition(.finishing)
            Task { await appState.stopRecording() }
        } else {
            appState.markCaptureTransition(.preparing)
            Task { await appState.startRecording() }
        }
    }
}

/// AppKit label so picker text stays white even when NSButton/Menu chrome forces a light appearance.
private struct ForcedLightLabel: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor = .white

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        apply(to: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        apply(to: nsView)
    }

    private func apply(to field: NSTextField) {
        field.stringValue = text
        field.font = font
        field.textColor = color
        field.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Native switch that changes state even when its click also activates the app/window.
private struct FirstClickSwitch: NSViewRepresentable {
    @Binding var isOn: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    func makeNSView(context: Context) -> AcceptsFirstMouseSwitch {
        let control = AcceptsFirstMouseSwitch()
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.controlSize = .small
        return control
    }

    func updateNSView(_ nsView: AcceptsFirstMouseSwitch, context: Context) {
        context.coordinator.isOn = $isOn
        nsView.state = isOn ? .on : .off
    }

    final class Coordinator: NSObject {
        var isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc func changed(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }

    final class AcceptsFirstMouseSwitch: NSSwitch {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }
}
