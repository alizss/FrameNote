import AppKit
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
        screenshot: NSImage,
        reference: NSImage?,
        title: String,
        marks: [ReviewMark],
        into parent: URL
    ) throws -> URL {
        guard let source = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
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
            marks: marks
        )
        try pngData(for: source).write(to: folder.appendingPathComponent("screenshot.png"))
        try annotatedPNG(source: source, marks: marks).write(to: folder.appendingPathComponent("annotated.png"))
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
        let red = NSColor.systemRed
        let start = NSPoint(x: mark.start.x * CGFloat(width), y: (1 - mark.start.y) * CGFloat(height))
        if let endValue = mark.end {
            let end = NSPoint(x: endValue.x * CGFloat(width), y: (1 - endValue.y) * CGFloat(height))
            let line = NSBezierPath()
            line.lineWidth = 3 * scale
            line.move(to: start)
            line.line(to: end)
            red.setStroke()
            line.stroke()
            if mark.kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = NSBezierPath()
                head.lineWidth = 3 * scale
                head.move(to: end)
                head.line(to: NSPoint(x: end.x - cos(angle - .pi / 6) * 15 * scale,
                                      y: end.y - sin(angle - .pi / 6) * 15 * scale))
                head.move(to: end)
                head.line(to: NSPoint(x: end.x - cos(angle + .pi / 6) * 15 * scale,
                                      y: end.y - sin(angle + .pi / 6) * 15 * scale))
                head.stroke()
            } else if mark.kind == .measure {
                for point in [start, end] {
                    let cap = NSBezierPath(ovalIn: NSRect(x: point.x - 5 * scale, y: point.y - 5 * scale,
                                                         width: 10 * scale, height: 10 * scale))
                    red.setFill()
                    cap.fill()
                }
            }
        }
        let radius = 13 * scale
        let badge = NSBezierPath(ovalIn: NSRect(x: start.x - radius, y: start.y - radius,
                                              width: radius * 2, height: radius * 2))
        red.setFill()
        badge.fill()
        let numberText = "\(number)" as NSString
        let font = NSFont.boldSystemFont(ofSize: 13 * scale)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = numberText.size(withAttributes: attributes)
        numberText.draw(at: NSPoint(x: start.x - size.width / 2, y: start.y - size.height / 2), withAttributes: attributes)
    }
}
