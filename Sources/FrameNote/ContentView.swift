import AppKit
import AVKit
import FrameNoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = ReviewStore()
    @FocusState private var focusedMark: UUID?

    private var hasReviewContent: Bool { store.screenshot != nil || store.videoURL != nil }
    private var widgetHeight: CGFloat {
        if store.isRecording { return 154 }
        if store.videoURL != nil { return 570 }
        if store.screenshot != nil { return 540 }
        return 154
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if store.isRecording {
                recordingControls
            } else if let videoURL = store.videoURL, let player = store.player {
                videoReview(videoURL: videoURL, player: player)
            } else if let screenshot = store.screenshot {
                imageReview(screenshot)
            } else {
                idleControls
            }
        }
        .padding(13)
        .frame(width: 360, height: widgetHeight, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.08), lineWidth: 1))
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.18), value: widgetHeight)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: store.isRecording ? "record.circle.fill" : "viewfinder")
                .foregroundStyle(store.isRecording ? Color.red : Color.accentColor)
            Text("FrameNote").font(.headline)
            Spacer()
            if hasReviewContent && !store.isRecording {
                Menu {
                    Button("Record new clip", systemImage: "record.circle") { store.toggleRecording() }
                    Button("Capture a window…", systemImage: "macwindow") { store.captureWindow() }
                    Button("Open screenshot or clip…", systemImage: "folder") { importMedia() }
                    Button("Add before image…", systemImage: "rectangle.split.2x1") { store.importReference() }
                        .disabled(!hasReviewContent)
                    if store.lastExport != nil {
                        Divider()
                        Button("Copy for agent", systemImage: "document.on.document") { store.copyForAgent() }
                        Button("Show exported files", systemImage: "folder") { store.revealExport() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More actions")
            }
            Button { NSApp.keyWindow?.close() } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close FrameNote")
        }
        .frame(height: 22)
    }

    private var idleControls: some View {
        VStack(spacing: 9) {
            Button { store.toggleRecording() } label: {
                Label("Record screen", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(store.isCapturing)

            HStack(spacing: 0) {
                Button { store.captureWindow() } label: {
                    Label("Capture", systemImage: "macwindow")
                }
                .help("Capture one window")
                .disabled(store.isCapturing)
                Spacer()
                Button { importMedia() } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a screenshot or clip")
            }
            .buttonStyle(.borderless)
            .font(.callout)

            if store.status != "Choose a screenshot or capture a window to start." {
                Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Always on top · drag anywhere to move")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var recordingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Recording").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Stop", systemImage: "stop.fill") { store.toggleRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(store.isCapturing)
            }
            Text("Move this panel out of the way. It won’t appear in the recording.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 3)
    }

    private func videoReview(videoURL: URL, player: AVPlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReviewCanvas(
                screenshot: nil, player: player, aspect: store.videoSize,
                marks: canvasMarks, tool: store.tool, currentTime: store.currentTime,
                pixelSize: (Int(store.videoSize.width), Int(store.videoSize.height)),
                onMark: addMark, reference: store.reference,
                compare: store.compare, comparisonFraction: store.comparisonFraction
            )
            .frame(height: 184)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onChange(of: videoURL) { _, _ in store.seek(to: 0) }

            playbackControls(player)
            if store.compare, store.reference != nil {
                Slider(value: $store.comparisonFraction, in: 0...1)
            }
            annotationTools
            feedbackList(imageSize: (Int(store.videoSize.width), Int(store.videoSize.height)))
            shareControls
        }
    }

    private func imageReview(_ screenshot: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ReviewCanvas(
                screenshot: screenshot, player: nil, aspect: screenshot.size,
                marks: canvasMarks, tool: store.tool, currentTime: nil,
                pixelSize: imagePixelSize(screenshot), onMark: addMark,
                reference: store.reference, compare: store.compare,
                comparisonFraction: store.comparisonFraction
            )
            .frame(height: 205)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if store.compare, store.reference != nil {
                Slider(value: $store.comparisonFraction, in: 0...1)
            }
            annotationTools
            feedbackList(imageSize: imagePixelSize(screenshot))
            shareControls
        }
    }

    private func playbackControls(_ player: AVPlayer) -> some View {
        HStack(spacing: 8) {
            Button {
                if player.rate == 0 { player.play() } else { player.pause() }
            } label: {
                Image(systemName: player.rate == 0 ? "play.fill" : "pause.fill")
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.rate == 0 ? "Play" : "Pause")
            Slider(value: Binding(get: { store.currentTime }, set: { store.seek(to: $0) }),
                   in: 0...max(store.duration, 0.01))
                .disabled(store.duration <= 0)
            Text("\(timeLabel(store.currentTime)) / \(timeLabel(store.duration))")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Button { store.toggleLoop() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(store.loopEnabled ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Loop 3 seconds around this moment")
            .disabled(store.duration <= 0)
        }
        .frame(height: 24)
    }

    private var annotationTools: some View {
        HStack(spacing: 8) {
            Picker("Mark", selection: $store.tool) {
                ForEach(MarkKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: symbol(for: kind)).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            if store.reference != nil {
                Button(store.compare ? "Done" : "Compare") { store.compare.toggle() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomLeading) {
            Text(instruction(for: store.tool))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .offset(y: 14)
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func feedbackList(imageSize: (Int, Int)) -> some View {
        if store.marks.isEmpty {
            Text("Click the preview to leave a note.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 25)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach($store.marks) { $mark in
                        MarkEditor(mark: $mark, imageSize: imageSize,
                                   focusedMark: $focusedMark) {
                            store.marks.removeAll { $0.id == mark.id }
                        } onSelect: {
                            if let time = mark.time { store.seek(to: time) }
                        }
                    }
                }
            }
            .frame(maxHeight: 112)
        }
    }

    private var shareControls: some View {
        VStack(spacing: 5) {
            Button { store.export() } label: {
                Label("Share feedback", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            if store.lastExport != nil {
                Button("Copy for agent", systemImage: "document.on.document") { store.copyForAgent() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            } else if store.status != "Screenshot ready. Select a tool and mark the image." &&
                        store.status != "Clip ready. Play it, pause on an issue, then add a note." {
                Text(store.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var canvasMarks: [ReviewMark] {
        store.marks + (store.pendingGapPreview.map { [$0] } ?? [])
    }

    private func addMark(start: UnitPoint2D, end: UnitPoint2D?) {
        store.addMark(start: start, end: end)
        if let mark = store.marks.last { focusedMark = mark.id }
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
    let imageSize: (Int, Int)
    @FocusState.Binding var focusedMark: UUID?
    var onDelete: () -> Void
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                Image(systemName: symbol(for: mark.kind))
                    .foregroundStyle(.red)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            TextField("Add a comment…", text: $mark.note, axis: .vertical)
                .lineLimit(1...2)
                .textFieldStyle(.plain)
                .focused($focusedMark, equals: mark.id)
            if mark.kind == .measure, let pixels = mark.distanceInPixels(width: imageSize.0, height: imageSize.1) {
                Text("\(Int(pixels.rounded())) px").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button(role: .destructive, action: onDelete) { Image(systemName: "xmark") }
                .buttonStyle(.plain).font(.caption2).accessibilityLabel("Delete note")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReviewCanvas: View {
    let screenshot: NSImage?
    let player: AVPlayer?
    let aspect: CGSize
    let marks: [ReviewMark]
    let tool: MarkKind
    let currentTime: Double?
    let pixelSize: (Int, Int)
    var onMark: (UnitPoint2D, UnitPoint2D?) -> Void
    var reference: NSImage? = nil
    var compare = false
    var comparisonFraction = 0.5

    var body: some View {
        GeometryReader { geometry in
            let fitted = fittedSize(aspect: aspect, in: geometry.size)
            let origin = CGPoint(x: (geometry.size.width - fitted.width) / 2,
                                 y: (geometry.size.height - fitted.height) / 2)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ZStack(alignment: .topLeading) {
                    if let player {
                        if compare, let reference {
                            Image(nsImage: reference).resizable().frame(width: fitted.width, height: fitted.height)
                            PlayerSurface(player: player)
                                .mask(alignment: .leading) {
                                    Rectangle().frame(width: fitted.width * comparisonFraction)
                                }
                            Rectangle().fill(.red).frame(width: 2, height: fitted.height)
                                .offset(x: fitted.width * comparisonFraction)
                        } else {
                            PlayerSurface(player: player)
                        }
                    } else if let screenshot {
                        if compare, let reference {
                            Image(nsImage: reference).resizable().frame(width: fitted.width, height: fitted.height)
                            Image(nsImage: screenshot).resizable().frame(width: fitted.width, height: fitted.height)
                                .mask(alignment: .leading) { Rectangle().frame(width: fitted.width * comparisonFraction) }
                            Rectangle().fill(.red).frame(width: 2, height: fitted.height)
                                .offset(x: fitted.width * comparisonFraction)
                        } else {
                            Image(nsImage: screenshot).resizable().frame(width: fitted.width, height: fitted.height)
                        }
                    }
                    MarksOverlay(marks: visibleMarks, pixelSize: pixelSize)
                        .frame(width: fitted.width, height: fitted.height)
                        .allowsHitTesting(false)
                }
                .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(compare ? nil : DragGesture(minimumDistance: 0)
                    .onEnded { drag in
                        let start = UnitPoint2D(x: drag.startLocation.x / fitted.width,
                                                y: drag.startLocation.y / fitted.height)
                        let end = UnitPoint2D(x: drag.location.x / fitted.width,
                                              y: drag.location.y / fitted.height)
                        onMark(start, tool == .point || tool == .guideHorizontal || tool == .guideVertical ? nil : end)
                    })
                .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)
                .shadow(radius: 10, y: 2)
            }
        }
    }

    private var visibleMarks: [ReviewMark] {
        guard let currentTime else { return marks }
        return marks.filter { mark in
            guard let time = mark.time else { return true }
            return abs(time - currentTime) < 0.18
        }
    }

    private func fittedSize(aspect: CGSize, in available: CGSize) -> CGSize {
        let width = max(aspect.width, 1)
        let height = max(aspect.height, 1)
        let scale = min(max(available.width - 40, 1) / width, max(available.height - 40, 1) / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct MarksOverlay: View {
    let marks: [ReviewMark]
    let pixelSize: (Int, Int)

    var body: some View {
        Canvas { context, size in
            for (index, mark) in marks.enumerated() {
                let start = point(mark.start, size)
                let end = mark.end.map { point($0, size) }
                let red = Color.red
                switch mark.kind {
                case .point:
                    badge(context: &context, at: start, number: index + 1)
                case .guideHorizontal:
                    stroke(&context, from: CGPoint(x: 0, y: start.y), to: CGPoint(x: size.width, y: start.y), color: .orange, dashed: true)
                    context.draw(Text("H GUIDE").font(.system(size: 10, weight: .bold)).foregroundColor(.orange), at: CGPoint(x: 44, y: start.y - 9))
                case .guideVertical:
                    stroke(&context, from: CGPoint(x: start.x, y: 0), to: CGPoint(x: start.x, y: size.height), color: .orange, dashed: true)
                    context.draw(Text("V GUIDE").font(.system(size: 10, weight: .bold)).foregroundColor(.orange), at: CGPoint(x: start.x + 28, y: 10))
                case .focus:
                    if let end {
                        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                          width: abs(start.x - end.x), height: abs(start.y - end.y))
                        context.fill(Path(rect), with: .color(.yellow.opacity(0.12)))
                        context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.yellow), lineWidth: 2)
                        badge(context: &context, at: CGPoint(x: rect.minX, y: rect.minY), number: index + 1)
                    }
                case .move:
                    if let end {
                        stroke(&context, from: start, to: end, color: .green, dashed: true)
                        context.stroke(Path(ellipseIn: CGRect(x: start.x - 9, y: start.y - 9, width: 18, height: 18)), with: .color(.red), lineWidth: 2)
                        context.stroke(Path(ellipseIn: CGRect(x: end.x - 10, y: end.y - 10, width: 20, height: 20)), with: .color(.green), lineWidth: 3)
                        badge(context: &context, at: end, number: index + 1)
                    }
                case .arrow:
                    if let end {
                        stroke(&context, from: start, to: end, color: red)
                        arrowHead(&context, from: start, to: end)
                        badge(context: &context, at: start, number: index + 1)
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
                        context.draw(Text("A").font(.system(size: 12, weight: .bold)).foregroundColor(.cyan), at: midpoint(start, end))
                    }
                    if let secondStart = mark.secondStart.map({ point($0, size) }),
                       let secondEnd = mark.secondEnd.map({ point($0, size) }) {
                        stroke(&context, from: secondStart, to: secondEnd, color: .purple)
                        endpoint(&context, at: secondStart); endpoint(&context, at: secondEnd)
                        context.draw(Text("B").font(.system(size: 12, weight: .bold)).foregroundColor(.purple), at: midpoint(secondStart, secondEnd))
                        badge(context: &context, at: start, number: index + 1)
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
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [7, 5] : []))
    }
    private func endpoint(_ context: inout GraphicsContext, at point: CGPoint) {
        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(.red))
    }
    private func badge(context: inout GraphicsContext, at point: CGPoint, number: Int) {
        context.fill(Path(ellipseIn: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)), with: .color(.red))
        context.draw(Text("\(number)").font(.system(size: 12, weight: .bold)).foregroundColor(.white), at: point)
    }
    private func arrowHead(_ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(x: end.x - cos(angle - .pi / 6) * 12, y: end.y - sin(angle - .pi / 6) * 12)
        let right = CGPoint(x: end.x - cos(angle + .pi / 6) * 12, y: end.y - sin(angle + .pi / 6) * 12)
        stroke(&context, from: left, to: end, color: .red); stroke(&context, from: end, to: right, color: .red)
    }
    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    private func measureLabel(_ context: inout GraphicsContext, start: CGPoint, end: CGPoint, mark: ReviewMark) {
        let pixelDX = (mark.end?.x ?? mark.start.x) - mark.start.x
        let pixelDY = (mark.end?.y ?? mark.start.y) - mark.start.y
        let dx = pixelDX * Double(pixelSize.0)
        let dy = pixelDY * Double(pixelSize.1)
        let label = Text("\(Int(hypot(dx, dy).rounded())) px").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(.white)
        let location = midpoint(start, end)
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
    case .point: "Click an element to pin a note."
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
