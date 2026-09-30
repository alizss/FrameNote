import AppKit
import AVFoundation
import Foundation

enum ExportError: LocalizedError {
    case unreadableImage
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "The screenshot could not be decoded."
        case .imageEncodingFailed: "The annotated image could not be saved."
        }
    }
}

@MainActor
public enum ReviewExporter {
    public static func export(
        screenshot: NSImage?,
        reference: NSImage?,
        title: String,
        marks: [ReviewMark],
        videoURL: URL? = nil,
        loopStart: Double? = nil,
        loopEnd: Double? = nil,
        into parent: URL
    ) throws -> URL {
        guard screenshot != nil || videoURL != nil else {
            throw ExportError.unreadableImage
        }
        let screenshotImage = screenshot?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        let videoGenerator = videoURL.map { AVAssetImageGenerator(asset: AVURLAsset(url: $0)) }
        videoGenerator?.appliesPreferredTrackTransform = true
        guard let source = screenshotImage ?? videoGenerator.flatMap({ try? $0.copyCGImage(at: .zero, actualTime: nil) }) else {
            throw ExportError.unreadableImage
        }
        let referenceImage = reference?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if reference != nil && referenceImage == nil {
            throw ExportError.unreadableImage
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let folder = parent.appendingPathComponent("FrameNote-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let manifest = ReviewManifest(
            createdAt: Date(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "UI feedback" : title,
            imageWidth: source.width,
            imageHeight: source.height,
            referenceImageFile: referenceImage == nil ? nil : "reference.png",
            videoFile: videoURL?.lastPathComponent,
            loopStart: loopStart,
            loopEnd: loopEnd,
            marks: marks
        )
        try pngData(for: source).write(to: folder.appendingPathComponent("screenshot.png"))
        let stillMarks = videoURL == nil ? marks : []
        try annotatedPNG(source: source, marks: stillMarks).write(to: folder.appendingPathComponent("annotated.png"))
        if videoURL == nil {
            for (index, mark) in marks.enumerated() where mark.kind == .focus {
                try focusPNG(source: source, mark: mark).write(
                    to: folder.appendingPathComponent(String(format: "focus-%02d.png", index + 1))
                )
            }
        }
        if let videoURL {
            let destination = folder.appendingPathComponent(videoURL.lastPathComponent)
            try FileManager.default.copyItem(at: videoURL, to: destination)
            guard let videoGenerator else { throw ExportError.unreadableImage }
            for (index, mark) in marks.enumerated() {
                guard let time = mark.time,
                      let frame = try? videoGenerator.copyCGImage(
                        at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil
                      ) else { continue }
                let stem = String(format: "moment-%02d", index + 1)
                try pngData(for: frame).write(to: folder.appendingPathComponent("\(stem).png"))
                try annotatedPNG(source: frame, marks: [mark]).write(
                    to: folder.appendingPathComponent("\(stem)-marked.png")
                )
                if mark.kind == .focus {
                    try focusPNG(source: frame, mark: mark).write(
                        to: folder.appendingPathComponent("\(stem)-focus.png")
                    )
                }
            }
        }
        if let referenceImage {
            try pngData(for: referenceImage).write(to: folder.appendingPathComponent("reference.png"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("feedback.json"))
        try ReviewMarkdown.generate(manifest).write(
            to: folder.appendingPathComponent("feedback.md"),
            atomically: true,
            encoding: .utf8
        )
        return folder
    }

    private static func pngData(for image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ExportError.imageEncodingFailed
        }
        return data
    }

    private static func focusPNG(source: CGImage, mark: ReviewMark) throws -> Data {
        guard let end = mark.end else { throw ExportError.unreadableImage }
        let x = Int((min(mark.start.x, end.x) * Double(source.width)).rounded(.down))
        let y = Int((min(mark.start.y, end.y) * Double(source.height)).rounded(.down))
        let width = max(1, Int((abs(mark.start.x - end.x) * Double(source.width)).rounded()))
        let height = max(1, Int((abs(mark.start.y - end.y) * Double(source.height)).rounded()))
        let bounds = CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !bounds.isNull, let cropped = source.cropping(to: bounds) else { throw ExportError.unreadableImage }
        return try pngData(for: cropped)
    }

    private static func annotatedPNG(source: CGImage, marks: [ReviewMark]) throws -> Data {
        let width = source.width
        let height = source.height
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw ExportError.imageEncodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSImage(cgImage: source, size: NSSize(width: width, height: height))
            .draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        let scale = max(1, min(CGFloat(width), CGFloat(height)) / 1000)
        for (index, mark) in marks.enumerated() {
            draw(mark, number: index + 1, width: width, height: height, scale: scale)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.imageEncodingFailed
        }
        return data
    }

    private static func draw(_ mark: ReviewMark, number: Int, width: Int, height: Int, scale: CGFloat) {
        let start = NSPoint(x: mark.start.x * CGFloat(width), y: (1 - mark.start.y) * CGFloat(height))
        let end = mark.end.map { NSPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) }
        let red = NSColor.systemRed
        switch mark.kind {
        case .point:
            badge(at: start, number: number, scale: scale, color: red)
        case .guideHorizontal:
            line(from: NSPoint(x: 0, y: start.y), to: NSPoint(x: CGFloat(width), y: start.y),
                 color: .systemOrange, scale: scale, dashed: true)
            drawLabel("H GUIDE", at: NSPoint(x: 44 * scale, y: start.y + 10 * scale), scale: scale, color: .systemOrange)
        case .guideVertical:
            line(from: NSPoint(x: start.x, y: 0), to: NSPoint(x: start.x, y: CGFloat(height)),
                 color: .systemOrange, scale: scale, dashed: true)
            drawLabel("V GUIDE", at: NSPoint(x: start.x + 35 * scale, y: CGFloat(height) - 15 * scale), scale: scale, color: .systemOrange)
        case .focus:
            if let end {
                let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                  width: abs(start.x - end.x), height: abs(start.y - end.y))
                NSColor.systemYellow.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6 * scale, yRadius: 6 * scale).fill()
                lineRect(rect, color: .systemYellow, scale: scale)
                badge(at: NSPoint(x: rect.minX, y: rect.maxY), number: number, scale: scale, color: red)
            }
        case .move:
            if let end {
                line(from: start, to: end, color: .systemGreen, scale: scale, dashed: true)
                ring(at: start, radius: 9 * scale, color: red, scale: scale)
                ring(at: end, radius: 10 * scale, color: .systemGreen, scale: scale)
                badge(at: end, number: number, scale: scale, color: .systemGreen)
                drawLabel("CURRENT", at: NSPoint(x: start.x, y: start.y + 18 * scale), scale: scale, color: red)
                drawLabel("NEW", at: NSPoint(x: end.x, y: end.y + 18 * scale), scale: scale, color: .systemGreen)
            }
        case .arrow:
            if let end {
                line(from: start, to: end, color: red, scale: scale)
                let angle = atan2(end.y - start.y, end.x - start.x)
                line(from: end, to: NSPoint(x: end.x - cos(angle - .pi / 6) * 15 * scale,
                                            y: end.y - sin(angle - .pi / 6) * 15 * scale), color: red, scale: scale)
                line(from: end, to: NSPoint(x: end.x - cos(angle + .pi / 6) * 15 * scale,
                                            y: end.y - sin(angle + .pi / 6) * 15 * scale), color: red, scale: scale)
                badge(at: start, number: number, scale: scale, color: red)
            }
        case .measure:
            if let end {
                line(from: start, to: end, color: red, scale: scale)
                ring(at: start, radius: 5 * scale, color: red, scale: scale, filled: true)
                ring(at: end, radius: 5 * scale, color: red, scale: scale, filled: true)
                let dx = abs((mark.end?.x ?? mark.start.x) - mark.start.x) * Double(width)
                let dy = abs((mark.end?.y ?? mark.start.y) - mark.start.y) * Double(height)
                let amount = Int(hypot(dx, dy).rounded())
                drawLabel("\(amount) px", at: NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 12 * scale), scale: scale, color: red)
            }
        case .compareGaps:
            if let end {
                line(from: start, to: end, color: .systemCyan, scale: scale)
                drawLabel("A", at: NSPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + 8 * scale), scale: scale, color: .systemCyan)
            }
            if let second = mark.secondStart, let secondEnd = mark.secondEnd {
                let a = NSPoint(x: second.x * CGFloat(width), y: (1 - second.y) * CGFloat(height))
                let b = NSPoint(x: secondEnd.x * CGFloat(width), y: (1 - secondEnd.y) * CGFloat(height))
                line(from: a, to: b, color: .systemPurple, scale: scale)
                drawLabel("B", at: NSPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 8 * scale), scale: scale, color: .systemPurple)
                badge(at: start, number: number, scale: scale, color: red)
            }
        }
    }

    private static func line(from start: NSPoint, to end: NSPoint, color: NSColor, scale: CGFloat, dashed: Bool = false) {
        let path = NSBezierPath()
        path.lineWidth = 3 * scale
        path.lineCapStyle = .round
        if dashed { var pattern: [CGFloat] = [7 * scale, 5 * scale]; path.setLineDash(&pattern, count: pattern.count, phase: 0) }
        path.move(to: start); path.line(to: end)
        color.setStroke(); path.stroke()
    }

    private static func ring(at point: NSPoint, radius: CGFloat, color: NSColor, scale: CGFloat, filled: Bool = false) {
        let path = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = 3 * scale
        if filled { color.setFill(); path.fill() } else { color.setStroke(); path.stroke() }
    }

    private static func lineRect(_ rect: NSRect, color: NSColor, scale: CGFloat) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 6 * scale, yRadius: 6 * scale)
        path.lineWidth = 3 * scale; color.setStroke(); path.stroke()
    }

    private static func badge(at point: NSPoint, number: Int, scale: CGFloat, color: NSColor) {
        let radius = 13 * scale
        let badge = NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius,
                                              width: radius * 2, height: radius * 2))
        color.setFill(); badge.fill()
        let numberText = "\(number)" as NSString
        let font = NSFont.boldSystemFont(ofSize: 13 * scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = numberText.size(withAttributes: attributes)
        numberText.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
    }

    private static func drawLabel(_ value: String, at point: NSPoint, scale: CGFloat, color: NSColor) {
        let string = value as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12 * scale),
            .foregroundColor: color,
            .strokeColor: NSColor.black,
            .strokeWidth: -2 * scale,
        ]
        let size = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
    }
}
