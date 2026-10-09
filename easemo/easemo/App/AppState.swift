import Combine
import Foundation
import SwiftUI
import AppKit
import AVFoundation

/// Top-level routes that the root view switches between.
public enum AppRoute: Equatable {
    case recording
    case editing(RecordingResult)
}

/// Full-window transition so setup never just vanishes or flashes back.
public enum CaptureTransition: Equatable {
    case none
    case preparing
    case finishing
    case returning
}

/// Single source of truth for the running app.
///
/// `AppState` owns the long-lived service objects (`CaptureSessionCoordinator`,
/// `VideoComposer`, `ExportManager`) and exposes view-model style state to
/// SwiftUI. View models are kept inside `AppState` rather than per-view
/// `@StateObject`s because the recording session has to survive view
/// transitions (e.g. switching from the recording screen to the editing
/// screen the moment the user clicks "Stop").
@MainActor
public final class AppState: ObservableObject {

    @Published public var route: AppRoute = .recording
    @Published public var captureTransition: CaptureTransition = .none

    /// Capture configuration the user has set on the recording screen.
    @Published public var configuration: RecordingConfiguration = .init()

    /// Live overlay layout (mirrors `configuration.overlay` so SwiftUI can
    /// bind to a single property for previews).
    @Published public var overlay: OverlayLayout = .default {
        didSet {
            configuration.overlay = overlay
            if coordinator.isRecording, oldValue != overlay {
                coordinator.recordPiPLayoutSample(overlay)
            }
        }
    }

    /// Playback speed selected on the editing screen.
    @Published public var playbackSpeed: Double = 1.0
    /// Trim start (seconds) selected on the editing screen.
    @Published public var trimStartSeconds: Double = 0
    /// Trim end (seconds) selected on the editing screen.
    @Published public var trimEndSeconds: Double = 0
    /// When true, the audio track is muted in the export and preview.
    @Published public var muteAudio: Bool = false

    /// Status string shown in the UI (recording timer / export progress).
    @Published public var statusMessage: String = ""

    /// User-facing error to surface in the UI.
    @Published public var errorMessage: String?

    public let coordinator: CaptureSessionCoordinator
    public let composer: VideoComposer
    public let exportManager: ExportManager
    private let recordingUIBridge: RecordingUIBridge

    private var cancellables = Set<AnyCancellable>()

    @MainActor
    public convenience init() {
        self.init(coordinator: CaptureSessionCoordinator(),
                  composer: VideoComposer(),
                  exportManager: ExportManager())
    }

    @MainActor
    public init(coordinator: CaptureSessionCoordinator,
                composer: VideoComposer = VideoComposer(),
                exportManager: ExportManager) {
        self.coordinator = coordinator
        self.composer = composer
        self.exportManager = exportManager
        self.recordingUIBridge = RecordingUIBridge()

        recordingUIBridge.setStopAction { [weak self] in
            Task { @MainActor in
                await self?.stopRecording()
            }
        }

        coordinator.$elapsedSeconds
            .sink { [weak self] seconds in
                guard let self = self, self.coordinator.isRecording else { return }
                self.statusMessage = Self.formatElapsed(seconds)
            }
            .store(in: &cancellables)

        coordinator.$isRecording
            .dropFirst()
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.recordingUIBridge.didStartRecording(
                        includeCamera: self.configuration.includeCamera,
                        cameraSession: self.coordinator.cameraManager.session,
                        cameraManager: self.coordinator.cameraManager,
                        blurWebcamBackground: self.configuration.blurBackgroundBehindWebcam,
                        overlay: self.overlay,
                        displayID: self.configuration.selectedDisplayID,
                        onOverlayChanged: { [weak self] updatedOverlay in
                            guard let self = self else { return }
                            self.overlay = updatedOverlay
                        }
                    )
                } else {
                    self.recordingUIBridge.didStopRecording()
                }
            }
            .store(in: &cancellables)

        exportManager.$progress
            .sink { [weak self] progress in
                guard let self = self else { return }
                if case .exporting = self.exportManager.state {
                    self.statusMessage = String(format: "Exporting… %d%%", Int(progress * 100))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Recording flow

    public func markCaptureTransition(_ transition: CaptureTransition) {
        captureTransition = transition
        if transition == .preparing {
            errorMessage = nil
            statusMessage = "Preparing…"
        }
        if transition == .finishing || transition == .returning {
            statusMessage = ""
        }
    }

    public func startRecording() async {
        if captureTransition != .preparing {
            markCaptureTransition(.preparing)
        }
        // Let SwiftUI paint the overlay before HUD/ScreenCaptureKit work.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 32_000_000)
        do {
            recordingUIBridge.didStartRecording(
                includeCamera: configuration.includeCamera,
                cameraSession: coordinator.cameraManager.session,
                cameraManager: coordinator.cameraManager,
                blurWebcamBackground: configuration.blurBackgroundBehindWebcam,
                overlay: overlay,
                displayID: configuration.selectedDisplayID,
                onOverlayChanged: { [weak self] updatedOverlay in
                    guard let self = self else { return }
                    self.overlay = updatedOverlay
                }
            )
            try await coordinator.start(configuration: configuration)
            captureTransition = .none
            recordingUIBridge.hideMainWindow()
        } catch {
            captureTransition = .none
            recordingUIBridge.didStopRecording()
            recordingUIBridge.showMainWindow()
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    public func stopRecording() async {
        if captureTransition != .finishing {
            markCaptureTransition(.finishing)
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 32_000_000)
        recordingUIBridge.didStopRecording()
        recordingUIBridge.showMainWindow()
        do {
            let result = try await coordinator.stop(finalOverlay: overlay)
            statusMessage = "Recording finished — \(Self.formatElapsed(result.duration.seconds))"
            if configuration.includeCamera, result.cameraURL == nil {
                errorMessage = "Camera recording was unavailable for this take. Please retry and keep camera enabled."
            }
            playbackSpeed = 1.0
            trimStartSeconds = 0
            trimEndSeconds = max(0, result.duration.seconds)
            overlay = result.layout
            configuration.blurBackgroundBehindWebcam = result.blurBackgroundBehindWebcam
            route = .editing(result)
            captureTransition = .none
        } catch {
            captureTransition = .none
            errorMessage = error.localizedDescription
            coordinator.screenPreview.startPreview(displayID: configuration.selectedDisplayID)
            try? await coordinator.cameraManager.startPreview()
        }
    }

    // MARK: Editing → Export flow

    public func export(result: RecordingResult, to destination: URL) async {
        do {
            errorMessage = nil
            statusMessage = "Composing…"
            let bundle = try await composer.compose(result: result,
                                                    layout: overlay,
                                                    speed: playbackSpeed,
                                                    trimStart: trimStartSeconds,
                                                    trimEnd: trimEndSeconds,
                                                    muteAudio: muteAudio)
            statusMessage = "Exporting…"
            _ = try await exportManager.export(bundle: bundle, to: destination)
            // Success UI is handled on the editing screen ("Video exported" + Reveal in Finder).
            statusMessage = ""
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    public func backToRecording() {
        statusMessage = ""
        trimStartSeconds = 0
        trimEndSeconds = 0
        muteAudio = false
        captureTransition = .returning
        Task { await returnToSetup() }
    }

    private func returnToSetup() async {
        // Mount setup behind the blocking transition before warming its previews.
        route = .recording
        await Task.yield()
        try? await Task.sleep(nanoseconds: 32_000_000)

        coordinator.screenPreview.refreshDisplays()
        coordinator.screenPreview.startPreview(displayID: configuration.selectedDisplayID)
        try? await coordinator.cameraManager.startPreview()
        coordinator.cameraManager.setBlurBackgroundEnabled(
            configuration.includeCamera && configuration.blurBackgroundBehindWebcam
        )

        // Keep the transition above setup until expensive preview initialization
        // finishes, so the newly mounted controls never appear temporarily frozen.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let screenReady = coordinator.screenPreview.hasFrame
            let cameraReady = coordinator.cameraManager.state == .preview
            let blurReady = !configuration.includeCamera
                || !configuration.blurBackgroundBehindWebcam
                || coordinator.cameraManager.liveBlurPreviewPixelBuffer != nil
            if screenReady && cameraReady && blurReady {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        recordingUIBridge.showMainWindow()
        await recordingUIBridge.waitUntilMainWindowAcceptsInput()
        captureTransition = .none
    }

    // MARK: Helpers

    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

@MainActor
private final class RecordingUIBridge: NSObject {
    private var statusItem: NSStatusItem?
    private var stopAction: (() -> Void)?
    private var floatingPanel: NSPanel?
    private var panelMoveObserver: NSObjectProtocol?
    private var onOverlayChanged: ((OverlayLayout) -> Void)?
    private var currentOverlay: OverlayLayout = .default
    private var cameraSession: AVCaptureSession?
    private weak var cameraManager: CameraManager?
    private weak var mainWindow: NSWindow?

    func setStopAction(_ action: @escaping () -> Void) {
        stopAction = action
    }

    func didStartRecording(includeCamera: Bool,
                           cameraSession: AVCaptureSession,
                           cameraManager: CameraManager,
                           blurWebcamBackground: Bool,
                           overlay: OverlayLayout,
                           displayID: UInt32?,
                           onOverlayChanged: @escaping (OverlayLayout) -> Void) {
        self.onOverlayChanged = onOverlayChanged
        self.currentOverlay = overlay
        self.cameraSession = cameraSession
        self.cameraManager = cameraManager
        cameraManager.setBlurBackgroundEnabled(blurWebcamBackground)
        installStatusItem()
        if includeCamera {
            installFloatingPanel(session: cameraSession,
                                 cameraManager: cameraManager,
                                 overlay: overlay,
                                 shape: overlay.shape,
                                 displayID: displayID)
        }
    }

    func hideMainWindow() {
        let window = NSApplication.shared.windows.first { candidate in
            candidate.isVisible && !(candidate is NSPanel)
        } ?? NSApplication.shared.windows.first { !($0 is NSPanel) }
        mainWindow = window
        window?.animationBehavior = .none
        if window?.isMiniaturized == false {
            window?.miniaturize(nil)
        }
        installStatusItem()
    }

    func showMainWindow() {
        let window = mainWindow ?? NSApplication.shared.windows.first { !($0 is NSPanel) }
        window?.animationBehavior = .none
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.animationBehavior = .default
        NSApplication.shared.activate(ignoringOtherApps: true)
        removeStatusItem()
    }

    func waitUntilMainWindowAcceptsInput() async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            let window = mainWindow ?? NSApplication.shared.windows.first { !($0 is NSPanel) }
            if NSApplication.shared.isActive, window?.isKeyWindow == true {
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func didStopRecording() {
        cameraManager?.setBlurBackgroundEnabled(false)
        removeFloatingPanel()
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Stop easemo"
        item.button?.target = self
        item.button?.action = #selector(stopFromMenuBar)
        statusItem = item
    }

    private func removeStatusItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    private func installFloatingPanel(session: AVCaptureSession,
                                      cameraManager: CameraManager,
                                      overlay: OverlayLayout,
                                      shape: OverlayShape,
                                      displayID: UInt32?) {
        guard floatingPanel == nil else { return }
        let screen = screenForRecording(displayID: displayID)
        let visible = screen?.visibleFrame ?? CGRect(x: 100, y: 100, width: 1200, height: 800)
        // Use the same layout function as export so floating preview matches
        // resulting video size/placement as closely as possible.
        let frameInCanvas = overlay.frame(in: visible.size, cameraAspect: 16.0/9.0)
        let origin = CGPoint(x: visible.minX + frameInCanvas.origin.x,
                             y: visible.maxY - frameInCanvas.maxY)
        let size = frameInCanvas.size

        let panel = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let hud = FloatingRecorderHUD(session: session,
                                      cameraManager: cameraManager,
                                      shape: shape,
                                      onScale: { [weak self] factor in
                                          self?.scaleOverlay(by: factor)
                                      },
                                      onSetShape: { [weak self] newShape in
                                          self?.setOverlayShape(newShape)
                                      },
                                      onReset: { [weak self] in
                                          self?.resetOverlayPlacement()
                                      })
        panel.contentView = NSHostingView(rootView: hud)
        panel.makeKeyAndOrderFront(nil)
        floatingPanel = panel

        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor [weak self, weak panel] in
                guard let self = self, let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
                let visible = screen.visibleFrame
                let center = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
                let normalized = CGPoint(
                    x: min(max((center.x - visible.minX) / max(visible.width, 1), 0), 1),
                    y: min(max((visible.maxY - center.y) / max(visible.height, 1), 0), 1)
                )
                self.applyOverlayChange {
                    $0.customCenter = normalized
                }
            }
        }
    }

    private func removeFloatingPanel() {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        onOverlayChanged = nil
        cameraSession = nil
        cameraManager = nil
    }

    @objc
    private func stopFromMenuBar() {
        stopAction?()
    }

    private func scaleOverlay(by factor: CGFloat) {
        guard factor.isFinite else { return }
        applyOverlayChange {
            let scaled = $0.widthFraction * factor
            $0.widthFraction = min(max(scaled, 0.10), 0.45)
        }
        refreshFloatingPanelFrame()
    }

    private func setOverlayShape(_ shape: OverlayShape) {
        applyOverlayChange {
            $0.shape = shape
        }
        refreshFloatingPanelAppearance()
        refreshFloatingPanelFrame()
    }

    private func resetOverlayPlacement() {
        applyOverlayChange {
            $0.customCenter = nil
            $0.position = .bottomRight
            $0.widthFraction = OverlayLayout.default.widthFraction
            $0.shape = OverlayLayout.default.shape
        }
        refreshFloatingPanelAppearance()
        refreshFloatingPanelFrame()
    }

    private func applyOverlayChange(_ update: (inout OverlayLayout) -> Void) {
        update(&currentOverlay)
        onOverlayChanged?(currentOverlay)
    }

    private func refreshFloatingPanelAppearance() {
        guard let panel = floatingPanel,
              let session = cameraSession,
              let cameraManager = cameraManager else { return }
        panel.contentView = NSHostingView(
            rootView: FloatingRecorderHUD(session: session,
                                          cameraManager: cameraManager,
                                          shape: currentOverlay.shape,
                                          onScale: { [weak self] factor in
                                              self?.scaleOverlay(by: factor)
                                          },
                                          onSetShape: { [weak self] newShape in
                                              self?.setOverlayShape(newShape)
                                          },
                                          onReset: { [weak self] in
                                              self?.resetOverlayPlacement()
                                          })
        )
    }

    private func screenForRecording(displayID: UInt32?) -> NSScreen? {
        if let displayID, let match = CaptureDisplay.nsScreen(forDisplayID: displayID) {
            return match
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshFloatingPanelFrame() {
        guard let panel = floatingPanel else { return }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 100, y: 100, width: 1200, height: 800)
        let frameInCanvas = currentOverlay.frame(in: visible.size, cameraAspect: 16.0/9.0)
        let origin = CGPoint(x: visible.minX + frameInCanvas.origin.x,
                             y: visible.maxY - frameInCanvas.maxY)
        panel.setFrame(CGRect(origin: origin, size: frameInCanvas.size), display: true, animate: false)
    }
}

private struct FloatingRecorderHUD: View {
    let session: AVCaptureSession
    @ObservedObject var cameraManager: CameraManager
    let shape: OverlayShape
    let onScale: (CGFloat) -> Void
    let onSetShape: (OverlayShape) -> Void
    let onReset: () -> Void

    /// `MagnificationGesture` reports cumulative scale since the gesture began; convert to per-update deltas for `onScale`.
    @State private var pinchBase: CGFloat = 1.0

    private var recordingBadge: some View {
        let live = cameraManager.state == .recording
        return HStack(spacing: 6) {
            Circle()
                .fill(live ? EasemoTheme.recordRed : EasemoTheme.textMuted)
                .frame(width: 8, height: 8)
            Text(live ? "REC" : "Starting…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.55))
        .clipShape(Capsule())
    }

    @ViewBuilder
    var body: some View {
        Group {
            if shape == .circle {
                AdaptiveCameraPreviewView(session: session,
                                          cameraManager: cameraManager,
                                          shape: shape)
                    .contentShape(Circle())
            } else {
                AdaptiveCameraPreviewView(session: session,
                                          cameraManager: cameraManager,
                                          shape: shape)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .overlay(alignment: .topLeading) {
            recordingBadge
                .padding(8)
        }
        .background(Color.clear)
        .gesture(MagnificationGesture()
            .onChanged { value in
                let delta = value / pinchBase
                pinchBase = value
                guard delta.isFinite, delta > 0 else { return }
                onScale(delta)
            }
            .onEnded { _ in
                pinchBase = 1.0
            })
        .contextMenu {
            Button("Circle") { onSetShape(.circle) }
            Button("Rectangle") { onSetShape(.rectangle) }
            Divider()
            Button("Size +") { onScale(1.1) }
            Button("Size -") { onScale(0.9) }
            Divider()
            Button("Reset Overlay") { onReset() }
        }
    }
}
