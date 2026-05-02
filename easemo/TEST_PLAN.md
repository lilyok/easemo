# easemo — backlog test plan

Manual checks to run once the current feature work is **complete**. Use this as a sign-off list before release or a big merge.

---

## 1. Overlay motion during recording → preview & export

**Expectation:** While recording, the floating PiP can be moved (and resized/shaped as implemented). The **edit preview** and the **exported composed file** must show the PiP **moving over time**, not frozen at a single position.

- [ ] Record with camera on; drag the PiP several times during capture; stop.
- [ ] On the edit screen, scrub/play: PiP position follows the motion you made.
- [ ] Export & open the file in another player: same behavior as preview.

---

## 2. Single overlay when camera overlay is on

**Expectation:** If the user has the **overlay (webcam) enabled**, the delivered video must show **exactly one** composited face/overlay — no duplicate PiP (e.g. screen capture must not also grab the app’s own floating window).

- [ ] Record with overlay enabled; ensure the main UI / floating panel is not captured as a second face on the screen track.
- [ ] Export preview: only one PiP instance in the final composite.

---

## 3. Speed & trim affect the result

**Expectation:** Changing **playback speed** and **trim** on the edit screen changes what you see in preview and what gets exported — preview and export stay aligned.

- [ ] Trim in/out: preview duration and visible content match trim; export matches preview.
- [ ] Change speed (e.g. slower / faster): preview reflects it; export matches preview.
- [ ] Combine trim + speed and spot-check start/end of visible action.

---

## 4. Readable UI copy (contrast)

**Expectation:** Every **button** and **label** stays readable in context: no **dark text on dark backgrounds** or **light text on light backgrounds** without enough contrast (including disabled/hover states where applicable).

- [ ] Recording screen: all primary actions and status text readable.
- [ ] Edit & export screen: controls, sliders, timeline, headers readable.
- [ ] Menu bar / floating PiP chrome (if any text): readable.
- [ ] Quick pass in both **light-looking** and **dark-looking** areas of the app chrome (as designed).

---

## Notes

- Tick items when verified; add initials/date in git or a ticket if your team tracks that way.
- If an item fails, log the build, macOS version, and steps to reproduce alongside a short screen recording if possible.
