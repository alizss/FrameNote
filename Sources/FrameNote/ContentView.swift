import AppKit
import AVKit
import FrameNoteCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var store = ReviewStore()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if hasReviewContent {
                    HStack(spacing: 10) {
                        Picker("Tool", selection: $store.tool) {
                            ForEach(MarkKind.allCases) { kind in
                                Label(kind.rawValue, systemImage: symbol(for: kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 190)
                        Spacer()
                        if store.isRecording {
                            Label("Recording", systemImage: "record.circle.fill")
                                .foregroundStyle(.red)
                                .font(.callout.weight(.semibold))
                        } else if store.reference != nil {
                            Toggle("Compare before / after", isOn: $store.compare)
                                .toggleStyle(.switch)
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    Divider()
                }

                if let videoURL = store.videoURL, let player = store.player {
                    ReviewCanvas(
                        screenshot: nil, player: player, aspect: store.videoSize,
                        marks: canvasMarks, tool: store.tool, currentTime: store.currentTime,
                        pixelSize: (Int(store.videoSize.width), Int(store.videoSize.height)),
                        onMark: store.addMark
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    timeline
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .onChange(of: videoURL) { _, _ in store.seek(to: 0) }
                } else if let screenshot = store.screenshot {
                    ReviewCanvas(
                        screenshot: screenshot, player: nil, aspect: screenshot.size,
                        marks: canvasMarks, tool: store.tool, currentTime: nil,
                        pixelSize: imagePixelSize(screenshot), onMark: store.addMark,
                        reference: store.reference, compare: store.compare,
                        comparisonFraction: store.comparisonFraction
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.isRecording {
                    recordingState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if hasReviewContent {
                    Divider()
                    HStack(spacing: 10) {
                        Text(store.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        if store.lastExport != nil {
                            Button("Copy for agent", systemImage: "document.on.document") { store.copyForAgent() }
                            Button("Show files") { store.revealExport() }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                } else if store.status != "Choose a screenshot or capture a window to start." && !store.isRecording {
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 10)
                }
            }
            if hasReviewContent {
                Divider()
                inspector.frame(width: 320)
            }
        }
        .frame(minWidth: hasReviewContent ? 900 : 600, minHeight: hasReviewContent ? 620 : 460)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if hasReviewContent {
                    Button("Record", systemImage: "record.circle") { store.toggleRecording() }
                        .disabled(store.isCapturing)
                    Menu("Open", systemImage: "plus") {
                        Button("Capture a window…", systemImage: "camera.viewfinder") { store.captureWindow() }
                        Button("Open an image…", systemImage: "photo") { store.importScreenshot() }
                        Button("Open a recording…", systemImage: "film") { store.importVideo() }
                    }
                    Button("Share review", systemImage: "square.and.arrow.up") { store.export() }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var hasReviewContent: Bool {
        store.screenshot != nil || store.videoURL != nil
    }

    private var timeline: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button {
                    if store.player?.rate == 0 { store.player?.play() } else { store.player?.pause() }
                } label: {
                    Image(systemName: store.player?.rate == 0 ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(store.player?.rate == 0 ? "Play" : "Pause")
                Slider(value: Binding(get: { store.currentTime }, set: { store.seek(to: $0) }),
                       in: 0...max(store.duration, 0.01))
                    .disabled(store.duration <= 0)
                Text("\(timeLabel(store.currentTime)) / \(timeLabel(store.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 112, alignment: .trailing)
                Button {
                    store.toggleLoop()
                } label: {
                    Label(store.loopEnabled ? "Loop on" : "Loop 3s", systemImage: "repeat")
                }
                .buttonStyle(.bordered)
                .tint(store.loopEnabled ? .accentColor : .secondary)
                .disabled(store.duration <= 0)
                .help("Repeat the three seconds around the playhead")
            }
            if !store.marks.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(store.marks.enumerated()), id: \.element.id) { index, mark in
                        if let time = mark.time {
                            Button("\(index + 1) · \(timeLabel(time))") { store.seek(to: time) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    Spacer()
                }
                .lineLimit(1)
            }
            if store.loopEnabled {
                Text("Repeats \(timeLabel(store.loopStart))–\(timeLabel(store.loopEnd))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tint)
            Text("Record a UI issue")
                .font(.system(size: 26, weight: .semibold))
            Text("Pause where it feels wrong. Add a pin, guide, or measurement.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Record screen", systemImage: "record.circle") { store.toggleRecording() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.isCapturing)
                .padding(.top, 3)
            HStack(spacing: 18) {
                Button("Capture one window") { store.captureWindow() }
                    .disabled(store.isCapturing)
                Text("or").foregroundStyle(.tertiary)
                Button("Open screenshot or clip…") { importMedia() }
            }
            .buttonStyle(.link)
            .font(.callout)
            Text("Nothing is uploaded unless you share it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(24)
    }

    private var recordingState: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.red)
            Text("Recording screen")
                .font(.title2.weight(.semibold))
            Text("Switch to the app you’re reviewing. Return here when you’re ready to stop.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Button("Stop recording", systemImage: "stop.fill") { store.toggleRecording() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(store.isCapturing)
        }
        .padding(24)
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

    private var canvasMarks: [ReviewMark] {
        store.marks + (store.pendingGapPreview.map { [$0] } ?? [])
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review").font(.title3.weight(.semibold))
            TextField("What are we reviewing?", text: $store.title).textFieldStyle(.roundedBorder)
            if store.videoURL != nil {
                Text("\(instruction(for: store.tool)) Note at \(timeLabel(store.currentTime)).")
                    .font(.callout).foregroundStyle(.secondary)
            } else if store.screenshot != nil {
                Text(instruction(for: store.tool))
                    .font(.callout).foregroundStyle(.secondary)
            }
            if store.compare, store.reference != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Before / after").font(.headline)
                    Slider(value: $store.comparisonFraction, in: 0...1)
                    HStack { Text("Before"); Spacer(); Text("After") }
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
            }
            HStack {
                Text("Notes (\(store.marks.count))").font(.headline)
                Spacer()
                if store.screenshot != nil || store.videoURL != nil {
                    Button("Before image…") { store.importReference() }
                }
                if !store.marks.isEmpty {
                    Button("Clear") { store.marks = [] }
                }
            }
            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach($store.marks) { $mark in
                        MarkEditor(mark: $mark, imageSize: store.screenshot.map(imagePixelSize) ??
                            (Int(store.videoSize.width), Int(store.videoSize.height))) {
                            store.marks.removeAll { $0.id == mark.id }
                        } onSelect: {
                            if let time = mark.time { store.seek(to: time) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Button("Share review…", systemImage: "square.and.arrow.up") { store.export() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .disabled(store.screenshot == nil && store.videoURL == nil)
        }
        .padding(16)
    }
}

private struct MarkEditor: View {
    @Binding var mark: ReviewMark
    let imageSize: (Int, Int)
    var onDelete: () -> Void
    var onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Button(action: onSelect) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: mark.kind)).foregroundStyle(.red)
                        Text(mark.kind.rawValue).font(.subheadline.weight(.medium))
                        if let time = mark.time { Text("· \(timeLabel(time))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).accessibilityLabel("Delete note")
            }
            if mark.kind == .measure, let pixels = mark.distanceInPixels(width: imageSize.0, height: imageSize.1) {
                Text("\(Int(pixels.rounded())) px \(measureDirection(mark, imageSize: imageSize))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else if mark.kind == .compareGaps,
                      let a = mark.distanceInPixels(width: imageSize.0, height: imageSize.1),
                      let b = mark.secondDistanceInPixels(width: imageSize.0, height: imageSize.1) {
                Text("A: \(Int(a.rounded())) px  ·  B: \(Int(b.rounded())) px  ·  Difference: \(Int(abs(a - b).rounded())) px")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            TextField("Add a short note…", text: $mark.note, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
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
