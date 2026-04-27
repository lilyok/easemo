import AppKit
import AVKit
import SwiftUI

/// Post-recording editing screen: speed slider, optional preview, export.
struct EditingView: View {
    @EnvironmentObject private var appState: AppState
    let recording: RecordingResult

    @State private var isExporting = false

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
        Group {
            if FileManager.default.fileExists(atPath: recording.screenURL.path) {
                VideoPlayer(player: AVPlayer(url: recording.screenURL))
                    .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .frame(minHeight: 260, maxHeight: 360)
                    .overlay(Text("Recording is unavailable").foregroundStyle(.white.opacity(0.6)))
            }
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
            Slider(value: $appState.playbackSpeed, in: 0.5...2.0, step: 0.05) {
                Text("Speed")
            } minimumValueLabel: {
                Text("0.5x").font(.caption).foregroundStyle(.white.opacity(0.6))
            } maximumValueLabel: {
                Text("2.0x").font(.caption).foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 16) {
                Toggle("Show webcam overlay", isOn: $appState.overlay.isVisible)
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .disabled(recording.cameraURL == nil)
                    .foregroundStyle(.white)

                Picker("Shape", selection: $appState.overlay.shape) {
                    ForEach(OverlayShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(recording.cameraURL == nil || !appState.overlay.isVisible)

                Picker("Position", selection: $appState.overlay.position) {
                    ForEach(OverlayPosition.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .frame(width: 200)
                .disabled(recording.cameraURL == nil || !appState.overlay.isVisible)
            }

            if recording.cameraURL != nil, appState.overlay.isVisible {
                HStack {
                    Text("Overlay size").foregroundStyle(.white.opacity(0.8))
                    Slider(value: $appState.overlay.widthFraction, in: 0.1...0.4)
                    Text(String(format: "%2.0f%%", appState.overlay.widthFraction * 100))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(20)
        .background(.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
}
