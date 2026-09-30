import AppKit
import AVKit
import FrameNoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store: ReviewStore
    @FocusState private var focusedMark: UUID?
    @State private var collapsed = false
    @State private var zoom: CGFloat = 1
    @State private var activeMark: UUID?
    @State private var selectingTime = false

    init(store: ReviewStore = ReviewStore()) {
        _store = StateObject(wrappedValue: store)
    }

    private var hasReviewContent: Bool { store.screenshot != nil || store.videoURL != nil }
    private var isReviewing: Bool { hasReviewContent && !store.isRecording && !collapsed }
    private var pixelSize: (Int, Int) {
        if let image = store.screenshot { return imagePixelSize(image) }
        return (Int(store.videoSize.width), Int(store.videoSize.height))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            if store.isRecording {
                recordingControls
            } else if isReviewing {
                reviewWorkspace
            } else if hasReviewContent {
                Button { collapsed = false } label: {
                    Label("Open review", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Your recording and comments are still here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                idleControls
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.1), lineWidth: 1))
        .preferredColorScheme(.light)
        .onChange(of: isReviewing, initial: true) { _, reviewing in
            NSApp.windows.compactMap { $0 as? FloatingPanel }.first?.setReviewMode(reviewing)
        }
        .onChange(of: store.videoURL) { _, _ in collapsed = false; zoom = 1; store.tool = .point }
        .onChange(of: store.screenshot) { _, _ in collapsed = false; zoom = 1; store.tool = .point }
    }

    private var header: some View {
        HStack(spacing: 12) {
            WindowDragHandle()
                .overlay(alignment: .leading) {
                    HStack(spacing: 7) {
                        Image(systemName: store.isRecording ? "record.circle.fill" : "viewfinder")
                            .foregroundStyle(store.isRecording ? Color.red : Color.accentColor)
                        Text("FrameNote").font(.headline)
                    }
                    .allowsHitTesting(false)
                }
                .help("Drag to move FrameNote")
            if hasReviewContent && !store.isRecording {
                Menu {
                    Button("Record new clip", systemImage: "record.circle") { store.toggleRecording() }
                    Button("Capture a window…", systemImage: "macwindow") { store.captureWindow() }
                    Button("Open screenshot or clip…", systemImage: "folder") { importMedia() }
                    Divider()
                    Button("Add before image…", systemImage: "rectangle.split.2x1") { store.importReference() }
                    if store.lastExport != nil {
                        Button("Show exported files", systemImage: "folder") { store.revealExport() }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("New capture and more actions")
            }
            if isReviewing {
                Button { store.export() } label: {
                    Label("Share feedback", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Button { collapsed = true } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").frame(width: 22, height: 24)
                }
                .buttonStyle(.plain).help("Collapse to small widget")
            }
            Button { (NSApp.delegate as? FrameNoteAppDelegate)?.hideWidget(nil) } label: {
                Image(systemName: "xmark").frame(width: 22, height: 24)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Hide widget — reopen from the menu bar")
        }
        .frame(height: 26)
    }

    private var idleControls: some View {
        VStack(spacing: 9) {
            Button { store.toggleRecording() } label: {
                Label("Record screen", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .disabled(store.isCapturing)
            HStack {
                Button("Capture", systemImage: "macwindow") { store.captureWindow() }
                    .disabled(store.isCapturing)
                Spacer()
                Button("Open", systemImage: "folder") { importMedia() }
            }
            .buttonStyle(.borderless).font(.callout)
            Text(store.status == "Choose a screenshot or capture a window to start."
                 ? "Always on top · drag the header to move" : store.status)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(store.isCapturing ? "Saving recording…" : "Recording")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Stop", systemImage: "stop.fill") { store.toggleRecording() }
                    .buttonStyle(.borderedProminent).tint(.red).disabled(store.isCapturing)
            }
            Text("FrameNote stays out of the recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var reviewWorkspace: some View {
        VStack(spacing: 10) {
            annotationTools
            Divider()
            ReviewCanvas(
                screenshot: store.screenshot, player: store.player,
                aspect: store.screenshot?.size ?? store.videoSize,
                marks: store.marks + (store.pendingGapPreview.map { [$0] } ?? []),
                tool: store.tool, currentTime: store.videoURL == nil ? nil : store.currentTime,
                pixelSize: pixelSize, zoom: zoom, activeMark: activeMark,
                onStart: store.pauseForAnnotation, onMark: addMark, onSelect: selectMark,
                reference: store.reference, compare: store.compare,
                comparisonFraction: store.comparisonFraction,
                editor: { mark in commentEditor(for: mark) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if store.player != nil { playbackControls }
            if store.compare, store.reference != nil {
                Slider(value: $store.comparisonFraction, in: 0...1)
            }
            HStack {
                Text(selectingTime ? "Drag across the timeline to select a moment." :
                     store.pendingGapPreview != nil ? "Gap A marked. Drag across gap B." : instruction(for: store.tool))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if store.lastExport != nil {
                    Button("Copy for agent") { store.copyForAgent() }.buttonStyle(.borderless)
                }
            }
            if store.status.contains("failed") || store.status.hasPrefix("Exported") {
                Text(store.status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var annotationTools: some View {
        HStack(spacing: 6) {
            toolButton(.point, title: "Comment")
            toolButton(.arrow, title: "Arrow")
            toolButton(.measure, title: "Measure")
            Menu {
                Button("Horizontal guide") { store.tool = .guideHorizontal }
                Button("Vertical guide") { store.tool = .guideVertical }
            } label: {
                Label("Guides", systemImage: "line.3.horizontal")
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(isGuide ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Menu {
                Button("Focus area") { store.tool = .focus }
                Button("Move here") { store.tool = .move }
                Button("Compare gaps") { store.tool = .compareGaps }
            } label: {
                Label(isExtraTool ? store.tool.rawValue : "More", systemImage: "ellipsis")
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(isExtraTool ? Color.accentColor.opacity(0.12) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer(minLength: 8)
            if !store.marks.isEmpty {
                Menu {
                    ForEach(Array(store.marks.enumerated()), id: \.element.id) { index, mark in
                        Button("\(index + 1). \(mark.note.isEmpty ? "Comment" : String(mark.note.prefix(45)))") {
                            selectMark(mark.id)
                        }
                    }
                } label: { Label("\(store.marks.count)", systemImage: "bubble.left") }
                .menuStyle(.borderlessButton).fixedSize().help("Reopen a comment")
            }
            if store.reference != nil {
                Button(store.compare ? "Done comparing" : "Compare") { store.compare.toggle() }
            }
            Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(zoom <= 1).help("Zoom out")
            Button("Fit") { zoom = 1 }.help("Fit the full image")
            Button { zoom = min(4, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(zoom >= 4).help("Zoom in; scroll to move around")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
    }

    private var isGuide: Bool { store.tool == .guideHorizontal || store.tool == .guideVertical }
    private var isExtraTool: Bool { [.focus, .move, .compareGaps].contains(store.tool) }

    private func toolButton(_ tool: MarkKind, title: String) -> some View {
        Button { store.tool = tool } label: {
            Label(title, systemImage: symbol(for: tool))
                .padding(.horizontal, 9).padding(.vertical, 7)
                .foregroundStyle(store.tool == tool ? Color.accentColor : .primary)
                .background(store.tool == tool ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).fixedSize()
    }

    private var playbackControls: some View {
        HStack(spacing: 10) {
            Button { activeMark = nil; focusedMark = nil; selectingTime = false; store.togglePlayback() } label: {
                Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).accessibilityLabel(store.isPlaying ? "Pause" : "Play")
            VideoTimeline(currentTime: store.currentTime, duration: store.duration,
                          selection: selectedRange, selecting: selectingTime,
                          marks: store.marks, onSeek: { time in
                store.pauseForAnnotation(); store.seek(to: time)
            }, onRange: setTimeRange)
                .frame(height: 30)
            Button {
                store.pauseForAnnotation()
                selectingTime.toggle()
            } label: {
                Label(selectingTime ? "Cancel" : "Select time", systemImage: "selection.pin.in.out")
            }
            .buttonStyle(.borderless).foregroundStyle(selectingTime ? Color.accentColor : .secondary)
            .disabled(store.duration <= 0)
            Text("\(timeLabel(store.currentTime)) / \(timeLabel(store.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button { store.toggleLoop() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(store.loopEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain).help("Loop 3 seconds around this moment")
            .disabled(store.duration <= 0)
        }
        .frame(height: 30)
    }

    private var selectedRange: ClosedRange<Double>? {
        guard let mark = store.marks.first(where: { $0.id == activeMark }),
              let start = mark.time, let end = mark.endTime else { return nil }
        return start...max(start, end)
    }

    @ViewBuilder private func commentEditor(for mark: ReviewMark) -> some View {
        let binding = Binding<ReviewMark>(get: {
            store.marks.first(where: { $0.id == mark.id }) ?? mark
        }, set: { updated in
            if let index = store.marks.firstIndex(where: { $0.id == mark.id }) { store.marks[index] = updated }
        })
        MarkEditor(mark: binding,
                   number: (store.marks.firstIndex { $0.id == mark.id } ?? 0) + 1,
                   focusedMark: $focusedMark,
                   onDelete: {
                       store.marks.removeAll { $0.id == mark.id }; activeMark = nil
                   }, onDone: { activeMark = nil; focusedMark = nil },
                   onTime: { selectingTime = true },
                   onRemoveTime: {
                       if let index = store.marks.firstIndex(where: { $0.id == mark.id }) {
                           store.marks[index].endTime = nil
                       }
                   })
    }

    private func selectMark(_ id: UUID) {
        guard let mark = store.marks.first(where: { $0.id == id }) else { return }
        store.pauseForAnnotation()
        if let time = mark.time { store.seek(to: time) }
        activeMark = id
        DispatchQueue.main.async { focusedMark = id }
    }

    private func setTimeRange(_ range: ClosedRange<Double>) {
        store.pauseForAnnotation()
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
        activeMark = mark.id
        DispatchQueue.main.async { focusedMark = mark.id }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            store.openVideo(at: url)
        } else {
            store.openImage(at: url)
        }
    }
}

private struct MarkEditor: View {
    @Binding var mark: ReviewMark
    let number: Int
    @FocusState.Binding var focusedMark: UUID?
    var onDelete: () -> Void
    var onDone: () -> Void
    var onTime: () -> Void
    var onRemoveTime: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Comment \(number)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete comment")
                Button("Done", action: onDone).buttonStyle(.borderless)
            }
            TextField("Write a comment…", text: $mark.note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.plain).font(.system(size: 13))
                .focused($focusedMark, equals: mark.id)
                .onExitCommand(perform: onDone)
            if let time = mark.time {
                HStack(spacing: 6) {
                    Button(action: onTime) {
                        Label(mark.endTime.map { "\(preciseTime(time)) – \(preciseTime($0))" }
                              ?? "\(preciseTime(time)) · Add time range", systemImage: "clock")
                            .font(.system(size: 11).monospacedDigit())
                    }.buttonStyle(.borderless)
                    if mark.endTime != nil {
                        Spacer(minLength: 0)
                        Button(action: onRemoveTime) { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).help("Use a single frame")
                    }
                }
            }
        }
        .padding(14).frame(width: 248)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
    }
}

private struct ReviewCanvas<Editor: View>: View {
    let screenshot: NSImage?
    let player: AVPlayer?
    let aspect: CGSize
    let marks: [ReviewMark]
    let tool: MarkKind
    let currentTime: Double?
    let pixelSize: (Int, Int)
    let zoom: CGFloat
    let activeMark: UUID?
    var onStart: () -> Void
    var onMark: (UnitPoint2D, UnitPoint2D?) -> Void
    var onSelect: (UUID) -> Void
    var reference: NSImage? = nil
    var compare = false
    var comparisonFraction = 0.5
    @ViewBuilder var editor: (ReviewMark) -> Editor
    @State private var draft: ReviewMark?

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(in: geometry.size)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    media(size: fitted)
                        .allowsHitTesting(false)
                    MarksOverlay(marks: visibleMarks + (draft.map { [$0] } ?? []), pixelSize: pixelSize, numbers: Dictionary(uniqueKeysWithValues: marks.enumerated().map { ($0.element.id, $0.offset + 1) }))
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                    if !compare {
                        AnnotationInputSurface(onStart: onStart, onChange: { start, end in
                            draft = ReviewMark(kind: tool == .point ? .focus : tool, start: start, end: endpoint(end),
                                               time: currentTime, note: "")
                        }, onFinish: { start, end in
                            draft = nil
                            if abs(start.x - end.x) * fitted.width < 5,
                               abs(start.y - end.y) * fitted.height < 5,
                               let existing = visibleMarks.last(where: { hit($0, at: start, size: fitted) }) {
                                onSelect(existing.id)
                            } else { onMark(start, endpoint(end)) }
                        })
                        .frame(width: fitted.width, height: fitted.height)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !compare, let mark = visibleMarks.first(where: { $0.id == activeMark }) {
                        editor(mark)
                            .offset(editorPosition(mark, size: fitted))
                    }
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
        ZStack(alignment: .leading) {
            if compare, let reference {
                Image(nsImage: reference).resizable().frame(width: size.width, height: size.height)
            }
            Group {
                if let player { PlayerSurface(player: player) }
                else if let screenshot { Image(nsImage: screenshot).resizable() }
            }
            .frame(width: size.width, height: size.height)
            .mask(alignment: .leading) {
                Rectangle().frame(width: size.width * (compare ? comparisonFraction : 1))
            }
            if compare {
                Rectangle().fill(.red).frame(width: 2, height: size.height)
                    .offset(x: size.width * comparisonFraction)
            }
        }
    }

    private var visibleMarks: [ReviewMark] { marks.filter { $0.isVisible(at: currentTime) } }

    private func hit(_ mark: ReviewMark, at point: UnitPoint2D, size: CGSize) -> Bool {
        let anchor = mark.kind == .focus ? UnitPoint2D(x: min(mark.start.x, mark.end?.x ?? mark.start.x),
                                                       y: min(mark.start.y, mark.end?.y ?? mark.start.y)) :
                     mark.kind == .move ? (mark.end ?? mark.start) : mark.start
        if hypot((point.x - anchor.x) * size.width, (point.y - anchor.y) * size.height) < 14 { return true }
        if mark.kind == .focus, let end = mark.end {
            return point.x >= min(mark.start.x, end.x) && point.x <= max(mark.start.x, end.x)
                && point.y >= min(mark.start.y, end.y) && point.y <= max(mark.start.y, end.y)
        }
        return false
    }

    private func editorPosition(_ mark: ReviewMark, size: CGSize) -> CGSize {
        let left = min(mark.start.x, mark.end?.x ?? mark.start.x) * size.width
        let right = max(mark.start.x, mark.end?.x ?? mark.start.x) * size.width
        let x = right + 290 < size.width ? right + 14 : left - 290
        let y = min(mark.start.y, mark.end?.y ?? mark.start.y) * size.height
        return CGSize(width: max(8, min(x, size.width - 284)), height: max(8, min(y, size.height - 190)))
    }

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

private struct MarksOverlay: View {
    let marks: [ReviewMark]
    let pixelSize: (Int, Int)
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
                        context.draw(Text("A").font(.system(size: 12, weight: .medium)).foregroundColor(.cyan), at: midpoint(start, end))
                    }
                    if let secondStart = mark.secondStart.map({ point($0, size) }),
                       let secondEnd = mark.secondEnd.map({ point($0, size) }) {
                        stroke(&context, from: secondStart, to: secondEnd, color: .purple)
                        endpoint(&context, at: secondStart); endpoint(&context, at: secondEnd)
                        context.draw(Text("B").font(.system(size: 12, weight: .medium)).foregroundColor(.purple), at: midpoint(secondStart, secondEnd))
                        badge(context: &context, at: start, number: numbers[mark.id] ?? (index + 1))
                    }
                }
            }
        }
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
    case .guideVertical: "line.3.vertical"
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
    String(format: "%d:%04.1f", Int(max(0, seconds)) / 60, max(0, seconds).truncatingRemainder(dividingBy: 60))
}
