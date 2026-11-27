import CoreGraphics
import Foundation

/// Finds UI elements in a screenshot from pixels alone, then reviews their spacing like a UI/UX designer would.
///
/// The detector has three stages:
/// 1. Edge map: a pixel is an edge when its colour changes sharply from a neighbour.
/// 2. Components: connected edge pixels become boxes. A box that frames other boxes (a button, chip or card)
///    becomes a *container*; loose boxes are merged into text lines and icon groups.
/// 3. Review (`LayoutRules`): padding, gaps, alignment, size consistency and text contrast are measured.
///
/// Nothing leaves the device and no model is involved, so results are repeatable and measured in real pixels.
public enum LayoutAnalyzer {
    public struct Options: Sendable {
        /// Smallest colour change (0–255) that counts as an edge. Video frames need a higher value because of compression noise.
        public var edgeThreshold: Int
        /// The longer side is scaled down to this before analysis.
        public var maxDimension: Int
        public var maxFindings: Int

        public init(edgeThreshold: Int = 6, maxDimension: Int = 3200, maxFindings: Int = 12) {
            self.edgeThreshold = edgeThreshold
            self.maxDimension = maxDimension
            self.maxFindings = maxFindings
        }

        public static let still = Options()
        public static let videoFrame = Options(edgeThreshold: 10)
    }

    /// - Parameter region: Normalized area of `image` to examine; nil examines the whole image.
    public static func analyze(_ image: CGImage, region: CGRect? = nil, options: Options = .still) -> LayoutAnalysis {
        let source = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var crop = source
        if let region {
            crop = CGRect(x: region.minX * source.width, y: region.minY * source.height,
                          width: region.width * source.width, height: region.height * source.height)
                .integral.intersection(source)
        }
        guard crop.width >= 12, crop.height >= 12, let cropped = image.cropping(to: crop),
              let bitmap = LayoutBitmap(cropped, maxDimension: options.maxDimension) else { return .empty }

        var detection = LayoutDetector.detect(bitmap, threshold: options.edgeThreshold)
        if detection.tooBusy {
            // A photo or heavy gradient: raise the bar so only strong structure remains.
            detection = LayoutDetector.detect(bitmap, threshold: options.edgeThreshold * 3)
        }

        // Everything the rules need, in source pixels relative to the crop.
        let inverse = 1 / bitmap.scale
        let elements = detection.elements.map { element -> RuleElement in
            let rect = element.rect
            return RuleElement(index: element.index, kind: element.kind,
                               rect: CGRect(x: rect.minX * inverse, y: rect.minY * inverse,
                                            width: rect.width * inverse, height: rect.height * inverse),
                               parent: element.parent, textLike: element.textLike)
        }
        let unit = min(3, max(1, Double(max(crop.width, crop.height)) / 1100))
        var raw = LayoutRules.review(elements, unit: unit)
        raw += LayoutRules.contrast(elements, bitmap: bitmap, unit: unit)
        raw = LayoutRules.prioritized(raw, limit: options.maxFindings)

        func normalized(_ rect: CGRect) -> CGRect {
            CGRect(x: (crop.minX + rect.minX) / source.width, y: (crop.minY + rect.minY) / source.height,
                   width: rect.width / source.width, height: rect.height / source.height)
        }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (crop.minX + point.x) / source.width, y: (crop.minY + point.y) / source.height)
        }
        func normalized(_ segment: LayoutSegment?) -> LayoutSegment? {
            segment.map { LayoutSegment(from: normalized($0.from), to: normalized($0.to)) }
        }

        let findings = raw.map { item in
            LayoutFinding(category: item.category, severity: item.severity, title: item.title, note: item.note,
                          rect: normalized(item.rect), gapA: normalized(item.gapA), gapB: normalized(item.gapB))
        }
        let layoutElements = elements.map {
            LayoutElement(id: $0.index, kind: $0.kind == .container ? .container : .content,
                          rect: normalized($0.rect), parent: $0.parent)
        }
        let guides = LayoutRules.guides(elements, unit: unit).map { guide -> LayoutGuide in
            let position = guide.axis == .vertical ? (crop.minX + guide.position) / source.width
                                                   : (crop.minY + guide.position) / source.height
            return LayoutGuide(axis: guide.axis, position: position, count: guide.count)
        }
        return LayoutAnalysis(elements: layoutElements, guides: guides, findings: findings,
                              region: normalized(CGRect(origin: .zero, size: crop.size)),
                              truncated: detection.tooBusy)
    }
}

// MARK: - Internal types shared with the rules

struct RuleElement {
    enum Kind { case container, content }
    var index: Int
    var kind: Kind
    /// Source pixels, relative to the analyzed crop.
    var rect: CGRect
    var parent: Int?
    var textLike: Bool
}

struct RawFinding {
    var category: LayoutFinding.Category
    var severity: Int
    var title: String
    var note: String
    var rect: CGRect
    var gapA: LayoutSegment?
    var gapB: LayoutSegment?
}

struct RawGuide {
    var axis: LayoutGuide.Axis
    var position: Double
    var count: Int
}

// MARK: - Pixels

struct LayoutBitmap {
    let width: Int
    let height: Int
    /// RGBA, 8 bits per channel.
    let pixels: [UInt8]
    /// Working pixels per source pixel (≤ 1).
    let scale: Double

    init?(_ image: CGImage, maxDimension: Int) {
        let longest = max(image.width, image.height)
        let scale = min(1, Double(maxDimension) / Double(longest))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width; self.height = height; self.pixels = pixels; self.scale = scale
    }
}

// MARK: - Detection

struct IRect {
    var x0, y0, x1, y1: Int   // x1 / y1 are exclusive
    var w: Int { x1 - x0 }
    var h: Int { y1 - y0 }
    var area: Int { w * h }

    func strictlyContains(_ other: IRect) -> Bool {
        other.x0 > x0 && other.y0 > y0 && other.x1 < x1 && other.y1 < y1
    }
    var cgRect: CGRect { CGRect(x: x0, y: y0, width: w, height: h) }
}

struct DetectedElement {
    var index: Int
    var kind: RuleElement.Kind
    var rect: CGRect          // working pixels
    var parent: Int?
    var textLike: Bool
}

struct Detection {
    var elements: [DetectedElement]
    var tooBusy: Bool
}

enum LayoutDetector {
    private static let maxComponents = 6000

    static func detect(_ bitmap: LayoutBitmap, threshold: Int) -> Detection {
        let w = bitmap.width, h = bitmap.height
        let mask = edgeMask(bitmap, threshold: threshold)
        let (labels, raw) = components(mask: mask, width: w, height: h)
        guard raw.count <= maxComponents else { return Detection(elements: [], tooBusy: true) }

        // Each box is trimmed by the 1px halo the edge map adds on the outside of a shape.
        let rects: [IRect] = raw.map { box in
            func trim(_ lo: Int, _ hi: Int) -> (Int, Int) {
                let size = hi - lo + 1
                if size > 2 { return (lo + 1, hi) }
                let mid = (lo + hi + 1) / 2
                return (mid, mid + 1)
            }
            let (x0, x1) = trim(box.minX, box.maxX)
            let (y0, y1) = trim(box.minY, box.maxY)
            return IRect(x0: x0, y0: y0, x1: x1, y1: y1)
        }

        // Containers: boxes whose outline frames other boxes.
        var isContainer = [Bool](repeating: false, count: raw.count)
        for i in raw.indices {
            let r = rects[i]
            guard r.w >= 12, r.h >= 12, raw[i].count >= 24 else { continue }
            let side = coverage(of: raw[i], label: Int32(i + 1), labels: labels, width: w)
            let opposite = (side.top >= 0.45 && side.bottom >= 0.45) || (side.left >= 0.45 && side.right >= 0.45)
            let strong = [side.top, side.bottom, side.left, side.right].filter { $0 >= 0.6 }.count >= 3
            guard opposite || strong else { continue }
            var count = 0, ux0 = Int.max, uy0 = Int.max, ux1 = Int.min, uy1 = Int.min
            for j in raw.indices where j != i && r.strictlyContains(rects[j]) {
                count += 1
                ux0 = min(ux0, rects[j].x0); uy0 = min(uy0, rects[j].y0)
                ux1 = max(ux1, rects[j].x1); uy1 = max(uy1, rects[j].y1)
            }
            guard count > 0 else { continue }
            let textLikeContent = Double(ux1 - ux0) >= 1.2 * Double(uy1 - uy0)
            if opposite && (count >= 3 || textLikeContent) { isContainer[i] = true }
            else if strong && min(r.w, r.h) >= 20 { isContainer[i] = true }
        }

        let containers = raw.indices.filter { isContainer[$0] }.sorted { rects[$0].area < rects[$1].area }
        func enclosing(_ j: Int) -> Int? {
            containers.first { $0 != j && rects[$0].strictlyContains(rects[j]) }
        }

        // Loose boxes are merged into text lines and icon groups, separately inside each container.
        var groups: [Int: [Int]] = [-1: []]
        for j in raw.indices where !isContainer[j] {
            groups[enclosing(j) ?? -1, default: []].append(j)
        }

        var elements: [DetectedElement] = []
        var elementOfComponent: [Int: Int] = [:]
        for c in containers {
            elementOfComponent[c] = elements.count
            elements.append(DetectedElement(index: elements.count, kind: .container, rect: rects[c].cgRect,
                                            parent: nil, textLike: false))
        }
        for c in containers {
            if let parent = enclosing(c), let parentElement = elementOfComponent[parent], let own = elementOfComponent[c] {
                elements[own].parent = parentElement
            }
        }
        for (container, members) in groups.sorted(by: { $0.key < $1.key }) {
            let parent = container < 0 ? nil : elementOfComponent[container]
            for block in merge(members.map { rects[$0] }) where max(block.w, block.h) >= 3 {
                elements.append(DetectedElement(index: elements.count, kind: .content, rect: block.cgRect, parent: parent,
                                                textLike: Double(block.w) >= 1.4 * Double(block.h)))
            }
        }
        return Detection(elements: elements, tooBusy: false)
    }

    // MARK: Edge map

    private static func edgeMask(_ bitmap: LayoutBitmap, threshold: Int) -> [Bool] {
        let w = bitmap.width, h = bitmap.height
        var mask = [Bool](repeating: false, count: w * h)
        bitmap.pixels.withUnsafeBufferPointer { px in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x, p = i * 4
                    if x + 1 < w {
                        let q = p + 4
                        let d = max(abs(Int(px[p]) - Int(px[q])), abs(Int(px[p + 1]) - Int(px[q + 1])), abs(Int(px[p + 2]) - Int(px[q + 2])))
                        if d > threshold { mask[i] = true; mask[i + 1] = true }
                    }
                    if y + 1 < h {
                        let q = p + w * 4
                        let d = max(abs(Int(px[p]) - Int(px[q])), abs(Int(px[p + 1]) - Int(px[q + 1])), abs(Int(px[p + 2]) - Int(px[q + 2])))
                        if d > threshold { mask[i] = true; mask[i + w] = true }
                    }
                }
            }
        }
        return mask
    }

    // MARK: Connected components

    struct RawBox { var minX, minY, maxX, maxY, count: Int }

    private struct UnionFind {
        var parent: [Int32] = [0]
        mutating func make() -> Int32 { parent.append(Int32(parent.count)); return Int32(parent.count - 1) }
        mutating func find(_ value: Int32) -> Int32 {
            var root = value
            while parent[Int(root)] != root { root = parent[Int(root)] }
            var current = value
            while parent[Int(current)] != root { let next = parent[Int(current)]; parent[Int(current)] = root; current = next }
            return root
        }
        mutating func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb } }
        }
    }

    /// 8-connected labelling. Labels in the returned array are 1-based component numbers (0 = background).
    private static func components(mask: [Bool], width w: Int, height h: Int) -> ([Int32], [RawBox]) {
        var labels = [Int32](repeating: 0, count: w * h)
        var uf = UnionFind()
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard mask[i] else { continue }
                var first: Int32 = 0
                func join(_ other: Int32) {
                    guard other != 0 else { return }
                    if first == 0 { first = other } else if other != first { uf.union(first, other) }
                }
                if x > 0 { join(labels[i - 1]) }
                if y > 0 {
                    if x > 0 { join(labels[i - w - 1]) }
                    join(labels[i - w])
                    if x + 1 < w { join(labels[i - w + 1]) }
                }
                labels[i] = first == 0 ? uf.make() : first
            }
        }
        var compact = [Int32](repeating: 0, count: uf.parent.count)
        var boxes: [RawBox] = []
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard labels[i] != 0 else { continue }
                let root = uf.find(labels[i])
                if compact[Int(root)] == 0 {
                    boxes.append(RawBox(minX: x, minY: y, maxX: x, maxY: y, count: 0))
                    compact[Int(root)] = Int32(boxes.count)
                }
                let id = Int(compact[Int(root)]) - 1
                labels[i] = Int32(id + 1)
                boxes[id].minX = min(boxes[id].minX, x); boxes[id].maxX = max(boxes[id].maxX, x)
                boxes[id].minY = min(boxes[id].minY, y); boxes[id].maxY = max(boxes[id].maxY, y)
                boxes[id].count += 1
            }
        }
        // Drop specks that are probably noise, but keep indices stable by leaving them as 1px boxes.
        return (labels, boxes)
    }

    /// How much of each side of the box's outline is drawn by the component itself.
    private static func coverage(of box: RawBox, label: Int32, labels: [Int32], width w: Int)
        -> (top: Double, bottom: Double, left: Double, right: Double) {
        let bw = box.maxX - box.minX + 1, bh = box.maxY - box.minY + 1
        func horizontal(_ y: Int) -> Int {
            var hits = 0
            for x in box.minX...box.maxX where labels[y * w + x] == label || (y + 1 <= box.maxY && labels[(y + 1) * w + x] == label) { hits += 1 }
            return hits
        }
        func horizontalBottom(_ y: Int) -> Int {
            var hits = 0
            for x in box.minX...box.maxX where labels[y * w + x] == label || (y - 1 >= box.minY && labels[(y - 1) * w + x] == label) { hits += 1 }
            return hits
        }
        func vertical(_ x: Int) -> Int {
            var hits = 0
            for y in box.minY...box.maxY where labels[y * w + x] == label || (x + 1 <= box.maxX && labels[y * w + x + 1] == label) { hits += 1 }
            return hits
        }
        func verticalRight(_ x: Int) -> Int {
            var hits = 0
            for y in box.minY...box.maxY where labels[y * w + x] == label || (x - 1 >= box.minX && labels[y * w + x - 1] == label) { hits += 1 }
            return hits
        }
        return (Double(horizontal(box.minY)) / Double(bw), Double(horizontalBottom(box.maxY)) / Double(bw),
                Double(vertical(box.minX)) / Double(bh), Double(verticalRight(box.maxX)) / Double(bh))
    }

    // MARK: Text lines and icon groups

    /// Merges neighbouring boxes that read as one unit: letters into words and lines, dots onto stems, icons onto labels.
    private static func merge(_ rects: [IRect]) -> [IRect] {
        guard !rects.isEmpty else { return [] }
        var parent = Array(rects.indices)
        func find(_ i: Int) -> Int {
            var r = i
            while parent[r] != r { r = parent[r] }
            var c = i
            while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
            return r
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[rb] = ra } }

        let order = rects.indices.sorted { rects[$0].x0 < rects[$1].x0 }
        let reach = max(8, rects.map { Int(Double($0.h) * 0.9) }.max() ?? 8)
        for (n, i) in order.enumerated() {
            let a = rects[i]
            for k in (n + 1)..<max(n + 1, order.count) {
                let j = order[k]
                let b = rects[j]
                if b.x0 > a.x1 + reach { break }
                if shouldMerge(a, b) { union(i, j) }
            }
        }
        var merged: [Int: IRect] = [:]
        for i in rects.indices {
            let root = find(i)
            if var existing = merged[root] {
                existing.x0 = min(existing.x0, rects[i].x0); existing.y0 = min(existing.y0, rects[i].y0)
                existing.x1 = max(existing.x1, rects[i].x1); existing.y1 = max(existing.y1, rects[i].y1)
                merged[root] = existing
            } else { merged[root] = rects[i] }
        }
        return merged.values.sorted { ($0.y0, $0.x0) < ($1.y0, $1.x0) }
    }

    private static func shouldMerge(_ a: IRect, _ b: IRect) -> Bool {
        let gapX = max(0, max(a.x0, b.x0) - min(a.x1, b.x1))
        let gapY = max(0, max(a.y0, b.y0) - min(a.y1, b.y1))
        if gapX == 0 && gapY == 0 { return true }
        let minH = min(a.h, b.h), maxH = max(a.h, b.h)
        let overlapY = min(a.y1, b.y1) - max(a.y0, b.y0)
        let overlapX = min(a.x1, b.x1) - max(a.x0, b.x0)
        // Same line: close enough that the gap is a letter or word space.
        if Double(overlapY) >= 0.4 * Double(minH), Double(gapX) <= max(2, 0.9 * Double(minH)) { return true }
        // A small mark right above or below a larger one (i-dot, accent, underline).
        if Double(minH) <= 0.5 * Double(maxH), Double(overlapX) >= 0.5 * Double(min(a.w, b.w)),
           Double(gapY) <= max(2, 0.25 * Double(maxH)) { return true }
        return false
    }
}
