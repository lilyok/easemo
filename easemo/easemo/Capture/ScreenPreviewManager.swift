import AppKit
import Combine
import CoreGraphics
import Foundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

/// One-shot screen snapshots for the configuration canvas.
/// Avoids a live `SCStream` and does not block first layout on ScreenCaptureKit.
@MainActor
public final class ScreenPreviewManager: ObservableObject {

    @Published public private(set) var displays: [CaptureDisplay] = []
    @Published public private(set) var hasFrame = false
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var activeDisplayID: UInt32?

    private weak var previewView: ScreenPreviewView.PreviewNSView?
    private var snapshotTask: Task<Void, Never>?

    private static let maxPreviewWidth: CGFloat = 480

    public init() {}

    func attachPreviewView(_ view: ScreenPreviewView.PreviewNSView) {
        previewView = view
    }

    public func refreshDisplays() {
        displays = CaptureDisplay.connectedScreens()
    }

    public func startPreview(displayID: UInt32?) {
        if displays.isEmpty {
            refreshDisplays()
        }
        let resolvedID = CaptureDisplayResolver.resolveID(
            preferred: displayID,
            available: displays.map(\.id),
            main: CGMainDisplayID()
        )
        if isRunning, activeDisplayID == resolvedID, snapshotTask != nil || hasFrame {
            return
        }

        snapshotTask?.cancel()
        activeDisplayID = resolvedID
        isRunning = resolvedID != nil
        lastError = nil

        guard let resolvedID else {
            lastError = RecordingManager.RecordingError.noDisplayAvailable.localizedDescription
            hasFrame = false
            return
        }

        #if canImport(ScreenCaptureKit)
        snapshotTask = Task { [weak self] in
            // Let the recording UI appear before the first screenshot.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await self?.captureSnapshot(displayID: resolvedID)
        }
        #endif
    }

    public func stopPreview() {
        snapshotTask?.cancel()
        snapshotTask = nil
        isRunning = false
        activeDisplayID = nil
        hasFrame = false
        previewView?.clear()
    }

    #if canImport(ScreenCaptureKit)
    private func captureSnapshot(displayID: UInt32) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let filter = RecordingManager.makeContentFilter(display: display, content: content)
            let config = SCStreamConfiguration()
            let scale = min(1, Self.maxPreviewWidth / max(CGFloat(display.width), 1))
            config.width = Self.evenPixelCount(Int(CGFloat(display.width) * scale))
            config.height = Self.evenPixelCount(Int(CGFloat(display.height) * scale))
            config.showsCursor = false
            config.scalesToFit = true

            let image: CGImage
            if #available(macOS 14.0, *) {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: config)
            } else if let fallback = CGDisplayCreateImage(displayID) {
                image = fallback
            } else {
                return
            }
            guard !Task.isCancelled else { return }
            previewView?.present(image)
            if !hasFrame {
                hasFrame = true
            }
            lastError = nil
        } catch {
            if !Task.isCancelled {
                lastError = error.localizedDescription
            }
        }
    }
    #endif

    private static func evenPixelCount(_ value: Int) -> Int {
        max(2, value - (value % 2))
    }
}
