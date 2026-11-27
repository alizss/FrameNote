import AppKit
import ImageIO
import SwiftUI

/// Sharing controls in the collapsible review details. Attachments prepare without blocking editing or playback.
struct FeedbackShareView: View {
    @ObservedObject var store: ReviewStore
    var showCopyControls = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                if showCopyControls {
                    Button { Task { await store.copyForAI() } } label: {
                        Label(store.isCopyingForAI ? "Preparing…" : "Copy for AI", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isCopyingForAI)
                    .help("Copy instructions and evidence images together")
                    Menu {
                        Button("Copy instructions only") { store.copyForAgent() }
                        if let image = store.shareFiles.first(where: { $0.lastPathComponent.hasSuffix("-sequence.png") || $0.lastPathComponent == "annotated.png" }) {
                            Button("Copy evidence image") { Task { await store.copyImage(at: image) } }
                        }
                    } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
                    if store.isPreparing {
                        ProgressView().controlSize(.small)
                        Text("Preparing evidence…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(store.status.hasPrefix("Copied instructions") ? "Copied · paste into your AI tool" : "Copy text + images · or drag evidence")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Evidence files").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Files") { store.revealExport() }.disabled(store.lastExport == nil)
                Button("Save copy…") { store.export() }
            }.buttonStyle(.borderless)
            if !store.shareFiles.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(store.shareFiles, id: \.self) { url in
                            attachment(url)
                        }
                    }
                }.frame(height: 48)
            } else {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(store.isPreparing ? "Your marked frames and clips will appear here." : "Images and clips prepare automatically as you review.")
                    if store.status.contains("failed") {
                        Button("Retry") { Task { await store.prepareFeedback() } }
                    }
                }.font(.caption).foregroundStyle(.secondary).frame(height: 32)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))

    }

    private func attachment(_ url: URL) -> some View {
        HStack(spacing: 7) {
            AttachmentThumbnail(url: url).frame(width: 42, height: 32)
            Text(label(for: url)).font(.system(size: 11, weight: .medium)).lineLimit(2)
                .frame(width: 105, alignment: .leading)
            if url.pathExtension == "png" {
                Button { Task { await store.copyImage(at: url) } } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy image to paste into chat")
            } else {
                Image(systemName: "hand.draw").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onDrag {
            store.retainPreparedFeedback()
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .help("Drag \(url.lastPathComponent) into your chat")
    }

    private func label(for url: URL) -> String {
        let name = url.lastPathComponent
        if name == "annotated.png" { return "Marked screenshot" }
        if name == "reference.png" { return "Design example" }
        if name == "wireframe.png" { return "Wireframe" }
        if name.hasPrefix("inspiration-") { return "Attachment" }
        if name == "feedback.md" { return "Instructions" }
        if name.hasPrefix("moment-") {
            let number = Int(name.split(separator: "-")[1]) ?? 1
            if name.hasSuffix("-sequence.png") { return "\(number) · Motion sequence" }
            if name.hasSuffix("-clip.mov") { return "\(number) · Selected clip" }
            return "\(number) · Marked frame"
        }
        return "Full recording"
    }
}

struct AttachmentThumbnail: View {
    let url: URL
    var maxPixels = 100
    @State private var thumbnail: CGImage?
    var body: some View {
        Group {
            if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: url.pathExtension == "md" ? "doc.text" : "film").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            guard url.pathExtension == "png" else { return }
            thumbnail = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true
                ] as CFDictionary)
            }.value
        }
    }
}

/// Always visible; these are the exact image files written to the clipboard.
struct CopyEvidencePreview: View {
    @ObservedObject var store: ReviewStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Images included in copy").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.copyEvidenceURLs.count) image\(store.copyEvidenceURLs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            if store.copyEvidenceURLs.isEmpty {
                HStack {
                    if store.isPreparing { ProgressView().controlSize(.small) }
                    Text(store.isPreparing ? "Preparing timestamped frames…" : "Evidence unavailable")
                    if !store.isPreparing {
                        Button("Retry") { Task { await store.prepareFeedback(fullExport: false) } }.buttonStyle(.borderless)
                    }
                }.font(.caption).frame(height: 124)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(store.copyEvidenceURLs.enumerated()), id: \.element) { index, url in
                            VStack(alignment: .leading, spacing: 4) {
                                AttachmentThumbnail(url: url, maxPixels: 400)
                                    .frame(width: 200, height: 112)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                Text("\(index + 1) · " + (url.lastPathComponent.contains("-sample-") ? url.deletingPathExtension().lastPathComponent.components(separatedBy: "-").last!.replacingOccurrences(of: "ms", with: " ms") : "Reference image"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.onDrag {
                                store.retainPreparedFeedback()
                                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                            }
                        }
                    }
                }.frame(height: 140)
            }
        }
    }
}
