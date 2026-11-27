# FrameNote

Turn a visual reference into a brief for Codex or another coding AI.

1. Paste a public social-post or media URL and press **Analyze reference**. You can also open, paste, or drop an image, GIF, or video.
2. FrameNote imports the media and starts analysis. Connect your AI provider on first use.
3. Review the visible text and timestamped images, then click **Copy for AI**.

The copy preview shows the exact text and evidence images sent to the clipboard. Evidence prepares in the background; Copy for AI becomes available when it is ready. Some receiving apps accept only text; drag the visible image previews into those apps. No sharing dropdown is needed.

## Links

Public social-video imports use [yt-dlp](https://github.com/yt-dlp/yt-dlp), installed separately:

```sh
brew install yt-dlp
```

FrameNote looks in Homebrew and `~/.local/bin`. It downloads one video, with a 200 MB limit and a two-minute timeout. No browser cookies or account credentials are read. Private, restricted, deleted, or site-blocked posts can fail. Direct images/videos and pages exposing media use the built-in importer. GIFs become playable clips.

## Analysis

Connect Codex CLI, Claude Code CLI, OpenAI, Anthropic, or an image-capable OpenAI-compatible endpoint in Settings. Account modes use the official installed CLI and its existing login. API keys are stored in Keychain.

Analysis sends sampled frames through the selected provider. It does not hear audio or inspect continuous motion; inferred timing and measurements are estimates. Links alone cannot guarantee that the receiving AI can see the media, so attach evidence when needed.

Local interactions target feedback within 150 ms. Network downloads, AI analysis, and evidence export take longer and show progress. This is a target, not a guarantee for every device or operation.

## Optional tools

FrameNote starts in the menu bar. Hover or click its icon to open the compact importer. The review uses a single header and a flat surface. Settings remain in the importer.

**Recent** is available in the launcher and review header. Search saved references by title or notes, then click one to reopen its media, annotations, and analysis. References save automatically on this Mac; opening another reference preserves the previous one. The latest draft from older versions is carried into Recent, but previously overwritten drafts cannot be recovered.

Working drafts live in `~/Library/Application Support/FrameNote/Draft`; imported sources and prepared exports live alongside them. Nothing uploads until analysis or sharing is requested.

## Develop

Requires macOS 14+ and Xcode command-line tools.

```sh
swift build
swift test --scratch-path /private/tmp/framenote-spm -j 2
./build.sh
open ~/Applications/FrameNote.app
```

`build.sh` installs at `~/Applications/FrameNote.app` and links it in the repository. It uses an Apple Development signing identity if available; otherwise ad-hoc signing. Built with SwiftUI, AppKit, AVFoundation, and ScreenCaptureKit.

Live import tests are opt-in: set `FRAMENOTE_TEST_SOCIAL_URL` or `FRAMENOTE_TEST_VIDEO_URL` when running tests.

MIT — see [LICENSE](LICENSE).
