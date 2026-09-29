# FrameNote

FrameNote is a small, open-source macOS app for giving precise visual feedback on a running app. Capture a window, point to a problem, measure a gap, leave several notes, and export a report that a designer, engineer, or coding agent can act on. It is an independent project and has no dependency on CloudClip.

## Try it

Requires macOS 14 or later and the Xcode command-line tools.

```sh
./build.sh
open FrameNote.app
```

1. Click **Capture Window** and select the window to review, or **Open Image** to use an existing screenshot. macOS may ask you to allow Screen Recording for FrameNote. If capture fails after granting permission, quit and reopen FrameNote.
2. Choose **Point**, **Arrow**, or **Measure**. Click for a point; drag for an arrow or a distance. Add a short note for each mark in the right panel.
3. Optionally add a **Before Image** and turn on **Compare** to scrub between it and the current image.
4. Click **Export Feedback** and choose a destination. FrameNote creates a timestamped folder with:
   - `screenshot.png` — the unmodified capture
   - `annotated.png` — numbered marks on the capture
   - `feedback.json` — structured marks in normalized image coordinates
   - `feedback.md` — a readable summary for an agent or teammate
   - `reference.png` — the optional before image

Attach `annotated.png` and `feedback.md` to a coding-agent thread, or give the agent the report folder path. The screenshot and notes remain local until you choose to share them. FrameNote does not upload them or read clipboard history. Measurements are screenshot pixels; Retina scaling means they may differ from layout points in the app's source code.

## Why this exists

Visual feedback is often simple to *see* and tedious to *describe*. “Make these gaps equal” should take one mark and one sentence, without opening an image editor or guessing which component owns the layout. FrameNote keeps each annotation as data, so an agent can connect the mark to the original image and verify the intended change.

This first version captures still images and supports manual before/after comparison. It does not yet capture UI event traces, record motion, map a mark to a source file, or automatically apply a code change.

## Development

```sh
swift build
swift test --scratch-path /private/tmp/framenote-spm -j 1
./build.sh
```

The app is written in SwiftUI and AppKit with no third-party packages. `build.sh` installs an ad-hoc signed app at `~/Applications/FrameNote.app` and links it as `FrameNote.app` in the repository root. The link is ignored by Git. The source project stays in this repository; the runnable bundle lives outside the synced Documents folder because its Finder metadata can invalidate macOS code signing. The test and build commands use temporary build directories for the same reason.

## Roadmap

- Faster capture and annotation: configurable shortcut, window targeting, undo/redo, movable marks, and a native image-share flow.
- Better review: synchronized before/after images, side-by-side motion comparison, and approval of individual notes.
- Better diagnostics: optional UI element identities and event markers supplied by the target app, with a small integration SDK.
- Wider support: evaluate Windows and Linux after the Mac workflow has been tested with real users.

## License

MIT. See [LICENSE](LICENSE).
