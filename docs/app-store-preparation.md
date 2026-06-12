# Easemo Mac App Store preparation

This document collects the practical release checklist and paste-ready draft text
for publishing **easemo** on the **Mac App Store**.

Drafted from the current repository state. Review all legal, privacy, pricing,
and account-specific details before submission.

## Current app facts

- Platform: macOS app for the Mac App Store.
- Bundle ID: `com.easemo.easemo`.
- Display name in app: `easemo`.
- Version/build in repo: `1.0` / `1`.
- Category: Video.
- Minimum macOS in `Info.plist`: `14.0`.
- Main purpose: local screen, webcam, and microphone recording for product demos.
- Export format: H.264 MP4 saved to a user-selected location.
- Monetization: free exports include a small `easemo` watermark; one-time
  non-consumable Lifetime Access purchase removes the watermark permanently.
- In-app purchase product ID: `com.easemo.easemo.lifetime`.
- Local StoreKit price in repo: USD 9.99.
- Network posture: no analytics, no telemetry, no cloud upload. StoreKit
  purchase/restore is the expected App Store network path.

## Owner inputs to prepare

These need an Apple Developer account, App Store Connect access, external
assets, or legal/account decisions.

- Apple Developer team ID and App Store Connect access.
- App Store Connect app record for bundle ID `com.easemo.easemo`.
- SKU, primary language, copyright holder, and contact details.
- Paid Apps Agreement, tax, and banking setup if selling Lifetime Access.
- App icon source artwork and full macOS app icon set, including 1024 x 1024.
- Screenshots and/or preview video captured from a release build.
- Public support URL.
- Public privacy policy URL.
- Optional marketing URL.
- Final price tier for Lifetime Access.
- Final privacy policy/legal review.
- Age rating questionnaire answers.
- Sandbox testers for purchase/restore validation.

## Technical checklist before submission

### App configuration

- Set `DEVELOPMENT_TEAM` in the Xcode project or local signing settings.
- Confirm Mac App Store signing, sandboxing, hardened runtime, and provisioning.
- Align deployment target settings:
  - `Info.plist` currently says macOS `14.0`.
  - The Xcode project currently includes `MACOSX_DEPLOYMENT_TARGET = 13.0`.
  - Choose one supported minimum, then make README, project, and plist match.
- Add the actual app icon PNG files referenced by the asset catalog.
- Add or verify `PrivacyInfo.xcprivacy` for required privacy manifest
  declarations, including any reportable Apple APIs used by the app.
- Confirm export-compliance answer. If Easemo only uses Apple system networking
  for StoreKit/App Store services and no custom encryption, this is typically
  the "no non-exempt encryption" path, but confirm before setting it.
- Verify the sandbox entitlement `com.apple.security.network.client` works for
  StoreKit purchase and restore in a release/sandbox build. Enable it if
  StoreKit requires outbound App Store connectivity.
- Verify screen recording, camera, microphone, and user-selected file access
  entitlements against current Mac App Store review requirements.
- Confirm the Lifetime Access copy matches product behavior. Current behavior
  appears to remove the export watermark; recording and editing are otherwise
  available without purchase.

### App Store Connect setup

- Create the Mac app record in App Store Connect.
- Register the non-consumable in-app purchase:
  - Product ID: `com.easemo.easemo.lifetime`
  - Reference name: `Lifetime Access`
  - Display name: `Lifetime Access`
  - Draft description: `Remove the easemo watermark from every export with a one-time purchase.`
- Add an IAP review screenshot showing the Lifetime Access purchase UI.
- Configure pricing and availability for the app and the IAP.
- Add support and privacy policy URLs.
- Complete App Privacy details.
- Complete age rating.
- Complete export compliance.
- Add App Review notes from this document.

### Validation

- Run unit tests:

  ```bash
  xcodebuild -project easemo/easemo.xcodeproj \
             -scheme easemo \
             -destination 'platform=macOS' \
             test
  ```

- Run the manual release checklist in `easemo/TEST_PLAN.md`.
- Test a release-signed build on a clean macOS user account:
  - First-run permission prompts for Screen Recording, Camera, and Microphone.
  - Start/stop recording.
  - Webcam overlay position, size, shape, and blur.
  - Trim and playback speed preview.
  - Export MP4 to a user-selected path.
  - Free export watermark.
  - Lifetime Access purchase and restore in sandbox.
  - Watermark-free export after purchase.
- Archive and validate through Xcode Organizer before upload.

## Paste-ready App Store metadata

### App name

```text
easemo
```

Alternative if you want title case in App Store Connect:

```text
Easemo
```

### Subtitle

30-character limit.

```text
Screen demos made easy
```

### Promotional text

170-character limit.

```text
Record your screen, webcam, and microphone, then trim, adjust speed, place your webcam overlay, and export a shareable MP4 - all locally on your Mac.
```

### Short marketing line

Useful for a website, press kit, or screenshot caption.

```text
Record. Compose. Ship demos faster.
```

### Description

```text
Easemo is a lightweight screen recorder for Mac that helps you create clear product demos without sending your recordings to the cloud.

Record your screen, webcam, and microphone together, then compose the final video after recording. Place your webcam overlay where it belongs, choose a rectangle or circle shape, trim the result, adjust playback speed, and export a shareable MP4.

Built for product makers, founders, educators, support teams, and anyone who needs to explain software quickly.

Features:

- Record your main display for product demos and walkthroughs
- Add your webcam as a picture-in-picture overlay
- Record microphone narration
- Blur the webcam background
- Drag and resize the webcam overlay
- Choose rectangle or circle webcam shapes
- Trim the start and end of your recording
- Export at 0.5x, 1x, 1.5x, or 2x speed
- Keep voices natural when changing playback speed
- Mute audio when you want a silent export
- Save the final video as an MP4
- Work locally on your Mac, with no cloud upload, analytics, or telemetry

Free exports include a small easemo watermark. Lifetime Access is a one-time purchase that removes the watermark from exports permanently.

Easemo is designed for a simple workflow: record, compose, export, and share.
```

### Keywords

100-character limit. Current draft is under the limit.

```text
screen recorder,webcam,demo,video,product,training,mp4,editor,mac,local
```

### What's New for version 1.0

```text
Initial Mac App Store release of easemo: local screen, webcam, and microphone recording with trim, speed controls, webcam overlay composition, background blur, and MP4 export.
```

## In-app purchase metadata

### Reference name

```text
Lifetime Access
```

### Product ID

```text
com.easemo.easemo.lifetime
```

### Display name

```text
Lifetime Access
```

### Description

```text
Remove the easemo watermark from every export with a one-time purchase.
```

### App Review notes for IAP

```text
Lifetime Access is a non-consumable one-time purchase. The free version can record, edit, and export videos with a small easemo watermark. Purchasing Lifetime Access removes the watermark from exports permanently. Use the Edit & Export screen after recording a short clip to view the purchase and restore controls.
```

## App Review notes

```text
Easemo is a local Mac screen recording and editing app.

To test the main flow:
1. Launch the app.
2. Enable Webcam and Microphone if needed.
3. Click Start Recording.
4. Grant Screen Recording, Camera, and Microphone permissions when macOS prompts.
5. Record a short clip, then stop recording.
6. On the Edit & Export screen, adjust trim, playback speed, audio mute, and webcam overlay options.
7. Click Export Video and save the MP4 to a user-selected location.

The app does not require a user account. Recordings are processed locally on the Mac. The only expected network path is App Store/StoreKit purchase and restore for the non-consumable Lifetime Access product.
```

## Privacy policy draft

Publish this on your website and update the bracketed fields before submission.

```text
Privacy Policy for Easemo

Effective date: [DATE]

Easemo is a Mac app for recording and composing screen, webcam, and microphone videos locally on your device.

Data collection

Easemo does not collect, sell, share, or track personal data. Easemo does not include analytics, advertising SDKs, third-party tracking SDKs, or cloud upload features.

Screen, camera, and microphone content

When you grant permission, Easemo can record your screen, webcam, and microphone so you can create demo videos. This content is processed locally on your Mac. Easemo does not upload your recordings to our servers.

Files

During recording and editing, Easemo may create temporary media files on your Mac. When you export a video, you choose where the MP4 file is saved. You are responsible for the content you choose to record and export.

Purchases

Easemo offers an optional one-time Lifetime Access purchase through Apple StoreKit. Apple processes payments. Easemo receives purchase entitlement status from Apple so it can enable watermark-free exports. Easemo does not receive your payment card details.

Network use

Easemo does not use a cloud service for recording or editing. Network access may occur through Apple's App Store services for purchase, restore, receipt, and entitlement verification.

Contact

If you have questions about this policy or need support, contact:

[SUPPORT EMAIL]
[SUPPORT URL]
```

## App Privacy answers draft

Use these only after confirming no additional data collection exists outside the
current repository.

- Data collected by the app: None.
- Tracking: No.
- Third-party advertising: No.
- Analytics: No.
- User account: Not required.
- User-generated content sharing inside the app: No.
- Payment data: Not collected by Easemo; purchases are handled by Apple.
- Diagnostics: Not collected by Easemo, unless you separately enable Apple
  developer crash/diagnostic reports in App Store Connect.

## Support page draft

```text
Easemo Support

Easemo is a Mac app for recording your screen, webcam, and microphone, then exporting a composed MP4 demo.

Quick start:
1. Open Easemo.
2. Choose whether to include Webcam and Microphone.
3. Click Start Recording and grant macOS permissions.
4. Stop recording when finished.
5. Trim, adjust speed, position the webcam overlay, and export your MP4.

Permissions:
Easemo needs Screen Recording permission to capture your display, Camera permission for the webcam overlay, and Microphone permission for narration. You can manage these in System Settings > Privacy & Security.

Purchases:
Free exports include a small easemo watermark. Lifetime Access is a one-time purchase that removes the watermark from exports permanently. If you already purchased Lifetime Access, use Restore on the Edit & Export screen.

Contact:
[SUPPORT EMAIL]
```

## Screenshot plan

Capture screenshots from a clean release build using realistic, non-sensitive
demo content. Prefer native Mac screenshots such as 16:10 sizes
(`1280 x 800`, `1440 x 900`, or `2560 x 1600`) and verify current App Store
Connect requirements before upload.

1. Recording screen
   - Caption idea: `Start a polished screen demo in one click.`
   - Show the main record button and input toggles.
2. Webcam overlay
   - Caption idea: `Add your webcam, choose a shape, and place it anywhere.`
   - Show webcam overlay controls and a harmless demo window in the background.
3. Edit and trim
   - Caption idea: `Trim the final video before export.`
   - Show preview and trim timeline.
4. Speed controls
   - Caption idea: `Speed up walkthroughs while keeping voices natural.`
   - Show speed set to 1.5x or 2x.
5. Export
   - Caption idea: `Export a shareable MP4 locally on your Mac.`
   - Show the export confirmation or save panel.

## Age rating draft

Likely rating target: 4+, assuming no hidden web browsing, social features,
user-generated content sharing, gambling, commerce outside Apple IAP, medical
content, or unrestricted content access. Confirm each App Store Connect
question based on the final app behavior.

## Recommended final submission order

1. Finish app icon and screenshot assets.
2. Fix signing/team and deployment target consistency.
3. Add privacy manifest and export compliance setting.
4. Configure the non-consumable IAP in App Store Connect.
5. Publish support and privacy policy pages.
6. Run automated tests and manual QA.
7. Archive, validate, upload, and submit for review with the metadata above.
