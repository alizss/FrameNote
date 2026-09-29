import AppKit
import FrameNoteCore
import SwiftUI

struct ContentView: View {
    @StateObject private var store = ReviewStore()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                canvasHeader
                Divider()
                if let screenshot = store.screenshot {
                    ReviewCanvas(
                        screenshot: screenshot,
                        reference: store.reference,
                        marks: store.marks,
                        tool: store.tool,
                        compare: store.compare,
                        comparisonFraction: store.comparisonFraction,
                        onMark: store.addMark
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                HStack {
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if store.lastExport != nil {
                        Button("Show Export") { store.revealExport() }
                            .buttonStyle(.link)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            Divider()
            inspector
                .frame(width: 310)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Capture Window", systemImage: "camera.viewfinder") { store.captureWindow() }
                    .disabled(store.isCapturing)
                Button("Open Image", systemImage: "photo") { store.importScreenshot() }
                Button("Export Feedback", systemImage: "square.and.arrow.up") { store.export() }
                    .disabled(store.screenshot == nil)
            }
        }
    }

    private var canvasHeader: some View {
        HStack(spacing: 12) {
            Picker("Mark", selection: $store.tool) {
                ForEach(MarkKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            .disabled(store.compare)
            Spacer()
            if store.reference != nil {
                Toggle("Compare", isOn: $store.compare)
                    .toggleStyle(.switch)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Show the agent exactly what should change")
                .font(.title2.weight(.semibold))
            Text("Capture any Mac window, point to details, measure gaps, and collect feedback in one report.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Capture a Window") { store.captureWindow() }
                    .buttonStyle(.borderedProminent)
                Button("Open an Image") { store.importScreenshot() }
            }
        }
        .padding(28)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Feedback")
                .font(.title3.weight(.semibold))
            TextField("Title", text: $store.title)
                .textFieldStyle(.roundedBorder)

            if store.screenshot != nil {
                Text("Click to place a point. Drag to draw an arrow or measure a gap. Add a note for each mark.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if store.compare {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Before / after")
                        .font(.headline)
                    Slider(value: $store.comparisonFraction, in: 0...1)
                    HStack {
                        Text("Before")
                        Spacer()
                        Text("After")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            HStack {
                Text("Notes (\(store.marks.count))")
                    .font(.headline)
                Spacer()
                if !store.marks.isEmpty {
                    Button("Clear") { store.marks = [] }
                        .buttonStyle(.link)
                }
            }
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach($store.marks) { $mark in
                        MarkEditor(mark: $mark) {
                            store.marks.removeAll { $0.id == mark.id }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Spacer(minLength: 0)
            Divider()
            Button("Add Before Image…") { store.importReference() }
                .disabled(store.screenshot == nil)
            Button("Export Feedback…") { store.export() }
                .buttonStyle(.borderedProminent)
                .disabled(store.screenshot == nil)
        }
        .padding(16)
    }
}

private struct MarkEditor: View {
    @Binding var mark: ReviewMark
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: mark.kind == .point ? "mappin" : mark.kind == .arrow ? "arrow.up.right" : "ruler")
                    .foregroundStyle(.red)
                Text(mark.kind.rawValue)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(mark.kind.rawValue) mark")
            }
            TextField("What should change here?", text: $mark.note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ReviewCanvas: View {
    let screenshot: NSImage
    let reference: NSImage?
    let marks: [ReviewMark]
    let tool: MarkKind
    let compare: Bool
    let comparisonFraction: Double
    let onMark: (UnitPoint2D, UnitPoint2D?) -> Void

    var body: some View {
        GeometryReader { geometry in
            let imageSize = imageSize(in: geometry.size)
            let imageFrame = CGRect(
                x: (geometry.size.width - imageSize.width) / 2,
                y: (geometry.size.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ZStack(alignment: .topLeading) {
                    if compare, let reference {
                        Image(nsImage: reference)
                            .resizable()
                            .frame(width: imageSize.width, height: imageSize.height)
                        Image(nsImage: screenshot)
                            .resizable()
                            .frame(width: imageSize.width, height: imageSize.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: imageSize.width * comparisonFraction)
                            }
                        Rectangle()
                            .fill(.red)
                            .frame(width: 2, height: imageSize.height)
                            .offset(x: imageSize.width * comparisonFraction)
                    } else {
                        Image(nsImage: screenshot)
                            .resizable()
                            .frame(width: imageSize.width, height: imageSize.height)
                        MarksOverlay(marks: marks)
                            .frame(width: imageSize.width, height: imageSize.height)
                    }
                }
                .frame(width: imageSize.width, height: imageSize.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(compare ? nil : DragGesture(minimumDistance: 0)
                    .onEnded { drag in
                        let start = UnitPoint2D(
                            x: drag.startLocation.x / imageSize.width,
                            y: drag.startLocation.y / imageSize.height
                        )
                        let end = UnitPoint2D(
                            x: drag.location.x / imageSize.width,
                            y: drag.location.y / imageSize.height
                        )
                        onMark(start, tool == .point ? nil : end)
                    })
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .shadow(radius: 10, y: 2)
            }
        }
    }

    private func imageSize(in available: CGSize) -> CGSize {
        let width = max(screenshot.size.width, 1)
        let height = max(screenshot.size.height, 1)
        let scale = min(max(available.width - 40, 1) / width, max(available.height - 40, 1) / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}

private struct MarksOverlay: View {
    let marks: [ReviewMark]

    var body: some View {
        Canvas { context, size in
            for (index, mark) in marks.enumerated() {
                let start = CGPoint(x: mark.start.x * size.width, y: mark.start.y * size.height)
                if let endValue = mark.end {
                    let end = CGPoint(x: endValue.x * size.width, y: endValue.y * size.height)
                    var line = Path()
                    line.move(to: start)
                    line.addLine(to: end)
                    context.stroke(line, with: .color(.red), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    if mark.kind == .arrow {
                        let angle = atan2(end.y - start.y, end.x - start.x)
                        var head = Path()
                        head.move(to: end)
                        head.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * 12,
                                                 y: end.y - sin(angle - .pi / 6) * 12))
                        head.move(to: end)
                        head.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * 12,
                                                 y: end.y - sin(angle + .pi / 6) * 12))
                        context.stroke(head, with: .color(.red), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    } else if mark.kind == .measure {
                        for point in [start, end] {
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                                         with: .color(.red))
                        }
                    }
                }
                context.fill(Path(ellipseIn: CGRect(x: start.x - 12, y: start.y - 12, width: 24, height: 24)),
                             with: .color(.red))
                context.draw(
                    Text("\(index + 1)").font(.system(size: 12, weight: .bold)).foregroundColor(.white),
                    at: start,
                    anchor: .center
                )
            }
        }
        .allowsHitTesting(false)
    }
}
