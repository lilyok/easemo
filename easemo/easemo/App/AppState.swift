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
                        overlay: self.overlay,
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

    public func startRecording() async {
        do {
            errorMessage = nil
            statusMessage = "Preparing…"
            try await coordinator.start(configuration: configuration)
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    public func stopRecording() async {
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
            route = .editing(result)
        } catch {
            errorMessage = error.localizedDescription
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
        route = .recording
        statusMessage = ""
        trimStartSeconds = 0
        trimEndSeconds = 0
        muteAudio = false
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

    func setStopAction(_ action: @escaping () -> Void) {
        stopAction = action
    }

    func didStartRecording(includeCamera: Bool,
                           cameraSession: AVCaptureSession,
                           overlay: OverlayLayout,
                           onOverlayChanged: @escaping (OverlayLayout) -> Void) {
        self.onOverlayChanged = onOverlayChanged
        self.currentOverlay = overlay
        self.cameraSession = cameraSession
        NSApplication.shared.windows.first(where: \.isVisible)?.miniaturize(nil)
        installStatusItem()
        if includeCamera {
            installFloatingPanel(session: cameraSession, overlay: overlay, shape: overlay.shape)
        }
    }

    func didStopRecording() {
        removeStatusItem()
        removeFloatingPanel()
        if let window = NSApplication.shared.windows.first {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
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
                                      overlay: OverlayLayout,
                                      shape: OverlayShape) {
        guard floatingPanel == nil else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
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

    private func removeFloatingPanel() {
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        onOverlayChanged = nil
        cameraSession = nil
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
        guard let panel = floatingPanel, let session = cameraSession else { return }
        panel.contentView = NSHostingView(
            rootView: FloatingRecorderHUD(session: session,
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
    let shape: OverlayShape
    let onScale: (CGFloat) -> Void
    let onSetShape: (OverlayShape) -> Void
    let onReset: () -> Void

    /// `MagnificationGesture` reports cumulative scale since the gesture began; convert to per-update deltas for `onScale`.
    @State private var pinchBase: CGFloat = 1.0

    @ViewBuilder
    var body: some View {
        Group {
            if shape == .circle {
                CameraPreviewView(session: session, shape: shape)
                    .contentShape(Circle())
            } else {
                CameraPreviewView(session: session, shape: shape)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
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
