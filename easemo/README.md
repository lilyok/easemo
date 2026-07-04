# easemo

> **easy + demo** — a lightweight, fully-local screen recording and editing tool for macOS.

`easemo` records your screen, webcam, and microphone at the same time, then
composes them into a single H.264 MP4 with a configurable webcam overlay
(rectangle or circle) and adjustable playback speed. Audio is preserved with
formant-aware time stretching, so the speaker's voice keeps its natural tone
even at 0.5× or 2× speed. Everything happens on-device — there is no network
or cloud component.

---

## Features

- **Screen recording** with [`ScreenCaptureKit`](https://developer.apple.com/documentation/screencapturekit) (main display, configurable frame rate, hardware H.264 via `AVAssetWriter`).
- **Webcam recording** with `AVCaptureSession` + `AVCaptureVideoDataOutput`.
- **Microphone recording** with a dedicated `AVCaptureSession` writing AAC to a separate `.m4a` file. Pluggable on/off.
- **Synchronized capture**: all pipelines start back-to-back from a shared coordinator and timestamp each track using its own clock for later alignment.
- **Post-recording composition** with a custom `AVVideoCompositing` implementation backed by Core Image — supports rectangle and circle masking and arbitrary corner placement.
- **Playback speed adjustment** (0.5×–2.0×) via `AVMutableCompositionTrack.scaleTimeRange`. Audio is rendered through an `AVAudioMix` whose `audioTimePitchAlgorithm` is set to `.spectral`, so voices sound natural (no chipmunk effect at 2×, no deep-voice effect at 0.5×).
- **Mute / unmute audio** in the editing screen — applies to both preview and export.
- **MP4 export** via `AVAssetExportSession` with progress reporting.
- **SwiftUI UI** with a recording screen and an editing/export screen.

---

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15.0 or later
- Apple silicon or Intel Mac with a webcam

---

## Project layout

```text
easemo/
├── easemo.xcodeproj/                  # Xcode project
└── easemo/
    ├── App/
    │   ├── EasemoApp.swift            # @main entry point
    │   └── AppState.swift             # Single source of truth
    ├── Capture/
    │   ├── RecordingManager.swift     # ScreenCaptureKit pipeline
    │   ├── CameraManager.swift        # Webcam pipeline (AVCapture)
    │   ├── AudioRecordingManager.swift  # Microphone pipeline (AVCapture)
    │   ├── CaptureSessionCoordinator.swift  # Starts/stops all pipelines
    │   ├── SampleBufferWriter.swift   # AVAssetWriter wrapper (video)
    │   └── AudioSampleWriter.swift    # AVAssetWriter wrapper (audio, AAC)
    ├── Composition/
    │   ├── VideoComposer.swift        # Builds AVMutableComposition + videoComposition
    │   └── OverlayVideoCompositor.swift  # Custom AVVideoCompositing (Core Image)
    ├── Export/
    │   └── ExportManager.swift        # AVAssetExportSession driver
    ├── Models/
    │   ├── RecordingConfiguration.swift
    │   └── RecordingResult.swift
    ├── UI/
    │   ├── RootView.swift
    │   ├── RecordingView.swift
    │   ├── CameraPreviewView.swift    # NSViewRepresentable for AVCaptureVideoPreviewLayer
    │   └── EditingView.swift
    ├── Resources/
    │   ├── Info.plist                 # Usage descriptions
    │   └── easemo.entitlements        # Sandbox + camera/microphone access
    ├── Assets.xcassets/
    └── Preview Content/
└── easemoTests/
    ├── OverlayLayoutTests.swift
    └── AppStateTests.swift
```

The architecture is intentionally modular — each module has a single
responsibility and can be tested in isolation:

| Module | Responsibility |
| --- | --- |
| `RecordingManager` | Configure `SCStream`, route frames into `SampleBufferWriter`. |
| `CameraManager` | Configure `AVCaptureSession`, expose a SwiftUI preview, write frames. |
| `CaptureSessionCoordinator` | Start/stop both pipelines together; produce a `RecordingResult`. |
| `VideoComposer` | Build `AVMutableComposition` + `AVMutableVideoComposition`; apply speed scaling. |
| `OverlayVideoCompositor` | Custom Core Image–based compositor that draws the camera over the screen with shape masking. |
| `ExportManager` | Drive `AVAssetExportSession`, surface progress. |
| `AppState` | Top-level view model owning the long-lived service objects. |

---

## How the pipelines fit together

```
                 ┌───────────────────────┐
   Screen frames │   RecordingManager    │  SampleBufferWriter   ── easemo-screen-*.mp4
   (SCStream) ──▶│  + ScreenStreamOutput │
                 └───────────────────────┘
                                                CaptureSessionCoordinator
                 ┌───────────────────────┐                │
   Camera frames │    CameraManager      │  SampleBufferWriter   ── easemo-camera-*.mp4
   (AVCapture) ─▶│  + CameraSampleHandler│                │
                 └───────────────────────┘                │
                 ┌───────────────────────┐                │
   Mic samples   │ AudioRecordingManager │  AudioSampleWriter    ── easemo-audio-*.m4a
   (AVCapture) ─▶│  + AudioSampleHandler │                │
                 └───────────────────────┘                ▼
                                                    RecordingResult
                                                          │
                                                          ▼
                                                   VideoComposer
                                  (uses OverlayVideoCompositor for video,
                                   AVAudioMix .spectral for pitch-preserve)
                                                          │
                                                          ▼
                                                   ExportManager  ──▶ user-selected .mp4
```

---

## ScreenCaptureKit pipeline (one-paragraph version)

`RecordingManager.startRecording(frameRate:)` discovers shareable content with
`SCShareableContent`, picks the first display, and builds an
`SCStreamConfiguration` whose `minimumFrameInterval` is set from the requested
frame rate. An `SCStream` is created with a `SCStreamOutput` (the
`ScreenStreamOutput` class) that:

1. Filters out incomplete (non-`SCFrameStatus.complete`) frames — those are
   ScreenCaptureKit's "idle" notifications and should not be encoded.
2. On the first sample, starts the `AVAssetWriter` session at the sample's
   presentation time so the timeline begins at zero.
3. Appends every subsequent sample buffer to the writer.

The writer (`SampleBufferWriter`) wraps an `AVAssetWriterInput` with an H.264
codec configured at ~6 bits/pixel and a 2-second key frame interval, suitable
for both desktop demos and high-motion content.

## AVAssetWriter usage

`SampleBufferWriter` is the single chokepoint for frames going to disk:

- A single video input is added per writer.
- `expectsMediaDataInRealTime = true` because both pipelines feed live
  samples.
- Out-of-order samples are dropped so the timeline is strictly monotonic.
- `start(at:)` is called with the first frame's PTS so that the writer's
  session origin matches the source clock.

## Composition logic

`VideoComposer.compose(result:layout:speed:trimStart:trimEnd:muteAudio:)`:

1. Creates an `AVMutableComposition` and inserts the screen video track
   spanning `[trimStart, trimEnd)`.
2. If the camera recording exists and the layout is visible, inserts the
   camera video track.
3. If the microphone recording exists, inserts its audio track over the same
   trimmed range.
4. Applies playback speed by calling `scaleTimeRange(_:toDuration:)` on every
   composition track. Because the same scale is applied uniformly, audio
   stays in sync.
5. Builds an `AVMutableVideoComposition` whose render size is the screen's
   natural size (corrected for the screen's `preferredTransform`) and whose
   `customVideoCompositorClass` is `OverlayVideoCompositor`. The
   `OverlayInstruction`s carry the screen track ID, optional camera track
   ID, the camera frame rect (computed via `OverlayLayout.frame(in:cameraAspect:)`)
   and the desired shape.
6. Builds an `AVMutableAudioMix` whose sole `AVMutableAudioMixInputParameters`
   pins `audioTimePitchAlgorithm = .spectral`. This is the formant-aware
   time-stretch algorithm: when `scaleTimeRange` is applied to the audio
   track to match a 0.5×–2× playback speed, the **pitch is preserved** and
   the speaker's voice keeps its natural tone. Mute is implemented as a
   single `setVolume(0, at: .zero)` ramp on the same parameters object.

The same `audioMix` is forwarded to:

- `AVPlayerItem.audioMix` for the editing-screen preview (so what you hear
  while previewing matches the export).
- `AVAssetExportSession.audioMix` for the final MP4. The export session also
  sets `audioTimePitchAlgorithm = .spectral` directly as a belt-and-braces
  default for any audio path that doesn't go through the mix.

The custom compositor uses Core Image to:

- Render the screen frame as the background.
- Transform the camera frame into the configured overlay frame.
- Optionally apply a soft circular mask via `CIRadialGradient` +
  `CIBlendWithMask`.
- Render to the destination pixel buffer with a hardware-backed `CIContext`.

This approach was chosen over the more common
`AVVideoCompositionCoreAnimationTool` + `CALayer` pattern because the latter
applies its layer tree as post-processing on top of the entire composition,
which makes it hard to mask only the camera region without baking the screen
underneath through the same mask.

---

## Running the project

1. Open `easemo/easemo.xcodeproj` in Xcode 15 or later.
2. Select the **easemo** scheme and the **My Mac** destination.
3. Press **⌘R** to build and run.
4. The first time you start a recording, macOS will prompt for **Screen
   Recording**, **Camera**, and **Microphone** access — grant all three in
   *System Settings → Privacy & Security*.
5. Click the big record button. Click it again to stop. The app routes you
   straight to the editing screen.
6. Adjust the playback speed slider, choose an overlay shape and position,
   then click **Export Video** to save an `.mp4`.

### Running the tests

```bash
xcodebuild -project easemo/easemo.xcodeproj \
           -scheme easemo \
           -destination 'platform=macOS' \
           test
```

The test target (`easemoTests`) covers the pure-Swift modules:

- `OverlayLayoutTests` — overlay frame placement / clamping.
- `AppStateTests` — elapsed-time formatter, AppState bindings, default mic / mute state.
- `VideoComposerAudioTests` — composer-side wiring of the `.spectral` pitch algorithm and mute behavior, exercised against synthesized fixture media (`TestMediaFixtures`).

When a fixture build fails, temp files are normally deleted automatically. Set **`EASEMO_KEEP_FAILED_TEST_MEDIA=1`** to skip deleting the temp URL when cleanup would only remove an on-disk file (for example a failure before `startWriting`). If `AVAssetWriter` is still `.writing`, **`cancelWriting()`** runs and **Apple’s API removes the output file** for that session, so there is often nothing left to inspect for mid-write failures.

### LSP / `buildServer.json`

The repository ships without a `buildServer.json`. If you use a Swift LSP
client outside Xcode (e.g. SourceKit-LSP through neovim or VS Code via
[`xcode-build-server`](https://github.com/SolaWing/xcode-build-server)),
generate the config locally — its `build_root` and the path to the
`xcode-build-server` binary are machine-specific so the file is gitignored:

```bash
xcode-build-server config \
    -workspace easemo/easemo.xcodeproj/project.xcworkspace \
    -scheme easemo
```

---

## Notes & non-goals (v1)

- **Single display only.** Multi-display capture is not in v1.
- **No real-time compositing.** All overlay/scale work happens during export.
- **No cloud, no analytics, no telemetry.**
- **No third-party dependencies.** Only Apple frameworks.

### Possible follow-ups

- Background blur for the webcam (Vision / Core Image)
- Layout presets
- Per-source audio mixing (system audio + microphone with separate volumes)
- Noise suppression on the microphone track

---

© 2026 Liliia Ivanova. Built with Swift, SwiftUI, AVFoundation, and ScreenCaptureKit.
