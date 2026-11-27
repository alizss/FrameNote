import AppKit
import AVKit
import FrameNoteCore
import SwiftUI
import WebKit

struct VariantWorkshop: View {
    @ObservedObject var store: ReviewStore
    let markID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var mode: VariantMode = .motion
    @State private var draft: ReviewVariant?
    @State private var comparisonID: UUID?
    @State private var replay = 0
    @State private var speed = 1.0
    @State private var showSource = false

    private var mark: ReviewMark? { store.marks.first { $0.id == markID } }
    private var variants: [ReviewVariant] { (mark?.variants ?? []).filter { $0.mode == mode } }
    private var comparison: ReviewVariant? { variants.first { $0.id == comparisonID } ?? variants.first }
    private var hasChanges: Bool {
        guard let draft else { return false }
        return mark?.variants?.first { $0.id == draft.id } != draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Try options").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let mark {
                Text(mark.note.isEmpty ? "Explore alternatives for this comment." : mark.note)
                    .font(.callout).lineLimit(3)
                Text("Local, coded templates · These demonstrate behavior using a sample interface. Your screenshot or recording is the reference.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Explore", selection: $mode) {
                        ForEach(VariantMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 300)
                    Button(showSource ? "Hide reference" : "Show reference") { showSource.toggle() }
                    Spacer()
                    Picker("Playback", selection: $speed) {
                        Text("1×").tag(1.0); Text("0.5×").tag(0.5); Text("0.25×").tag(0.25)
                    }.frame(width: 120)
                    Button { replay += 1 } label: { Label("Replay both", systemImage: "play.fill") }
                }
                if showSource {
                    if let image = store.screenshot {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 160)
                    } else if let player = store.player {
                        VideoPlayer(player: player).frame(height: 160)
                        Text("Original recording · use its playback controls to review the source moment.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if var draft {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Compare", selection: $comparisonID) {
                                ForEach(variants) { variant in
                                    Text("\(variant.version) · \(variant.title)").tag(Optional(variant.id))
                                }
                            }
                            if let comparison {
                                PrototypePreview(variant: comparison, note: mark.note, replay: replay, speed: speed)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Try", selection: Binding(get: { self.draft?.id }, set: { id in
                                self.draft = variants.first { $0.id == id }
                            })) {
                                ForEach(variants) { variant in
                                    Text("\(variant.version) · \(variant.title)").tag(Optional(variant.id))
                                }
                            }
                            PrototypePreview(variant: draft, note: mark.note, replay: replay, speed: speed)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(draft.rationale).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        VStack(alignment: .leading) {
                            Text("Duration · \(Int(draft.durationMS)) ms").font(.caption)
                            Slider(value: draftBinding(\.durationMS, fallback: 180), in: 80...600, step: 10)
                        }
                        VStack(alignment: .leading) {
                            Text("Travel · \(Int(draft.distance)) px").font(.caption)
                            Slider(value: draftBinding(\.distance, fallback: 16), in: 0...64, step: 2)
                        }
                        VStack(alignment: .leading) {
                            Text("Spacing · \(Int(draft.spacing)) px").font(.caption)
                            Slider(value: draftBinding(\.spacing, fallback: 16), in: 8...32, step: 2)
                        }
                    }
                    HStack {
                        Picker("Easing", selection: draftBinding(\.easing, fallback: .gentle)) {
                            ForEach(VariantEasing.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Interaction", selection: draftBinding(\.presentation, fallback: .drawer)) {
                            ForEach(VariantPresentation.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Dim background", isOn: draftBinding(\.dimBackground, fallback: false))
                    }.font(.caption)
                    TextField("Refinement note for the coding agent…", text: draftBinding(\.refinement, fallback: ""))
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Reset adjustments") { self.draft = variants.first { $0.id == draft.id } }
                            .disabled(!hasChanges)
                        Button("Save refinement") {
                            self.draft = store.saveRefinement(draft, for: markID)
                        }.disabled(!hasChanges)
                        Spacer()
                        Button("Copy code") { copy(draft.html(note: mark.note), message: "Prototype HTML copied.") }
                        Button("Use this") {
                            if hasChanges, let saved = store.saveRefinement(draft, for: markID) { draft = saved; self.draft = saved }
                            store.selectVariant(draft.id, for: markID)
                        }.buttonStyle(.borderedProminent)
                    }
                    if let selected = mark.variants?.first(where: { $0.id == mark.selectedVariantID }) {
                        HStack {
                            Label("Chosen: \(selected.version) · \(selected.title)", systemImage: "checkmark.circle")
                            Text("Issue stays open until you approve it.").foregroundStyle(.secondary)
                            Spacer()
                            Button("Copy implementation brief") {
                                copy(selected.implementationBrief(note: mark.note), message: "Implementation brief copied.")
                            }
                        }.font(.caption)
                    }
                }
            } else {
                Text("This comment was removed. Undo the deletion to restore its options.")
                Spacer()
            }
        }
        .padding(20).frame(minWidth: 880, idealWidth: 960, minHeight: 680, idealHeight: 740)
        .onAppear {
            mode = mark?.variants?.first?.mode ?? (store.videoURL == nil ? .visual : .motion)
            prepareMode()
        }
        .onChange(of: mode) { _, _ in prepareMode() }
        .onChange(of: speed) { _, _ in replay += 1 }
    }

    private func prepareMode() {
        store.ensureVariants(for: markID, mode: mode)
        draft = variants.first { $0.id == mark?.selectedVariantID } ?? variants.dropFirst().first ?? variants.first
        comparisonID = variants.first?.id
    }

    private func draftBinding<T>(_ key: WritableKeyPath<ReviewVariant, T>, fallback: T) -> Binding<T> {
        Binding(get: { draft?[keyPath: key] ?? fallback }, set: { draft?[keyPath: key] = $0 })
    }

    private func copy(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store.status = message
    }
}

/// Keep the document alive while interacting; only settings changes replace the HTML.
private struct PrototypePreview: NSViewRepresentable {
    let variant: ReviewVariant
    let note: String
    let replay: Int
    let speed: Double

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.speed = speed
        let key = variant.id.uuidString + note
        let settings = variant.previewSettingsJSON
        if coordinator.documentKey != key {
            coordinator.documentKey = key
            coordinator.settings = settings
            coordinator.replay = replay
            coordinator.loaded = false
            view.loadHTMLString(variant.html(note: note), baseURL: nil)
        } else if coordinator.settings != settings || coordinator.replay != replay {
            coordinator.settings = settings
            coordinator.replay = replay
            if coordinator.loaded { coordinator.apply(to: view) }
        }
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var documentKey = ""
        var settings = "{}"
        var replay = 0
        var speed = 1.0
        var loaded = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            apply(to: webView)
        }
        func apply(to webView: WKWebView) {
            webView.evaluateJavaScript("applySettings(\(settings), \(speed))", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
