import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Post-recording editing screen: speed slider, optional preview, export.
struct EditingView: View {
    @EnvironmentObject private var appState: AppState
    let recording: RecordingResult

    @State private var isExporting = false
    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    /// Playhead mapped to **source** timeline (`0…recording.duration`) for trim UI.
    @State private var currentTimeSeconds: Double = 0
    /// Output timeline length after trim + speed (matches export).
    @State private var composedOutputDurationSeconds: Double = 0.1
    @State private var previewRebuildTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            header
            previewPlayer
            controls
            Spacer()
            actions
        }
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.13),
                                            Color(red: 0.05, green: 0.06, blue: 0.10)],
                                   startPoint: .top, endPoint: .bottom))
        .onAppear {
            installTimeObserver()
            Task { await rebuildComposedPreview(immediatePlayback: true) }
        }
        .onDisappear {
            previewRebuildTask?.cancel()
            previewRebuildTask = nil
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            player.pause()
        }
        .onChange(of: appState.playbackSpeed, perform: { _ in
            scheduleComposedPreviewRebuild(immediatePlayback: true)
        })
        .onChange(of: appState.trimStartSeconds, perform: { _ in
            scheduleComposedPreviewRebuild(immediatePlayback: true)
        })
        .onChange(of: appState.trimEndSeconds, perform: { _ in
            scheduleComposedPreviewRebuild(immediatePlayback: true)
        })
        .onChange(of: appState.overlay, perform: { _ in
            scheduleComposedPreviewRebuild(immediatePlayback: true)
        })
    }

    private var header: some View {
        HStack {
            Button(action: { appState.backToRecording() }) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Spacer()
            Text("Edit & Export")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 80)
        }
    }

    private var previewPlayer: some View {
        VStack(spacing: 12) {
            if FileManager.default.fileExists(atPath: recording.screenURL.path) {
                MacVideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .frame(minHeight: 260, maxHeight: 360)
                    .overlay(Text("Recording is unavailable").foregroundStyle(.white.opacity(0.6)))
            }

            TrimTimelineView(
                start: trimStartBinding,
                end: trimEndBinding,
                duration: max(recording.duration.seconds, 0),
                currentTime: currentTimeSeconds,
                onScrub: { sourceTime in
                    currentTimeSeconds = sourceTime
                    seekPlayerToSourceTime(sourceTime)
                }
            )
            .frame(height: 40)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Playback Speed")
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: "%.2fx", appState.playbackSpeed))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                Text("Speed")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                Slider(value: $appState.playbackSpeed, in: 0.5...2.0, step: 0.05)
                Text("0.5x")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                Text("2.0x")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Trim")
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(formatTime(appState.trimStartSeconds)) - \(formatTime(appState.trimEndSeconds))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                HStack {
                    Text("Start")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(formatTime(appState.trimStartSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
                HStack {
                    Text("End")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(formatTime(appState.trimEndSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(20)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { appState.trimStartSeconds },
            set: { newValue in
                let maxStart = max(appState.trimEndSeconds - 0.1, 0)
                appState.trimStartSeconds = min(max(newValue, 0), maxStart)
            }
        )
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { appState.trimEndSeconds },
            set: { newValue in
                let duration = max(recording.duration.seconds, 0)
                let minEnd = min(duration, appState.trimStartSeconds + 0.1)
                appState.trimEndSeconds = min(max(newValue, minEnd), duration)
            }
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped.rounded(.towardZero))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 12) {
                Button("Discard", role: .destructive) {
                    appState.backToRecording()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: chooseExportDestination) {
                    Label(isExporting ? "Exporting…" : "Export Video",
                          systemImage: "square.and.arrow.up")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isExporting)
            }
        }
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "easemo-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.canCreateDirectories = true
        panel.title = "Export composed recording"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        Task {
            await appState.export(result: recording, to: url)
            isExporting = false
        }
    }

    /// Rebuild preview from the same `VideoComposer.compose` pipeline as export
    /// so screen + frontal camera overlay match the exported MP4.
    private func scheduleComposedPreviewRebuild(immediatePlayback: Bool) {
        previewRebuildTask?.cancel()
        previewRebuildTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await rebuildComposedPreview(immediatePlayback: immediatePlayback)
        }
    }

    private func rebuildComposedPreview(immediatePlayback: Bool) async {
        guard FileManager.default.fileExists(atPath: recording.screenURL.path) else { return }
        let layout = appState.overlay
        do {
            let bundle = try await appState.composer.compose(result: recording,
                                                               layout: layout,
                                                               speed: appState.playbackSpeed,
                                                               trimStart: appState.trimStartSeconds,
                                                               trimEnd: appState.trimEndSeconds)
            let item = AVPlayerItem(asset: bundle.composition)
            item.videoComposition = bundle.videoComposition
            let outDur = max(bundle.scaledDuration.seconds, 0.05)
            composedOutputDurationSeconds = outDur

            player.pause()
            player.replaceCurrentItem(with: item)
            player.rate = 1.0
            syncSourceTimelineFromCompositionTime(.zero)

            if immediatePlayback {
                player.play()
            }
        } catch {
            // Fallback so UI still plays something usable.
            player.replaceCurrentItem(with: AVPlayerItem(url: recording.screenURL))
            composedOutputDurationSeconds = recording.duration.seconds
        }
    }

    private func installTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { _ in
            let tOut = player.currentTime().seconds
            guard tOut.isFinite else { return }
            if tOut >= composedOutputDurationSeconds - 0.03 {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            syncSourceTimelineFromCompositionTime(player.currentTime())
        }
    }

    /// Map composition clock → source-screen seconds (for brushes / trim overlay).
    private func syncSourceTimelineFromCompositionTime(_ compositionTime: CMTime) {
        let tOut = compositionTime.seconds
        guard tOut.isFinite else { return }
        let trimLen = max(appState.trimEndSeconds - appState.trimStartSeconds, 0.1)
        let u = composedOutputDurationSeconds > 0
            ? min(max(tOut / composedOutputDurationSeconds, 0), 1)
            : 0
        currentTimeSeconds = appState.trimStartSeconds + u * trimLen
    }

    private func seekPlayerToSourceTime(_ sourceSeconds: Double) {
        let trimLen = max(appState.trimEndSeconds - appState.trimStartSeconds, 0.1)
        let uSource = sourceSeconds - appState.trimStartSeconds
        let u = min(max(uSource / trimLen, 0), 1)
        let out = u * composedOutputDurationSeconds
        player.seek(to: CMTime(seconds: out, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }
}

private struct TrimTimelineView: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let currentTime: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let d = max(duration, 0.1)
            let startX = CGFloat(start / d) * width
            let endX = CGFloat(end / d) * width
            let playheadX = CGFloat(min(max(currentTime, 0), d) / d) * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: 8)
                Capsule()
                    .fill(.blue.opacity(0.9))
                    .frame(width: max(endX - startX, 8), height: 8)
                    .offset(x: startX)
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 2, height: 20)
                    .offset(x: playheadX)
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .offset(x: startX - 8)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = min(max(value.location.x, 0), endX - 8)
                        start = Double(x / width) * d
                        onScrub(start)
                    })
                Circle()
                    .fill(.white)
                    .frame(width: 16, height: 16)
                    .offset(x: endX - 8)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = max(min(value.location.x, width), startX + 8)
                        end = Double(x / width) * d
                        onScrub(min(end, max(start, currentTime)))
                    })
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let x = min(max(value.location.x, 0), width)
                onScrub(Double(x / width) * d)
            })
        }
    }
}

private struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
