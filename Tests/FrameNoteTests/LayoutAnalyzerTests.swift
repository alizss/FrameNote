import AppKit
import XCTest
@testable import FrameNoteCore

final class LayoutAnalyzerTests: XCTestCase {
    /// Draws a small UI with known flaws so the engine can be checked against ground truth.
    private struct Chip {
        var rect: CGRect          // top-left origin
        var label: String
        var textOffset = CGPoint.zero
        var textColor = NSColor(white: 0.1, alpha: 1)
    }

    private func render(size: CGSize, background: NSColor = NSColor(white: 0.91, alpha: 1), chips: [Chip],
                        extra: ((CGSize) -> Void)? = nil) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        for chip in chips {
            let flipped = NSRect(x: chip.rect.minX, y: size.height - chip.rect.maxY, width: chip.rect.width, height: chip.rect.height)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: flipped, xRadius: flipped.height / 2, yRadius: flipped.height / 2).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: chip.textColor]
            let text = NSAttributedString(string: chip.label, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: flipped.midX - textSize.width / 2 + chip.textOffset.x,
                                  y: flipped.midY - textSize.height / 2 - chip.textOffset.y))
        }
        extra?(size)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }

    private func summary(_ analysis: LayoutAnalysis) -> String {
        analysis.findings.map { "[\($0.category.rawValue) \($0.severity)] \($0.note)" }.joined(separator: "\n")
    }

    func testFindsElementsAndSharedEdges() {
        let chips = [Chip(rect: CGRect(x: 40, y: 60, width: 90, height: 36), label: "Image"),
                     Chip(rect: CGRect(x: 142, y: 60, width: 60, height: 36), label: "4K"),
                     Chip(rect: CGRect(x: 214, y: 60, width: 70, height: 36), label: "16:9")]
        let analysis = LayoutAnalyzer.analyze(render(size: CGSize(width: 400, height: 160), chips: chips))
        let containers = analysis.elements.filter { $0.kind == .container }
        XCTAssertEqual(containers.count, 3, "Each pill should be found as a surface that holds its label.")
        for container in containers {
            XCTAssertEqual(container.rect.height * 160, 36, accuracy: 3)
            XCTAssertTrue(analysis.elements.contains { $0.parent == container.id && $0.kind == .content },
                          "Each surface should contain its text.")
        }
        XCTAssertTrue(analysis.guides.contains { $0.axis == .horizontal && abs($0.position * 160 - 60) < 3 },
                      "The shared top edge of the row should become a guide line.")
        XCTAssertTrue(analysis.findings.isEmpty, "A clean row must not produce findings:\n\(summary(analysis))")
    }

    func testFlagsUnevenGapsBetweenChips() throws {
        // Gaps: 12, 12, 21.
        let chips = [Chip(rect: CGRect(x: 40, y: 60, width: 80, height: 36), label: "Image"),
                     Chip(rect: CGRect(x: 132, y: 60, width: 80, height: 36), label: "Video"),
                     Chip(rect: CGRect(x: 224, y: 60, width: 80, height: 36), label: "Audio"),
                     Chip(rect: CGRect(x: 325, y: 60, width: 80, height: 36), label: "Files")]
        let analysis = LayoutAnalyzer.analyze(render(size: CGSize(width: 460, height: 160), chips: chips))
        let finding = try XCTUnwrap(analysis.findings.first { $0.category == .spacing }, summary(analysis))
        XCTAssertTrue(finding.note.contains("12 px"), finding.note)
        XCTAssertTrue(finding.note.contains("21 px"), finding.note)
        let a = try XCTUnwrap(finding.gapA), b = try XCTUnwrap(finding.gapB)
        XCTAssertEqual((a.to.x - a.from.x) * 460, 12, accuracy: 2)
        XCTAssertEqual((b.to.x - b.from.x) * 460, 21, accuracy: 2)
    }

    func testFlagsLabelThatSitsTooHighInsideItsChip() throws {
        let chips = [Chip(rect: CGRect(x: 40, y: 50, width: 110, height: 44), label: "Download", textOffset: CGPoint(x: 0, y: 9))]
        let analysis = LayoutAnalyzer.analyze(render(size: CGSize(width: 240, height: 140), chips: chips))
        let finding = try XCTUnwrap(analysis.findings.first { $0.category == .padding }, summary(analysis))
        XCTAssertTrue(finding.note.contains("of space"), finding.note)
        XCTAssertGreaterThanOrEqual(finding.severity, 2)
    }

    func testFlagsLowContrastText() throws {
        let chips = [Chip(rect: CGRect(x: 40, y: 50, width: 120, height: 40), label: "Secondary",
                          textColor: NSColor(white: 0.78, alpha: 1))]
        let analysis = LayoutAnalyzer.analyze(render(size: CGSize(width: 240, height: 140), chips: chips))
        let finding = try XCTUnwrap(analysis.findings.first { $0.category == .contrast }, summary(analysis))
        XCTAssertTrue(finding.note.contains(":1"), finding.note)
    }

    func testRegionAnalysisReportsCoordinatesInTheFullImage() throws {
        let chips = [Chip(rect: CGRect(x: 40, y: 20, width: 80, height: 36), label: "Top"),
                     Chip(rect: CGRect(x: 40, y: 220, width: 110, height: 44), label: "Bottom", textOffset: CGPoint(x: 0, y: 9))]
        let image = render(size: CGSize(width: 300, height: 300), chips: chips)
        let lower = LayoutAnalyzer.analyze(image, region: CGRect(x: 0, y: 0.6, width: 1, height: 0.4))
        let finding = try XCTUnwrap(lower.findings.first { $0.category == .padding }, summary(lower))
        XCTAssertGreaterThan(finding.rect.minY, 0.6, "Finding coordinates belong to the full image, not the crop.")
        XCTAssertEqual(finding.rect.midY * 300, 242, accuracy: 6)
        XCTAssertFalse(lower.elements.contains { $0.rect.maxY < 0.55 }, "Nothing above the region should be analysed.")
    }

    func testBusyPhotoDoesNotHangOrFlood() {
        let size = CGSize(width: 600, height: 400)
        let image = render(size: size, chips: []) { size in
            for _ in 0..<5000 {
                NSColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
                NSRect(x: .random(in: 0..<size.width), y: .random(in: 0..<size.height), width: 3, height: 3).fill()
            }
        }
        let started = Date()
        let analysis = LayoutAnalyzer.analyze(image)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertLessThanOrEqual(analysis.findings.count, 12)
    }

    func testAutoMarksCarryTheMeasuredNote() throws {
        let chips = [Chip(rect: CGRect(x: 40, y: 50, width: 110, height: 44), label: "Download", textOffset: CGPoint(x: 0, y: 9))]
        let analysis = LayoutAnalyzer.analyze(render(size: CGSize(width: 240, height: 140), chips: chips))
        let finding = try XCTUnwrap(analysis.findings.first)
        let mark = ReviewMark(finding: finding, time: nil)
        XCTAssertEqual(mark.kind, .focus)
        XCTAssertEqual(mark.auto, true)
        XCTAssertTrue(mark.note.hasPrefix(finding.note))
        XCTAssertNotNil(mark.end)
    }
}
