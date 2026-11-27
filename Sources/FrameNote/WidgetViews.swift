import SwiftUI

struct StartPanelView: View {
    @ObservedObject var store: ReviewStore
    var onContinue: () -> Void
    var onOpen: () -> Void
    var onPaste: () -> Void
    private var hasReview: Bool { store.screenshot != nil || store.videoURL != nil }

    var onImport: (URL) -> Void
    var importing: Bool
    var onCancel: () -> Void
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a reference").font(.system(size: 19, weight: .semibold))
                Text("Turn a reference into instructions for your AI.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextField("Paste a social post or media link", text: $link)
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onSubmit { submit() }.disabled(importing)
            Button(action: submit) {
                HStack(spacing: 8) {
                    if importing { ProgressView().controlSize(.small) }
                    Text(importing ? "Getting reference…" : "Analyze reference")
                }.frame(maxWidth: .infinity).frame(height: 26)
            }.buttonStyle(.borderedProminent).disabled(importing || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack(spacing: 16) {
                Button("Open file", action: onOpen).disabled(importing)
                Button("Paste media", action: onPaste).disabled(importing)
                Spacer()
                if importing { Button("Cancel", action: onCancel) }
                else if hasReview { Button("Back to reference", action: onContinue) }
            }.buttonStyle(.borderless).font(.callout).disabled(store.isCapturing)
            Text(importing || store.status.hasPrefix("Could not") ? store.status : "X / Twitter, social videos, GIFs, images · or drop a file")
                .font(.caption).foregroundStyle(.secondary).lineLimit(4)
        }
    }

    private func submit() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            store.status = "Could not read this link. Paste a full https:// URL."
            return
        }
        onImport(url)
    }
}

struct RecordingWidgetView: View {
    @ObservedObject var store: ReviewStore
    var onHide: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                WindowDragHandle()
                    .overlay { Image(systemName: "line.3.horizontal").font(.system(size: 12)).foregroundStyle(.secondary).allowsHitTesting(false) }
                    .frame(width: 16, height: 46).help("Drag to move recording controls")
                WindowDragHandle()
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Circle().fill(.red).frame(width: 6, height: 6)
                                Text(store.isCapturing ? "Saving recording" : "Recording").font(.caption).foregroundStyle(.secondary)
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(elapsed(at: context.date)).font(.system(size: 21, weight: .semibold, design: .monospaced))
                            }
                        }.allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity).frame(height: 52)
                Button { store.toggleRecording() } label: {
                    HStack(spacing: 6) {
                        if store.isCapturing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "stop.fill").font(.system(size: 11)) }
                        Text(store.isCapturing ? "Saving" : "Stop").font(.system(size: 13, weight: .semibold))
                    }.padding(.horizontal, 13).frame(height: 34)
                        .foregroundStyle(.white).background(Color.red, in: Capsule())
                }.buttonStyle(.plain).disabled(store.isCapturing)
            }.frame(height: 52)
            HStack {
                Text("Screen recording").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Hide", action: onHide).buttonStyle(.borderless).font(.caption2)
                    .help("Recording continues. Click FrameNote in the menu bar to show controls again.")
            }.frame(height: 20)
        }.frame(height: 80)
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(store.recordingStartedAt ?? date)))
        return seconds >= 3600 ? String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
                               : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
