import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// Post-recording editing screen: trim, speed, preview, export.
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
    @State private var lastExportedURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 4)
            ScrollView {
                VStack(spacing: 20) {
                    previewSection
                    controlsPanel
                }
                .padding(.top, 12)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(easemoEditingBackground)
        .onAppear {
            appState.statusMessage = ""
            appState.playbackSpeed = (appState.playbackSpeed * 2).rounded() / 2
            appState.playbackSpeed = min(max(appState.playbackSpeed, 0.5), 2.0)
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
        .onChange(of: appState.muteAudio, perform: { _ in
            scheduleComposedPreviewRebuild(immediatePlayback: true)
        })
    }

    private var easemoEditingBackground: some View {
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
        ZStack {
            HStack {
                Button(action: { appState.backToRecording() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(EasemoTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(EasemoTheme.sliderTrackInactive.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous)
                            .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                Spacer()
                Menu {
                    Button("Back to recording") { appState.backToRecording() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(EasemoTheme.textSecondary)
                        .frame(width: 36, height: 28)
                        .background(EasemoTheme.sliderTrackInactive.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusInput, style: .continuous))
                }
                .menuStyle(.borderlessButton)
            }
            Text("Edit & Export")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(EasemoTheme.textPrimary)
        }
    }

    private var previewSection: some View {
        VStack(spacing: 16) {
            if FileManager.default.fileExists(atPath: recording.screenURL.path) {
                MacVideoPlayerView(player: player)
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                            .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            } else {
                RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                    .fill(EasemoTheme.sliderTrackInactive.opacity(0.5))
                    .frame(minHeight: 260, maxHeight: 380)
                    .overlay(
                        Text("Recording is unavailable")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(EasemoTheme.textMuted)
                    )
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
            .frame(height: 84)
        }
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            trimSummaryRow

            VStack(alignment: .leading, spacing: 10) {
                Text("Speed: \(formatSpeedLabel(appState.playbackSpeed))")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(EasemoTheme.textPrimary)

                SpeedSnapSliderRow(speed: snappedSpeedBinding)
            }

            Divider()
                .background(EasemoTheme.panelBorder)

            HStack(spacing: 12) {
                Text("Audio")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(EasemoTheme.textPrimary)
                if recording.audioURL != nil {
                    HStack(spacing: 10) {
                        Text("Mute")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(EasemoTheme.textSecondary)
                        Toggle("", isOn: $appState.muteAudio)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(EasemoTheme.accentPurple)
                            .accessibilityLabel("Mute audio")
                    }
                } else {
                    Spacer()
                    Text("No microphone audio in this recording.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(EasemoTheme.textMuted)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .easemoPanelStyle()
    }

    private var trimSummaryRow: some View {
        HStack {
            Text("Trim")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EasemoTheme.textMuted)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
            Text("\(formatTime(appState.trimStartSeconds)) → \(formatTime(appState.trimEndSeconds))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(EasemoTheme.textSecondary)
        }
    }

    private var snappedSpeedBinding: Binding<Double> {
        Binding(
            get: { appState.playbackSpeed },
            set: { newValue in
                let stepped = (newValue * 2).rounded() / 2
                appState.playbackSpeed = min(max(stepped, 0.5), 2.0)
            }
        )
    }

    private func formatSpeedLabel(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f×", value)
        }
        return String(format: "%.1f×", value)
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
        VStack(alignment: .leading, spacing: 12) {
            if let url = lastExportedURL {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(EasemoTheme.accentPurple)
                        Text("Video exported")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(EasemoTheme.textPrimary)
                    }
                    Button(action: { revealInFinder(url) }) {
                        Text("Reveal in Finder")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(EasemoTheme.accentPurple)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EasemoTheme.sliderTrackInactive.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: EasemoTheme.radiusPanel, style: .continuous)
                        .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                )
            }

            if isExporting || (!appState.statusMessage.isEmpty && lastExportedURL == nil) {
                Text(appState.statusMessage.isEmpty ? "Working…" : appState.statusMessage)
                    .font(.system(size: 13, weight: .regular).monospacedDigit())
                    .foregroundStyle(EasemoTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    lastExportedURL = nil
                    appState.backToRecording()
                } label: {
                    Text("Discard")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(EasemoTheme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(EasemoTheme.sliderTrackInactive)
                .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous)
                        .stroke(EasemoTheme.panelBorder, lineWidth: 1)
                )

                Button(action: chooseExportDestination) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isExporting ? "Exporting…" : "Export Video")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(EasemoTheme.accentGradient)
                .clipShape(RoundedRectangle(cornerRadius: EasemoTheme.radiusButton, style: .continuous))
                .shadow(color: EasemoTheme.accentPurple.opacity(0.35), radius: 12, y: 5)
                .disabled(isExporting)
                .opacity(isExporting ? 0.65 : 1)
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "easemo-\(Int(Date().timeIntervalSince1970)).mp4"
        panel.canCreateDirectories = true
        panel.title = "Export composed recording"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        lastExportedURL = nil
        Task {
            await appState.export(result: recording, to: url)
            isExporting = false
            if appState.errorMessage == nil {
                lastExportedURL = url
            }
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
                                                             trimEnd: appState.trimEndSeconds,
                                                             muteAudio: appState.muteAudio)
            let item = AVPlayerItem(asset: bundle.composition)
            item.videoComposition = bundle.videoComposition
            item.audioTimePitchAlgorithm = .spectral
            if let audioMix = bundle.audioMix {
                item.audioMix = audioMix
            }
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

// MARK: - Speed control (aligned ticks + labels)

private struct SpeedSnapSliderRow: View {
    @Binding var speed: Double
    private let marks: [Double] = [0.5, 1.0, 1.5, 2.0]
    /// Matches AppKit slider horizontal padding so thumb centers line up with labels.
    private let sliderHorizontalInset: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let totalW = max(geo.size.width, 1)
            let trackW = max(totalW - sliderHorizontalInset * 2, 1)
            let labelY: CGFloat = 30

            ZStack(alignment: .topLeading) {
                Slider(value: $speed, in: 0.5...2.0, step: 0.5)
                    .tint(EasemoTheme.accentPurple)
                    .padding(.horizontal, sliderHorizontalInset)

                ForEach(marks, id: \.self) { mark in
                    let u = (mark - 0.5) / 1.5
                    let x = sliderHorizontalInset + CGFloat(u) * trackW
                    Capsule()
                        .fill(EasemoTheme.textMuted.opacity(0.45))
                        .frame(width: 2, height: 6)
                        .position(x: x, y: 10)
                        .allowsHitTesting(false)

                    let selected = abs(speed - mark) < 0.01
                    Text(Self.speedTickLabel(mark))
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundStyle(selected ? EasemoTheme.accentPurple : EasemoTheme.textSecondary)
                        .position(x: x, y: labelY)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 48)
    }

    private static func speedTickLabel(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f×", value)
        }
        return String(format: "%.1f×", value)
    }
}

// MARK: - Trim timeline

private struct TrimTimelineView: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let currentTime: Double
    let onScrub: (Double) -> Void

    private let barHeight: CGFloat = 10
    private let handleWidth: CGFloat = 10

    @State private var startDragInitial: Double = 0
    @State private var endDragInitial: Double = 0
    @State private var isDraggingStart = false
    @State private var isDraggingEnd = false

    /// Horizontal inset so trim handles and playhead are not clipped at window edges.
    private let trackHorizontalInset: CGFloat = 16
    private let trackAreaHeight: CGFloat = 44

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let d = max(duration, 0.1)
            let trackWidth = max(width - trackHorizontalInset * 2, 1)
            let startX = trackHorizontalInset + CGFloat(start / d) * trackWidth
            let endX = trackHorizontalInset + CGFloat(end / d) * trackWidth
            let playheadX = trackHorizontalInset + CGFloat(min(max(currentTime, 0), d) / d) * trackWidth
            let barY = (trackAreaHeight - barHeight) / 2
            let handleCenterY = trackAreaHeight / 2

            VStack(spacing: 8) {
                HStack {
                    Text(formatClock(0))
                    Spacer()
                    Text(formatClock(d))
                }
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(EasemoTheme.textMuted)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(EasemoTheme.sliderTrackInactive)
                        .frame(width: trackWidth, height: barHeight)
                        .offset(x: trackHorizontalInset, y: barY)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: max(startX - trackHorizontalInset, 0), height: barHeight)
                        .offset(x: trackHorizontalInset, y: barY)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .frame(width: max(width - trackHorizontalInset - endX, 0), height: barHeight)
                        .offset(x: endX, y: barY)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [EasemoTheme.accentPurple.opacity(0.95), EasemoTheme.accentIndigo.opacity(0.95)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(endX - startX, handleWidth * 2), height: barHeight)
                        .offset(x: startX, y: barY)
                        .shadow(color: EasemoTheme.accentPurple.opacity(0.25), radius: 6, y: 0)

                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 2, height: 22)
                        .position(x: playheadX, y: handleCenterY)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .allowsHitTesting(false)

                    trimHandle(isLeading: true)
                        .position(x: startX, y: handleCenterY)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDraggingStart {
                                        isDraggingStart = true
                                        startDragInitial = start
                                    }
                                    let deltaT = Double(value.translation.width / trackWidth) * d
                                    let newStart = min(max(startDragInitial + deltaT, 0), end - 0.1)
                                    start = newStart
                                    onScrub(start)
                                }
                                .onEnded { _ in
                                    isDraggingStart = false
                                }
                        )

                    trimHandle(isLeading: false)
                        .position(x: endX, y: handleCenterY)
                        .highPriorityGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDraggingEnd {
                                        isDraggingEnd = true
                                        endDragInitial = end
                                    }
                                    let deltaT = Double(value.translation.width / trackWidth) * d
                                    let newEnd = min(max(endDragInitial + deltaT, start + 0.1), d)
                                    end = newEnd
                                    onScrub(min(end, max(start, currentTime)))
                                }
                                .onEnded { _ in
                                    isDraggingEnd = false
                                }
                        )
                }
                .frame(height: trackAreaHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(max(value.location.x, trackHorizontalInset), trackHorizontalInset + trackWidth)
                            onScrub(Double((x - trackHorizontalInset) / trackWidth) * d)
                        }
                )

                HStack {
                    Text("Start \(formatClock(start))")
                    Spacer()
                    Text("End \(formatClock(end))")
                }
                .font(.system(size: 11, weight: .regular).monospacedDigit())
                .foregroundStyle(EasemoTheme.textSecondary)
            }
        }
    }

    private func trimHandle(isLeading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color(red: 0.94, green: 0.95, blue: 0.97))
            .frame(width: handleWidth, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(EasemoTheme.sliderTrackInactive)
                    .frame(width: 2, height: 12)
                    .offset(x: isLeading ? 1 : -1)
            )
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }

    private func formatClock(_ seconds: Double) -> String {
        let t = max(0, seconds)
        let total = Int(t.rounded(.towardZero))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
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
