# FrameNote

FrameNote is an open-source macOS app for giving clear visual feedback on UI work. Record an interaction or open a screenshot, mark the exact place and moment, and send the evidence to a designer, developer, or coding agent. It is an independent project with no dependency on CloudClip.

## Try it

Requires macOS 14 or later and Xcode command-line tools.

```sh
./build.sh
open ~/Applications/FrameNote.app
```

1. Click **Record** to capture the primary display, or open a screenshot, image, or video. FrameNote’s own windows are excluded from screen recordings. Recording captures video only; it does not record audio.
2. Pause where the issue appears. With **Comment** selected, drag a box around the relevant area (or click a point), then type in the small comment card beside it. **Done** closes the card; click the marked area or use the comments menu to reopen it.
3. To comment on motion, choose **Select time** and drag across the playback bar. Drag either blue handle to adjust the start or end. This attaches the range to the open comment, or creates a new one. You can select time first and then draw an area before typing. The annotation stays visible throughout its time range. The repeat button loops three seconds around the playhead.
4. Click **Share feedback** to export the original recording or image, marked moments, notes, and a structured JSON report. After exporting, **Copy for agent** copies a paste-ready summary with the evidence folder path.

Capture controls stay in a small floating widget. Stop opens a larger review in the same floating window: drag an edge to resize it, use the magnifiers to zoom, and comment directly beside your selection. There is no permanent sidebar. Drag the header to move the window. The collapse button returns to the small widget without losing the current review.

FrameNote also lives in the macOS menu bar. Click its viewfinder icon to show or hide the widget. The widget's × button hides it and keeps the current review in memory; right-click the menu-bar icon for **Quit FrameNote**.

The tools are:

- **Comment:** drag to select an area or click an element, then type. Video comments can cover one frame or a time range.
- **Guide:** place a full-screen horizontal or vertical alignment line with one click.
- **Measure gap:** drag between two points to see the distance in screenshot pixels.
- **Compare gaps:** drag across gap A, then gap B. FrameNote reports both sizes and their difference.
- **Move here:** drag from the current position to the intended position.
- **Focus area:** draw a box around the relevant area.
- **Arrow:** point toward a detail.

Reviews stay on your Mac until you choose to share them. FrameNote does not upload recordings or read clipboard history. Measurements use image pixels; Retina pixels may differ from layout points in source code.

## What gets exported

The timestamped review folder includes:

- `recording.mov` (or the original video filename) when reviewing video
- `screenshot.png` and `annotated.png` as a poster frame for clips or the original screenshot and its annotations for still reviews
- A `moment-XX.png` and `moment-XX-marked.png` pair for each video note, plus a `focus` crop when that note uses **Focus area**
- A `focus-XX.png` crop for each still image focus note
- `feedback.md` with comments, locations, measured gaps, and timestamps or time ranges
- `feedback.json` with normalized coordinates, start/end times, mark types, and loop bounds
- `reference.png` when a before image is provided

## Development

```sh
swift build
swift test --scratch-path /private/tmp/framenote-spm -j 1
./build.sh
```

The app uses SwiftUI, AppKit, AVFoundation, and ScreenCaptureKit with no third-party packages. `build.sh` installs the app at `~/Applications/FrameNote.app` and links it as `FrameNote.app` in the repository root. When an Apple Development signing identity is available, the build uses it so macOS can keep Screen Recording consent across rebuilds; set `FRAMENOTE_SIGNING_IDENTITY` to select a specific identity. Without one, it falls back to ad-hoc signing, which may cause macOS to ask for Screen Recording permission again after rebuilds. The source project lives in this repository; the runnable app lives outside the synced Documents folder because Finder metadata there can invalidate macOS code signing. The build uses a temporary directory for the same reason.

## License

MIT. See [LICENSE](LICENSE).
