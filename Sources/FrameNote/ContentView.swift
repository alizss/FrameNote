import AppKit
import AVKit
import FrameNoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store: ReviewStore
    @FocusState private var focusedMark: UUID?
    @State private var importing = false
    @State private var showingLibrary = false
    @State private var importTask: Task<Void, Never>?
    @State private var zoom: CGFloat = 1
    @State private var activeMark: UUID?
    @State private var selectingTime = false
    @State private var detailedEditing = false
    @AppStorage("reviewCommentsOpen") private var commentsOpen = true
    @AppStorage("reviewDetailsOpen") private var reviewDetailsOpen = false
    @AppStorage("layout.sidebarWidth") private var sidebarWidthValue = 268.0
    @AppStorage("layout.density") private var density: WorkspaceDensity = .compact
    @AppStorage("layout.advancedTools") private var advancedTools = false
    @AppStorage("layout.hideEmptyComments") private var hideEmptyComments = true
    @AppStorage("layout.showHints") private var showHints = false
    @AppStorage("layout.resetGeneration") private var layoutResetGeneration = 0
    @AppStorage("appearance.cornerRadius") private var cornerRadius = 12.0
    @State private var showEmptySidebar = false
    private var sidebarWidth: CGFloat {
        get { CGFloat(sidebarWidthValue) }
        nonmutating set { sidebarWidthValue = Double(newValue) }
    }
    private var commentsVisible: Bool { commentsOpen && (!hideEmptyComments || !store.marks.isEmpty || showEmptySidebar) }
    @State private var sidebarDragWidth: CGFloat?
    @State private var logoHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zoomCenter = UnitPoint2D(x: 0.5, y: 0.5)
    @State private var selectingZoom = false
    @State private var showingLauncher: Bool
    @AppStorage("appearance.theme") private var theme: FrameNoteTheme = .light
    @State private var settingsSection: SettingsSection = .appearance
    @State private var showAPISettings = false
    @State private var pendingAnalysisMarkID: UUID?
    @State private var showInspirationImport = false
    @State private var pasteOnImport = false
    @State private var focusAnimation: Task<Void, Never>?
    private let automaticallyFocusComments: Bool

    init(store: ReviewStore = ReviewStore(restoreSavedDraft: true), automaticallyFocusComments: Bool = true, detailedEditing: Bool = false) {
        self.automaticallyFocusComments = automaticallyFocusComments
        _detailedEditing = State(initialValue: detailedEditing)
        _store = StateObject(wrappedValue: store)
        _showingLauncher = State(initialValue: store.screenshot == nil && store.videoURL == nil)
    }

    private var hasReviewContent: Bool { store.screenshot != nil || store.videoURL != nil }
    private var isReviewing: Bool { (hasReviewContent || showingLibrary) && !store.isRecording && (!showingLauncher || showingLibrary) }
    private var presentation: FrameNotePresentation { store.isRecording ? .recording : isReviewing ? .review : .launcher }
    private var pixelSize: (Int, Int) {
        if let image = store.screenshot { return imagePixelSize(image) }
        return (Int(store.videoSize.width), Int(store.videoSize.height))
    }

    var body: some View {
        VStack(spacing: density.spacing) {
            if !store.isRecording && (!isReviewing || detailedEditing) { header }
            if store.isRecording {
                recordingControls
            } else if showingLibrary {
                ReviewLibraryView(store: store, onClose: { showingLibrary = false })
            } else if isReviewing {
                reviewWorkspace
            } else {
                idleControls
            }
        }
        .padding(.horizontal, store.isRecording ? 12 : density.padding)
        .padding(.bottom, store.isRecording ? 12 : density.padding)
        .padding(.top, isReviewing && !detailedEditing ? 0 : store.isRecording ? 12 : density.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(FrameNoteSurface(theme: theme, compact: !isReviewing))
        .ignoresSafeArea(.container, edges: isReviewing ? .top : [])
        .preferredColorScheme(theme.scheme)
        .onChange(of: presentation, initial: true) { _, mode in
            NSApp.windows.compactMap { $0 as? FloatingPanel }.first?.setPresentation(mode)
        }
        .onChange(of: theme, initial: true) { _, _ in updateWindowAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .frameNoteShowLauncher)) { _ in
            guard !store.isRecording else { return }
            store.pauseForAnnotation(); focusedMark = nil; showingLibrary = false; showingLauncher = true
        }
        .onChange(of: store.openedReviewGeneration) { _, _ in showingLauncher = false }
        .onChange(of: store.isRecording) { _, recording in if recording { showingLauncher = false } }
        .onChange(of: store.videoURL) { _, _ in focusAnimation?.cancel(); zoom = 1; store.tool = .point }
        .onChange(of: store.screenshot) { _, _ in focusAnimation?.cancel(); zoom = 1; store.tool = .point }
        .sheet(isPresented: $showAPISettings) { apiSettings }
        .sheet(isPresented: $showInspirationImport) {
            InspirationImportView(store: store, pasteOnOpen: pasteOnImport, onImported: { referenceImported() })
        }
        .background {
            Button("Paste media") { pasteReference() }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(focusedMark != nil || showAPISettings || showInspirationImport || showingLibrary)
                .hidden()
        }
        .onDisappear { focusAnimation?.cancel() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !importing else { return false }
            startImport(url); return true
        }
        .onChange(of: layoutResetGeneration) { _, _ in showEmptySidebar = false }
        .onChange(of: store.marks.map(\.id)) { _, ids in
            if let activeMark, !ids.contains(activeMark) { self.activeMark = nil; focusedMark = nil }
        }
        .onDeleteCommand { removeSelectedMark() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            brandIcon
            if isReviewing {
                Button { store.pauseForAnnotation(); focusedMark = nil; showingLauncher = true } label: {
                    Label("Start", systemImage: "chevron.left")
                }.buttonStyle(.borderless).font(.caption)
            } else {
                Text("FrameNote").font(.system(size: 13, weight: .semibold))
            }
            WindowDragHandle().frame(height: 26).help("Drag to move FrameNote")
            if isReviewing && detailedEditing {
                Button("Done editing") {
                    store.pauseForAnnotation()
                    detailedEditing.toggle()
                }.buttonStyle(.borderless).font(.caption)
            }
            headerUtilities
        }
        .frame(height: 30)
        .modifier(FrameNoteChrome())
    }

    private var brandIcon: some View {
        WindowDragHandle()
            .overlay {
                Image(systemName: store.isRecording ? "record.circle.fill" : "viewfinder")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(store.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor.opacity(logoHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
            .frame(width: 26, height: 26)
            .onHover { logoHovered = $0 }
            .accessibilityLabel("FrameNote")
            .help("FrameNote · drag to move")
    }

    @ViewBuilder private var headerUtilities: some View {
        libraryButton
        if isReviewing {
            Button { settingsSection = .appearance; showAPISettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.borderless).font(.caption).fixedSize()
            .help("Appearance, workspace, and AI connections").accessibilityLabel("Settings")
        } else {
            Button { settingsSection = .appearance; showAPISettings = true } label: {
                Image(systemName: "gearshape").frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundStyle(.secondary).help("Settings & appearance")
            Button { (NSApp.delegate as? FrameNoteAppDelegate)?.hideWidget(nil) } label: {
                Image(systemName: "xmark").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide FrameNote — reopen from the menu bar")
        }
    }

    private var libraryButton: some View {
        Button {
            store.pauseForAnnotation()
            showingLibrary = true
        } label: { Label("Recent", systemImage: "clock.arrow.circlepath") }
            .buttonStyle(.borderless).font(.callout)
            .disabled(importing || store.isCapturing || store.isRecording)
            .help("Open a previous reference")
    }

    private var idleControls: some View {
        StartPanelView(store: store, onContinue: { showEmptySidebar = false; showingLauncher = false }, onOpen: importMedia,
                       onPaste: pasteReference,
                       onImport: { startImport($0) }, importing: importing,
                       onCancel: { importTask?.cancel() })
    }

    private var recordingControls: some View {
        RecordingWidgetView(store: store, onHide: { (NSApp.delegate as? FrameNoteAppDelegate)?.hideWidget(nil) })
    }

    private func updateWindowAppearance() {
        let appearance: NSAppearance?
        switch theme {
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        default: appearance = nil
        }
        NSApp.windows.compactMap { $0 as? FloatingPanel }.first?.appearance = appearance
    }

    @ViewBuilder private var reviewWorkspace: some View {
        if detailedEditing { detailedWorkspace }
        else { inspirationWorkspace }
    }

    private var inspirationWorkspace: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    store.pauseForAnnotation()
                    showingLauncher = true
                } label: {
                    Label("New reference", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to links and files")

                WindowDragHandle().frame(maxWidth: .infinity, minHeight: 28)
                    .accessibilityHidden(true)

                libraryButton

                Button {
                    let id = store.ensureWholeReview()
                    analyze(id)
                } label: {
                    Text(store.analyzingMarkIDs.isEmpty ? "Analyze" : "Analyzing…")
                }
                .buttonStyle(.bordered)
                .disabled(!store.analyzingMarkIDs.isEmpty || (store.videoURL != nil && store.duration <= 0))
                Button { Task { await store.copyPreviewForAI() } } label: {
                    Label(store.isCopyingForAI ? "Copying…" : "Copy for AI", systemImage: "doc.on.doc")
                }.buttonStyle(.borderedProminent)
                    .disabled(store.lastExport == nil || store.isCopyingForAI)
            }
            .controlSize(.small)
            .frame(height: 28)
            // This row shares the native title bar; leave its traffic lights clear.
            .padding(.leading, 76)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 12) {
                    Group {
                        if let player = store.player {
                            VideoPlayer(player: player)
                        } else if let screenshot = store.screenshot {
                            Image(nsImage: screenshot).resizable().scaledToFit()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                     .clipped()
                    CopyEvidencePreview(store: store)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("What caught your eye?").font(.headline)
                        TextField("Optional: the transition, layout, or a detail to adapt…",
                                  text: referenceNote, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(3...8)
                            .disabled(!store.analyzingMarkIDs.isEmpty)
                        Divider()
                        Text("Text included in copy").font(.headline)
                        Text(store.implementationBrief).font(.system(size: 13))
                            .lineSpacing(4).textSelection(.enabled)
                        if let error = store.analysisErrors.values.first {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 4)
                }.frame(width: 330)
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
        }
        .onAppear { _ = store.ensureWholeReview() }
        .task(id: store.reviewRevision) {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard !Task.isCancelled else { return }
            await store.prepareFeedback(fullExport: false)
        }
    }

    private var referenceNote: Binding<String> {
        Binding(get: {
            store.marks.first(where: { $0.wholeMedia == true && $0.aiGenerated != true })?.note ?? ""
        }, set: { value in
            let id = store.ensureWholeReview()
            if let index = store.marks.firstIndex(where: { $0.id == id }) {
                store.marks[index].note = value
            }
        })
    }

    private var detailedWorkspace: some View {
        VStack(spacing: density.spacing) {
            annotationTools
            Divider()
            HStack(spacing: 0) {
                ReviewCanvas(
                    screenshot: store.screenshot, player: store.player,
                    aspect: store.screenshot?.size ?? store.videoSize,
                    marks: store.marks + (store.pendingGapPreview.map { [$0] } ?? []),
                    wireframe: store.showWireframe ? store.layoutOverlay : nil,
                    tool: store.tool, currentTime: store.videoURL == nil ? nil : store.currentTime,
                    pixelSize: pixelSize, zoom: zoom, zoomCenter: zoomCenter, selectingZoom: selectingZoom,
                    activeMark: activeMark, editableIDs: Set(store.marks.map(\.id)),
                    onStart: { focusAnimation?.cancel(); store.pauseForAnnotation() }, onMark: addMark, onSelect: selectMark,
                    onEdit: { edited in
                        if let index = store.marks.firstIndex(where: { $0.id == edited.id }) { store.marks[index] = edited }
                    },
                    onZoom: zoomToArea, onZoomFactor: zoomBy
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                if commentsVisible {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(width: 1)
                        .padding(.horizontal, 10).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if sidebarDragWidth == nil { sidebarDragWidth = sidebarWidth }
                            sidebarWidth = min(420, max(220, (sidebarDragWidth ?? sidebarWidth) - value.translation.width))
                        }.onEnded { _ in sidebarDragWidth = nil })
                        .help("Drag to resize comments")
                    commentsPanel.frame(width: sidebarWidth)
                }
            }
            if store.player != nil { playbackControls }
            sharingBar
            if reviewDetailsOpen {
                VStack(spacing: 8) {
                    if !store.marks.isEmpty { commentTrack }
                    FeedbackShareView(store: store, showCopyControls: false)
                }.transition(.opacity)
            }
            if showHints {
                HStack {
                    Text(selectingZoom ? "Draw an area to zoom in." : selectingTime ? "Drag across the timeline to select a range." : instruction(for: store.tool))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("Pinch to zoom · scroll to pan").font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.status.hasPrefix("Could not") || store.status.contains("failed") {
                Text(store.status).font(.caption).foregroundStyle(.red)
            }
        }
        .task(id: reviewDetailsOpen ? store.reviewRevision : -1) {
            guard reviewDetailsOpen else { return }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            await store.prepareFeedback()
        }
    }

    private var annotationTools: some View {
        VStack(alignment: .leading, spacing: density.spacing) {
            HStack(spacing: 4) {
                primaryTools
                if !advancedTools {
                    Menu {
                        Button("Move here", systemImage: "arrow.up.right.and.arrow.down.left") { store.tool = .move }
                        Button("Measure", systemImage: "ruler") { store.tool = .measure }
                        Button("Compare gaps", systemImage: "equal") { store.tool = .compareGaps }
                        Button("Horizontal guide", systemImage: "line.3.horizontal") { store.tool = .guideHorizontal }
                        Button("Vertical guide", systemImage: "line.3.horizontal") { store.tool = .guideVertical }
                        Divider()
                        Button("Auto-annotate", systemImage: "wand.and.stars") { runAutoAnnotate() }
                            .disabled(store.isAutoAnnotating)
                    } label: { Text("More tools") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 6)
                }
                Spacer(minLength: 8)
                analysisButton
            }
            if advancedTools {
                HStack(spacing: 4) { precisionTools; Spacer(); inspectionTools }
            }
            HStack(spacing: 12) {
                viewTools
            }.buttonStyle(.borderless).font(.system(size: 12))
        }.font(.system(size: 12, weight: .medium))
    }

    private var sharingBar: some View {
        HStack(spacing: 8) {
            Button { Task { await store.copyForAI() } } label: {
                Label(store.isCopyingForAI ? "Preparing…" : "Copy for AI", systemImage: "doc.on.doc")
            }.buttonStyle(.borderedProminent).controlSize(.small).disabled(store.isCopyingForAI)
                .help("Copy instructions and visual evidence for your AI tool")
            Menu {
                Button("Copy instructions only") { store.copyForAgent() }
                if let image = store.shareFiles.first(where: { $0.lastPathComponent.hasSuffix("-sequence.png") || $0.lastPathComponent == "annotated.png" }) {
                    Button("Copy evidence image") { Task { await store.copyImage(at: image) } }
                }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize()
            if store.status.hasPrefix("Copied instructions") { Text("Copied").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.16)) { reviewDetailsOpen.toggle() }
            } label: {
                Label("Files & feedback", systemImage: reviewDetailsOpen ? "chevron.down" : "chevron.right")
            }.buttonStyle(.borderless).font(.caption)
        }
    }

    @ViewBuilder private var inspectionTools: some View {
        Button { runAutoAnnotate() } label: {
            if store.isAutoAnnotating {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Scanning…") }
            } else {
                Label(autoAnnotateRegion == nil ? "Auto-annotate" : "Auto-annotate area", systemImage: "wand.and.stars")
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .disabled(store.isAutoAnnotating)
        .help(autoAnnotateRegion == nil
              ? "Measure this screenshot or video frame and mark spacing, padding, alignment and contrast problems"
              : "Measure only the selected area and mark what looks wrong")
        if store.layoutOverlay != nil {
            Button { store.showWireframe.toggle() } label: {
                Label("Wireframe", systemImage: "square.dashed.inset.filled")
            }
            .foregroundStyle(store.showWireframe ? Color.purple : .secondary)
            .help(store.showWireframe ? "Hide the detected layout" : "Show the detected layout")
        }
    }

    private var analysisButton: some View {
        Button {
            let id = activeMark ?? store.ensureWholeReview()
            activeMark = id; commentsOpen = true
            analyze(id)
        } label: {
            Label(activeMark.flatMap { id in store.marks.first { $0.id == id } }.map { $0.wholeMedia == true && $0.aiGenerated != true ? (store.videoURL == nil ? "Analyze image" : "Analyze video") : "Analyze selection" }
                  ?? (store.videoURL == nil ? "Analyze image" : "Analyze video"), systemImage: "sparkles")
        }.buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!store.analyzingMarkIDs.isEmpty || (store.videoURL != nil && store.duration <= 0))
            .help("Review the entire image or video without drawing annotations, or analyze a selected comment")
    }

    @ViewBuilder private var viewTools: some View {
        Button {
            if let mark = store.marks.first(where: { $0.id == activeMark }), let end = mark.end, mark.kind == .focus {
                zoomToArea(mark.start, end)
            } else { selectingZoom.toggle(); store.pauseForAnnotation() }
        } label: {
            Label(selectingZoom ? "Cancel zoom" : "Zoom to area", systemImage: "viewfinder")
        }.foregroundStyle(selectingZoom ? Color.accentColor : .primary)
        Button(zoom == 1 ? "Fit" : String(format: "%.1f×", zoom)) { focusAnimation?.cancel(); zoom = 1; zoomCenter = UnitPoint2D(x: 0.5, y: 0.5); selectingZoom = false }
            .help("Fit the whole image")
        Button { store.undoAnnotations() } label: { Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly) }
            .disabled(!store.canUndoAnnotations).help("Undo annotation").keyboardShortcut("z", modifiers: .command)
        Button { store.redoAnnotations() } label: { Label("Redo", systemImage: "arrow.uturn.forward").labelStyle(.iconOnly) }
            .disabled(!store.canRedoAnnotations).help("Redo annotation").keyboardShortcut("z", modifiers: [.command, .shift])
        Button { removeSelectedMark(force: true) } label: { Image(systemName: "trash") }
            .disabled(activeMark == nil).help("Remove selected annotation")
        Button("Clear") {
            store.clearAnnotations(); activeMark = nil; focusedMark = nil; selectingTime = false
        }.disabled(store.marks.isEmpty && store.layoutOverlay == nil && store.pendingGapPreview == nil).help("Clear all comments and marks. Undo restores them.")
        Spacer(minLength: 8)
        if store.layoutOverlay != nil && !advancedTools {
            Button { store.showWireframe.toggle() } label: { Label("Wireframe", systemImage: "square.dashed.inset.filled") }
                .help("Show or hide the detected layout")
        }
        Button {
            let visible = commentsVisible
            withAnimation(.easeOut(duration: 0.16)) {
                commentsOpen = !visible; showEmptySidebar = !visible
            }
            if visible { focusedMark = nil }
        } label: {
            Label("Comments \(store.marks.count)", systemImage: "sidebar.right")
        }.help(commentsVisible ? "Hide comments" : "Show comments")

    }

    /// A box the person drew becomes the area to scan; generated notes never count.
    private var autoAnnotateRegion: CGRect? {
        guard let mark = store.marks.first(where: { $0.id == activeMark }), mark.kind == .focus,
              mark.auto != true, let end = mark.end else { return nil }
        let rect = CGRect(x: min(mark.start.x, end.x), y: min(mark.start.y, end.y),
                          width: abs(mark.start.x - end.x), height: abs(mark.start.y - end.y))
        return rect.width > 0.02 && rect.height > 0.02 ? rect : nil
    }

    private func runAutoAnnotate() {
        let region = autoAnnotateRegion
        focusedMark = nil
        Task {
            if await store.autoAnnotate(in: region) != nil { commentsOpen = true }
        }
    }

    private func zoomToArea(_ start: UnitPoint2D, _ end: UnitPoint2D) {
        focusAnimation?.cancel()
        let width = abs(start.x - end.x), height = abs(start.y - end.y)
        guard width > 0.005, height > 0.005 else { return }
        zoomCenter = UnitPoint2D(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        zoom = min(8, max(1, 0.8 / max(width, height)))
        selectingZoom = false
    }

    private func zoomBy(_ factor: CGFloat, _ anchor: UnitPoint2D) {
        focusAnimation?.cancel()
        zoom = min(8, max(1, zoom * factor))
        zoomCenter = anchor
        selectingZoom = false
    }

    private func removeSelectedMark(force: Bool = false) {
        guard (force || focusedMark == nil), let activeMark else { return }
        store.marks.removeAll { $0.id == activeMark }
        self.activeMark = nil
        focusedMark = nil
        selectingTime = false
    }

    private func analyze(_ markID: UUID) {
        store.pauseForAnnotation()
        if AIConnection.load().configurationError != nil {
            pendingAnalysisMarkID = markID
            openAPISettings()
        } else { store.analyzeDesign(for: markID) }
    }

    private func openAPISettings() {
        settingsSection = .ai
        showAPISettings = true
    }

    private var apiSettings: some View {
        FrameNoteSettingsView(section: settingsSection, onSavedAI: {
            showAPISettings = false
            if let pendingAnalysisMarkID { store.analyzeDesign(for: pendingAnalysisMarkID) }
            pendingAnalysisMarkID = nil
        }, onClose: {
            showAPISettings = false; pendingAnalysisMarkID = nil
        })
    }

    @ViewBuilder private var primaryTools: some View {
        toolButton(.point, title: "Comment")
        toolButton(.focus, title: "Box")
        toolButton(.arrow, title: "Arrow")
        if advancedTools { toolButton(.move, title: "Move here") }
    }

    @ViewBuilder private var precisionTools: some View {
        toolButton(.measure, title: "Measure")
        toolButton(.compareGaps, title: "Compare")
        toolButton(.guideHorizontal, title: "H guide")
        toolButton(.guideVertical, title: "V guide")
    }

    /// Lets a placed comment change type (pin, box, arrow, …) without redrawing it.
    private func kindPicker(_ mark: ReviewMark) -> some View {
        let kinds: [MarkKind] = [.point, .focus, .arrow, .move, .measure, .guideHorizontal, .guideVertical]
        return HStack(spacing: 2) {
            ForEach(kinds) { kind in
                Button { store.convertMark(mark.id, to: kind) } label: {
                    Image(systemName: symbol(for: kind))
                        .rotationEffect(.degrees(kind == .guideVertical ? 90 : 0))
                        .frame(width: 28, height: 24)
                        .foregroundStyle(mark.kind == kind ? Color.accentColor : .secondary)
                        .background(mark.kind == kind ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(ImmediateToolStyle())
                .help("Change to \(kind == .point ? "Comment" : kind.rawValue)")
                .accessibilityLabel(kind == .point ? "Comment" : kind.rawValue)
            }
        }
    }

    private var commentsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comments").font(.headline)
                Text("\(store.marks.filter { !$0.isApproved }.count) open")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if store.marks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "cursorarrow.click.2").font(.title2).foregroundStyle(Color.accentColor)
                    Text("Point. Comment. Share.").font(.subheadline.weight(.semibold))
                    Text("Click a detail or draw a box. Write what should change here.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 20)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(store.marks.enumerated()), id: \.element.id) { index, mark in
                                commentCard(mark, number: index + 1).id(mark.id)
                            }
                        }.padding(2)
                    }
                    .onChange(of: activeMark) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func commentCard(_ mark: ReviewMark, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selectMark(mark.id) } label: {
                HStack(spacing: 7) {
                    Text("\(number)").font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                    Text(mark.wholeMedia == true ? (mark.aiGenerated == true ? "Observation" : "Whole review") : mark.kind == .point ? "Comment" : mark.kind.rawValue).font(.caption.weight(.medium))
                    if mark.aiGenerated == true {
                        Text("AI").font(.system(size: 9, weight: .semibold)).foregroundStyle(.purple)
                    }
                    if mark.auto == true {
                        Text("Auto").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.purple)
                            .help("Measured from the pixels. Edit it, approve it, or delete it.")
                    }
                    Spacer()
                    if let time = mark.time {
                        Text(preciseTime(time)).font(.caption.monospacedDigit())
                    }
                }.foregroundStyle(mark.isApproved ? Color.secondary : Color.accentColor)
            }.buttonStyle(.plain)
            if activeMark == mark.id {
                TextField("What should change?", text: Binding(get: {
                    store.marks.first { $0.id == mark.id }?.note ?? ""
                }, set: { text in
                    if let index = store.marks.firstIndex(where: { $0.id == mark.id }) { store.marks[index].note = text }
                }), axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focusedMark, equals: mark.id)
                .task(id: mark.id) {
                    // The lazy sidebar creates the editor after the mark is selected.
                    // Request focus once its native text field has actually mounted.
                    focusedMark = nil
                    await Task.yield()
                    if activeMark == mark.id { focusedMark = mark.id }
                }
                .onExitCommand { focusedMark = nil }
                if mark.wholeMedia != true { kindPicker(mark) }
                if let time = mark.time {
                    Button {
                        store.pauseForAnnotation(); selectingTime = true
                    } label: {
                        Label(mark.endTime.map { "\(preciseTime(time)) – \(preciseTime($0))" } ?? "Add time range", systemImage: "clock")
                    }.buttonStyle(.borderless).font(.caption)
                    if mark.endTime != nil {
                        Button("Use a single frame") {
                            if let index = store.marks.firstIndex(where: { $0.id == mark.id }) { store.marks[index].endTime = nil }
                        }.buttonStyle(.borderless).font(.caption)
                    }
                }
            } else {
                Button { selectMark(mark.id) } label: {
                    Text(mark.note.isEmpty ? "Write a comment…" : mark.note)
                        .font(.system(size: 13)).foregroundStyle(mark.note.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if activeMark == mark.id, mark.kind == .focus, let end = mark.end {
                HStack {
                    Button("Zoom to this area") { zoomToArea(mark.start, end) }.buttonStyle(.borderless)
                    Spacer()
                    Text("\(Int(abs(end.x - mark.start.x) * Double(pixelSize.0))) × \(Int(abs(end.y - mark.start.y) * Double(pixelSize.1))) px")
                        .foregroundStyle(.secondary)
                }.font(.caption)
            }
            if activeMark == mark.id {
                Button { analyze(mark.id) } label: { Label(mark.wholeMedia == true && mark.aiGenerated != true ? "Analyze whole review" : "Analyze this", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(store.analyzingMarkIDs.contains(mark.id))
                if store.analyzingMarkIDs.contains(mark.id) {
                    HStack { ProgressView().controlSize(.small); Text("Reviewing interaction, motion, and visual design…") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = store.analysisErrors[mark.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let analysis = mark.designAnalysis {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Design suggestions").font(.caption.weight(.semibold))
                        ScrollView { Text(.init(analysis)).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 220)
                        Button("Add suggestions to comment") {
                            if let index = store.marks.firstIndex(where: { $0.id == mark.id }) {
                                let note = store.marks[index].note
                                store.marks[index].note = note.isEmpty ? analysis : note + "\n\n" + analysis
                            }
                        }.buttonStyle(.borderless).font(.caption)
                    }.padding(8).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                }
            }
            HStack {
                Button {
                    if let index = store.marks.firstIndex(where: { $0.id == mark.id }) {
                        store.marks[index].isApproved.toggle()
                    }
                } label: {
                    Label(mark.isApproved ? "Approved" : "Approve", systemImage: mark.isApproved ? "checkmark.circle.fill" : "checkmark.circle")
                }.foregroundStyle(mark.isApproved ? Color.green : Color.secondary)
                Spacer()
                Button {
                    store.marks.removeAll { $0.id == mark.id }
                    if activeMark == mark.id { activeMark = nil; focusedMark = nil; selectingTime = false }
                } label: { Image(systemName: "trash") }
                .help("Remove comment")
            }.buttonStyle(.borderless).font(.caption)
        }
        .padding(12)
        .background(activeMark == mark.id ? Color.accentColor.opacity(0.05) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(activeMark == mark.id ? Color.accentColor.opacity(0.5) : .primary.opacity(0.08), lineWidth: 1))
    }

    private var commentTrack: some View {
        FeedbackTrack(marks: store.marks, duration: store.videoURL == nil ? nil : store.duration,
                      activeMark: activeMark, onSelect: selectMark)
    }

    private func toolButton(_ tool: MarkKind, title: String) -> some View {
        Button { store.tool = tool } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol(for: tool))
                    .rotationEffect(.degrees(tool == .guideVertical ? 90 : 0))
            }
                .padding(.horizontal, density == .compact ? 8 : 12).padding(.vertical, density == .compact ? 6 : 9)
                .foregroundStyle(store.tool == tool ? Color.accentColor : .primary)
                .background(store.tool == tool ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(ImmediateToolStyle()).fixedSize().help(instruction(for: tool))
    }

    private var playbackControls: some View {
        VStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { transportControls; Spacer(); rangeControls }
                VStack(spacing: 4) {
                    HStack(spacing: 10) { transportControls; Spacer() }
                    HStack(spacing: 12) { rangeControls; Spacer() }
                }
            }.font(.system(size: 12)).buttonStyle(.borderless)
            VideoTimeline(currentTime: store.currentTime, duration: store.duration,
                          selection: selectedRange, selecting: selectingTime,
                          marks: store.marks, onSeek: { time in
                store.pauseForAnnotation(); store.seek(to: time)
            }, onRange: setTimeRange)
            .frame(height: 24).padding(.horizontal, 2)
        }
    }

    @ViewBuilder private var transportControls: some View {
        Button { focusedMark = nil; selectingTime = false; store.togglePlayback() } label: {
            Label(store.isPlaying ? "Pause" : "Play", systemImage: store.isPlaying ? "pause.fill" : "play.fill")
        }
        Button { focusedMark = nil; store.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
            .help("Previous frame").accessibilityLabel("Previous frame")
        Button { focusedMark = nil; store.stepFrame(1) } label: { Image(systemName: "forward.frame") }
            .help("Next frame").accessibilityLabel("Next frame")
        Text(preciseTime(store.currentTime)).monospacedDigit().foregroundStyle(.secondary)
        HStack(spacing: 2) {
            ForEach([Float(0.25), 0.5, 1], id: \.self) { rate in
                Button { store.setPlaybackRate(rate) } label: {
                    Text(rate == 1 ? "1×" : rate == 0.5 ? "0.5×" : "0.25×")
                        .font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(store.playbackRate == rate ? Color.accentColor.opacity(0.15) : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(ImmediateToolStyle())
            }
        }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var rangeControls: some View {
        Button {
            store.pauseForAnnotation(); selectingTime.toggle()
        } label: {
            Label(selectingTime ? "Cancel selection" : "Select time range", systemImage: "selection.pin.in.out")
        }.foregroundStyle(selectingTime ? Color.accentColor : .secondary).disabled(store.duration <= 0)
        Button { store.toggleLoop(range: selectedRange) } label: {
            Label(selectedRange == nil ? "Loop 3s" : "Loop selection", systemImage: "repeat")
                .foregroundStyle(store.loopEnabled ? Color.accentColor : .secondary)
        }.disabled(store.duration <= 0)
    }

    private var selectedRange: ClosedRange<Double>? {
        guard let mark = store.marks.first(where: { $0.id == activeMark }),
              let start = mark.time, let end = mark.endTime else { return nil }
        return start...max(start, end)
    }

    private func selectMark(_ id: UUID) {
        guard let mark = store.marks.first(where: { $0.id == id }) else { return }
        store.pauseForAnnotation()
        if let time = mark.time { store.seek(to: time) }
        commentsOpen = true
        activeMark = id
        if automaticallyFocusComments && mark.wholeMedia != true { focusComment(mark) }
        DispatchQueue.main.async { focusedMark = id }
    }

    private func focusComment(_ mark: ReviewMark) {
        focusAnimation?.cancel()
        let points = [mark.start, mark.end, mark.secondStart, mark.secondEnd].compactMap { $0 }
        let loX = points.map(\.x).min() ?? mark.start.x, hiX = points.map(\.x).max() ?? mark.start.x
        let loY = points.map(\.y).min() ?? mark.start.y, hiY = points.map(\.y).max() ?? mark.start.y
        let targetCenter = UnitPoint2D(x: (loX + hiX) / 2, y: (loY + hiY) / 2)
        let targetZoom = min(4, max(1, 0.65 / max(0.22, max(hiX - loX, hiY - loY))))
        let initialZoom = zoom, initialCenter = zoomCenter
        selectingZoom = false
        if reduceMotion { zoom = targetZoom; zoomCenter = targetCenter; return }
        focusAnimation = Task { @MainActor in
            let clock = ContinuousClock(), started = ContinuousClock.now
            while !Task.isCancelled {
                let elapsed = started.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let t = min(1, seconds / 0.32), eased = t * t * (3 - 2 * t)
                zoom = initialZoom + (targetZoom - initialZoom) * eased
                zoomCenter = UnitPoint2D(x: initialCenter.x + (targetCenter.x - initialCenter.x) * eased,
                                        y: initialCenter.y + (targetCenter.y - initialCenter.y) * eased)
                if t == 1 { return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private func setTimeRange(_ range: ClosedRange<Double>) {
        store.pauseForAnnotation()
        store.loopEnabled = false
        store.seek(to: range.lowerBound)
        if let index = store.marks.firstIndex(where: { $0.id == activeMark }) {
            store.marks[index].time = range.lowerBound
            store.marks[index].endTime = range.upperBound
        } else {
            let mark = ReviewMark(kind: .point, start: UnitPoint2D(x: 0.5, y: 0.5),
                                  time: range.lowerBound, endTime: range.upperBound, note: "")
            store.marks.append(mark)
            activeMark = mark.id
        }
        selectingTime = false
        commentsOpen = true
        DispatchQueue.main.async { focusedMark = activeMark }
    }

    private func addMark(start: UnitPoint2D, end: UnitPoint2D?) {
        // A time selection can be refined by drawing an area before writing its note.
        if store.tool == .point, let end,
           let index = store.marks.firstIndex(where: { $0.id == activeMark }),
           store.marks[index].kind == .point, store.marks[index].endTime != nil,
           store.marks[index].note.isEmpty,
           abs(end.x - start.x) > 0.005, abs(end.y - start.y) > 0.005 {
            store.marks[index].kind = .focus
            store.marks[index].start = start
            store.marks[index].end = end
            focusedMark = activeMark
            return
        }
        let count = store.marks.count
        store.addMark(start: start, end: end)
        guard store.marks.count > count, let mark = store.marks.last else { return }
        commentsOpen = true
        activeMark = mark.id
        DispatchQueue.main.async { focusedMark = mark.id }
    }

    private func referenceImported() {
        showingLauncher = false
        detailedEditing = false
        analyze(store.ensureWholeReview())
    }

    private func pasteReference() {
        guard !importing else { return }
        do {
            let media = try ClipboardMedia.read()
            startImport(media.url, cleanup: media.temporary)
        } catch { store.status = "Could not paste. Copy a link, image, or video first." }
    }

    private func startImport(_ url: URL, cleanup: Bool = false) {
        guard !importing else { return }
        importing = true
        store.status = "Getting your reference…"
        importTask = Task {
            defer {
                importing = false
                if cleanup { try? FileManager.default.removeItem(at: url) }
            }
            do {
                try await store.importInspiration(url, source: url.isFileURL ? url.lastPathComponent : url.absoluteString)
                referenceImported()
            } catch is CancellationError { store.status = "Import cancelled." }
            catch { store.status = "Could not import: " + error.localizedDescription }
        }
    }

    private func importMedia() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { startImport(url) }
        }
    }

}

private struct ReviewCanvas: View {
    let screenshot: NSImage?
    let player: AVPlayer?
    let aspect: CGSize
    let marks: [ReviewMark]
    let wireframe: LayoutOverlay?
    let tool: MarkKind
    let currentTime: Double?
    let pixelSize: (Int, Int)
    let zoom: CGFloat
    let zoomCenter: UnitPoint2D
    let selectingZoom: Bool
    let activeMark: UUID?
    let editableIDs: Set<UUID>
    var onStart: () -> Void
    var onMark: (UnitPoint2D, UnitPoint2D?) -> Void
    var onSelect: (UUID) -> Void
    var onEdit: (ReviewMark) -> Void
    var onZoom: (UnitPoint2D, UnitPoint2D) -> Void
    var onZoomFactor: (CGFloat, UnitPoint2D) -> Void
    @State private var draft: ReviewMark?
    @State private var editing: (mark: ReviewMark, handle: MarkEditHandle)?
    @State private var gestureStarted = false

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(in: geometry.size)
            ReviewViewport(documentSize: CGSize(width: max(fitted.width, geometry.size.width), height: max(fitted.height, geometry.size.height)),
                           imageSize: fitted, center: zoomCenter, zoom: zoom, onZoom: onZoomFactor) {
                ZStack(alignment: .topLeading) {
                    media(size: fitted)
                    if let wireframe, wireframe.isVisible(at: currentTime) {
                        WireframeOverlay(overlay: wireframe)
                            .frame(width: fitted.width, height: fitted.height)
                            .allowsHitTesting(false)
                    }
                    MarksOverlay(marks: visibleMarks.filter { $0.id != draft?.id } + (draft.map { [$0] } ?? []), pixelSize: pixelSize, activeMark: activeMark, numbers: Dictionary(uniqueKeysWithValues: marks.enumerated().map { ($0.element.id, $0.offset + 1) }))
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                    AnnotationInputSurface(onStart: onStart, onChange: { start, end in
                            if !gestureStarted {
                                gestureStarted = true
                                if !selectingZoom {
                                    let ordered = visibleMarks.filter { editableIDs.contains($0.id) }.sorted { $0.id == activeMark && $1.id != activeMark }
                                    for mark in ordered {
                                        if let handle = MarkEditing.handle(for: mark, at: start, size: fitted, selected: mark.id == activeMark) {
                                            editing = (mark, handle); break
                                        }
                                    }
                                }
                            }
                            if let editing {
                                draft = MarkEditing.edited(editing.mark, handle: editing.handle, from: start, to: end)
                            } else {
                                draft = ReviewMark(kind: selectingZoom || tool == .point ? .focus : tool, start: start, end: endpoint(end),
                                                   time: currentTime, note: "")
                            }
                        }, onFinish: { start, end in
                            defer { draft = nil; editing = nil; gestureStarted = false }
                            if selectingZoom { onZoom(start, end); return }
                            let clicked = abs(start.x - end.x) * fitted.width < 5 && abs(start.y - end.y) * fitted.height < 5
                            if let editing {
                                if !clicked {
                                    onEdit(MarkEditing.edited(editing.mark, handle: editing.handle, from: start, to: end))
                                }
                                if clicked || activeMark != editing.mark.id { onSelect(editing.mark.id) }
                            } else { onMark(start, endpoint(end)) }
                        })
                        .frame(width: fitted.width, height: fitted.height)
                }
                .frame(width: fitted.width, height: fitted.height)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
        }
    }

    private func endpoint(_ point: UnitPoint2D) -> UnitPoint2D? {
        [.guideHorizontal, .guideVertical].contains(tool) ? nil : point
    }

    private func media(size: CGSize) -> some View {
        Group {
            if let player { PlayerSurface(player: player) }
            else if let screenshot { Image(nsImage: screenshot).resizable() }
        }
        .frame(width: size.width, height: size.height)
    }

    private var visibleMarks: [ReviewMark] { marks.filter { $0.isVisible(at: currentTime) } }

    private func fittedSize(in available: CGSize) -> CGSize {
        let width = max(aspect.width, 1)
        let height = max(aspect.height, 1)
        let scale = min(max(available.width - 16, 1) / width,
                        max(available.height - 16, 1) / height) * zoom
        return CGSize(width: width * scale, height: height * scale)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> PassivePlayerView {
        let view = PassivePlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: PassivePlayerView, context: Context) { view.player = player }

    final class PassivePlayerView: AVPlayerView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

/// The detected layout: boxes around elements and thin lines where several elements share an edge.
private struct WireframeOverlay: View {
    let overlay: LayoutOverlay

    var body: some View {
        Canvas { context, size in
            let purple = Color(red: 0.55, green: 0.25, blue: 0.95)
            for guide in overlay.guides {
                var path = Path()
                if guide.axis == .vertical {
                    path.move(to: CGPoint(x: guide.position * size.width, y: 0))
                    path.addLine(to: CGPoint(x: guide.position * size.width, y: size.height))
                } else {
                    path.move(to: CGPoint(x: 0, y: guide.position * size.height))
                    path.addLine(to: CGPoint(x: size.width, y: guide.position * size.height))
                }
                context.stroke(path, with: .color(purple.opacity(0.3)), lineWidth: 0.6)
            }
            for element in overlay.elements {
                let rect = CGRect(x: element.rect.minX * size.width, y: element.rect.minY * size.height,
                                  width: element.rect.width * size.width, height: element.rect.height * size.height)
                if element.kind == .container { context.fill(Path(rect), with: .color(purple.opacity(0.06))) }
                context.stroke(Path(rect), with: .color(purple.opacity(element.kind == .container ? 0.9 : 0.7)),
                               lineWidth: element.kind == .container ? 1.1 : 0.8)
            }
        }
    }
}

private struct MarksOverlay: View {
    let marks: [ReviewMark]
    let pixelSize: (Int, Int)
    var activeMark: UUID?
    var numbers: [UUID: Int] = [:]

    var body: some View {
        Canvas { context, size in
            for (index, mark) in marks.enumerated() {
                let start = point(mark.start, size)
                let end = mark.end.map { point($0, size) }
                let red = Color.blue
                switch mark.kind {
                case .point:
                    badge(context: &context, at: start, number: numbers[mark.id] ?? (index + 1))
                case .guideHorizontal:
                    stroke(&context, from: CGPoint(x: 0, y: start.y), to: CGPoint(x: size.width, y: start.y), color: .blue, dashed: true)
                    context.draw(Text("H GUIDE").font(.system(size: 10, weight: .medium)).foregroundColor(.blue), at: CGPoint(x: 44, y: start.y - 9))
                case .guideVertical:
                    stroke(&context, from: CGPoint(x: start.x, y: 0), to: CGPoint(x: start.x, y: size.height), color: .blue, dashed: true)
                    context.draw(Text("V GUIDE").font(.system(size: 10, weight: .medium)).foregroundColor(.blue), at: CGPoint(x: start.x + 28, y: 10))
                case .focus:
                    if let end {
                        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                          width: abs(start.x - end.x), height: abs(start.y - end.y))
                        context.fill(Path(rect), with: .color(.blue.opacity(0.04)))
                        context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.blue), lineWidth: 1.25)
                        badge(context: &context, at: CGPoint(x: rect.minX, y: rect.minY), number: numbers[mark.id] ?? (index + 1))
                    }
                case .move:
                    if let end {
                        stroke(&context, from: start, to: end, color: .green, dashed: true)
                        context.stroke(Path(ellipseIn: CGRect(x: start.x - 9, y: start.y - 9, width: 18, height: 18)), with: .color(.blue), lineWidth: 1.25)
                        context.stroke(Path(ellipseIn: CGRect(x: end.x - 10, y: end.y - 10, width: 20, height: 20)), with: .color(.green), lineWidth: 1.25)
                        badge(context: &context, at: end, number: numbers[mark.id] ?? (index + 1))
                    }
                case .arrow:
                    if let end {
                        stroke(&context, from: start, to: end, color: red)
                        arrowHead(&context, from: start, to: end)
                        badge(context: &context, at: start, number: numbers[mark.id] ?? (index + 1))
                    }
                case .measure:
                    if let end {
                        stroke(&context, from: start, to: end, color: red)
                        endpoint(&context, at: start); endpoint(&context, at: end)
                        measureLabel(&context, start: start, end: end, mark: mark)
                    }
                case .compareGaps:
                    if let end {
                        stroke(&context, from: start, to: end, color: .cyan)
                        endpoint(&context, at: start); endpoint(&context, at: end)
                        context.draw(Text("A · \(pixels(mark.start, mark.end)) px").font(.system(size: 11, weight: .medium)).foregroundColor(.cyan), at: midpoint(start, end))
                    }
                    if let secondStart = mark.secondStart.map({ point($0, size) }),
                       let secondEnd = mark.secondEnd.map({ point($0, size) }) {
                        stroke(&context, from: secondStart, to: secondEnd, color: .purple)
                        endpoint(&context, at: secondStart); endpoint(&context, at: secondEnd)
                        context.draw(Text("B · \(pixels(mark.secondStart, mark.secondEnd)) px").font(.system(size: 11, weight: .medium)).foregroundColor(.purple), at: midpoint(secondStart, secondEnd))
                        badge(context: &context, at: start, number: numbers[mark.id] ?? (index + 1))
                    }
                }
                if mark.id == activeMark, mark.end != nil {
                    var handles: [UnitPoint2D] = []
                    if mark.kind == .focus, let end = mark.end {
                        handles = [mark.start, end, UnitPoint2D(x: mark.start.x, y: end.y), UnitPoint2D(x: end.x, y: mark.start.y)]
                    } else {
                        handles = [mark.start, mark.end, mark.secondStart, mark.secondEnd].compactMap { $0 }
                    }
                    for handle in handles {
                        let location = point(handle, size)
                        let path = Path(roundedRect: CGRect(x: location.x - 4, y: location.y - 4, width: 8, height: 8), cornerRadius: 2)
                        context.fill(path, with: .color(.white))
                        context.stroke(path, with: .color(.blue), lineWidth: 1.5)
                    }
                    if mark.kind == .focus, let end {
                        badge(context: &context, at: CGPoint(x: min(start.x, end.x), y: min(start.y, end.y)), number: numbers[mark.id] ?? (index + 1))
                    }
                }
            }
        }
    }

    private func pixels(_ a: UnitPoint2D?, _ b: UnitPoint2D?) -> Int {
        guard let a, let b else { return 0 }
        return Int(hypot((b.x - a.x) * Double(pixelSize.0), (b.y - a.y) * Double(pixelSize.1)).rounded())
    }
    private func point(_ value: UnitPoint2D, _ size: CGSize) -> CGPoint {
        CGPoint(x: value.x * size.width, y: value.y * size.height)
    }
    private func stroke(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, dashed: Bool = false) {
        var path = Path(); path.move(to: from); path.addLine(to: to)
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: dashed ? [4, 4] : []))
    }
    private func endpoint(_ context: inout GraphicsContext, at point: CGPoint) {
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(.blue))
    }
    private func badge(context: inout GraphicsContext, at point: CGPoint, number: Int) {
        let circle = Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        context.fill(circle, with: .color(.white))
        context.stroke(circle, with: .color(.blue), lineWidth: 1)
        context.draw(Text("\(number)").font(.system(size: 10, weight: .medium)).foregroundColor(.blue), at: point)
    }
    private func arrowHead(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(x: end.x - cos(angle - .pi / 6) * 8, y: end.y - sin(angle - .pi / 6) * 8)
        let right = CGPoint(x: end.x - cos(angle + .pi / 6) * 8, y: end.y - sin(angle + .pi / 6) * 8)
        stroke(&context, from: left, to: end, color: .blue); stroke(&context, from: end, to: right, color: .blue)
    }
    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private func measureLabel(_ context: inout GraphicsContext, start: CGPoint, end: CGPoint, mark: ReviewMark) {
        let pixelDX = (mark.end?.x ?? mark.start.x) - mark.start.x
        let pixelDY = (mark.end?.y ?? mark.start.y) - mark.start.y
        let dx = pixelDX * Double(pixelSize.0)
        let dy = pixelDY * Double(pixelSize.1)
        let label = Text("\(Int(hypot(dx, dy).rounded())) px").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.blue)
        let location = midpoint(start, end)
        let labelSize = context.resolve(label).measure(in: CGSize(width: 180, height: 30))
        let background = CGRect(x: location.x - labelSize.width / 2 - 7,
                                y: location.y - labelSize.height / 2 - 4,
                                width: labelSize.width + 14, height: labelSize.height + 8)
        context.fill(Path(roundedRect: background, cornerRadius: 5), with: .color(.white))
        context.stroke(Path(roundedRect: background, cornerRadius: 5), with: .color(.blue.opacity(0.25)), lineWidth: 0.5)
        context.draw(label, at: location)
    }
}

private func symbol(for kind: MarkKind) -> String {
    switch kind {
    case .point: "mappin.and.ellipse"
    case .arrow: "arrow.up.right"
    case .measure: "ruler"
    case .guideHorizontal: "line.3.horizontal"
    case .guideVertical: "line.3.horizontal"
    case .focus: "viewfinder"
    case .move: "arrow.up.forward.and.arrow.down.backward"
    case .compareGaps: "equal"
    }
}

private func imagePixelSize(_ image: NSImage) -> (Int, Int) {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (1, 1) }
    return (cgImage.width, cgImage.height)
}

private func instruction(for kind: MarkKind) -> String {
    switch kind {
    case .point: "Drag to select an area, or click to leave a comment."
    case .arrow: "Drag an arrow toward the detail you mean."
    case .measure: "Drag across a gap to see its size in screenshot pixels."
    case .guideHorizontal: "Click once to place a horizontal guide across the screen."
    case .guideVertical: "Click once to place a vertical guide across the screen."
    case .focus: "Drag a box around the area to focus on."
    case .move: "Drag from the current position to where the element should go."
    case .compareGaps: "Drag across gap A, then drag across gap B to compare them."
    }
}

private func measureDirection(_ mark: ReviewMark, imageSize: (Int, Int)) -> String {
    guard let end = mark.end else { return "" }
    let dx = abs(end.x - mark.start.x) * Double(imageSize.0)
    let dy = abs(end.y - mark.start.y) * Double(imageSize.1)
    if min(dx, dy) < max(dx, dy) * 0.2 { return dx > dy ? "horizontal gap" : "vertical gap" }
    return "diagonal"
}

private func timeLabel(_ seconds: Double) -> String {
    let wholeSeconds = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
}

private func preciseTime(_ seconds: Double) -> String {
    String(format: "%d:%06.3f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60))
}
