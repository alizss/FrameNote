import CoreGraphics
import Foundation

/// The design review. Every rule works in source pixels and only reports what it measured.
enum LayoutRules {
    // MARK: Entry points

    static func review(_ elements: [RuleElement], unit u: Double) -> [RawFinding] {
        var findings: [RawFinding] = []
        let parents = Set(elements.map(\.parent))
        for parent in parents {
            let siblings = elements.filter { $0.parent == parent }
            guard siblings.count >= 2, siblings.count <= 150 else { continue }
            let rows = clusters(siblings, rowsOf: true)
            let columns = clusters(siblings, rowsOf: false)
            // Judge neighbours only: items far apart on a line belong to different parts of the layout.
            for row in rows.flatMap({ runs($0, vertical: false) }) where row.count >= 2 {
                findings += centreAlignment(row, unit: u)
                findings += heightConsistency(row, unit: u)
                findings += paddingConsistency(row, in: elements, unit: u)
                if row.count >= 3 { findings += gapRhythm(row, vertical: false, unit: u) }
            }
            for column in columns {
                for run in runs(column, vertical: true) where run.count >= 3 { findings += gapRhythm(run, vertical: true, unit: u) }
                for run in runs(column, vertical: true) where run.count >= 4 { findings += edgeAlignment(run, unit: u) }
            }
        }
        for container in elements where container.kind == .container {
            findings += padding(of: container, children: elements.filter { $0.parent == container.index }, unit: u)
        }
        return findings
    }

    /// Most serious first, capped, and never two notes about the same spot.
    static func prioritized(_ findings: [RawFinding], limit: Int) -> [RawFinding] {
        let weight: [LayoutFinding.Category: Int] = [.padding: 4, .spacing: 4, .alignment: 3, .sizing: 2, .contrast: 1]
        let sorted = findings.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if weight[$0.category] != weight[$1.category] { return (weight[$0.category] ?? 0) > (weight[$1.category] ?? 0) }
            return ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX)
        }
        var kept: [RawFinding] = []
        for finding in sorted where kept.count < limit {
            let duplicate = kept.contains { other in
                other.category == finding.category && overlap(other.rect, finding.rect) > 0.6
            }
            if !duplicate { kept.append(finding) }
        }
        // Read top-to-bottom so the numbers on the screenshot follow the page.
        return kept.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    // MARK: Padding inside surfaces

    private static func padding(of container: RuleElement, children: [RuleElement], unit u: Double) -> [RawFinding] {
        // Components (chips, buttons, fields) hold a few things. A toolbar or card with many children is layout, not padding.
        guard !children.isEmpty, children.count <= 3, container.rect.height >= 6 * u, container.rect.height <= 220 * u else { return [] }
        let content = children.map(\.rect).reduce(children[0].rect) { $0.union($1) }
        let box = container.rect
        let top = content.minY - box.minY, bottom = box.maxY - content.maxY
        let left = content.minX - box.minX, right = box.maxX - content.maxX
        guard top >= 0, bottom >= 0, left >= 0, right >= 0 else { return [] }
        // Content that touches the outline is usually the outline and the content fusing in the edge map, not a design choice to report.
        guard min(top, bottom, left, right) >= 2 * u else { return [] }

        var problems: [String] = []
        var severity = 1
        let contentHeight = content.height
        // Letters with descenders (g, y, p) and ascenders make the ink box lower or higher than the optical centre,
        // so a designer centres text on its line, not on its ink. Allow for that before calling padding uneven.
        let hasText = children.contains { $0.textLike }
        let verticalTolerance = max(1.5 * u, 0.2 * max(top, bottom), hasText ? 0.3 * contentHeight : 0)
        let horizontalTolerance = max(3 * u, 0.4 * max(left, right))

        if abs(top - bottom) > verticalTolerance {
            let (small, large, side) = top < bottom ? (top, bottom, "above") : (bottom, top, "below")
            problems.append("\(px(small)) of space \(side) the content but \(px(large)) on the opposite side")
            severity = max(severity, large >= 3 * max(small, u) ? 3 : 2)
        }
        // A wide surface with content pushed to one side is flexible layout (a field, a list row), not a padding slip.
        let compactHorizontally = max(left, right) <= 2 * contentHeight + 6 * u
        if abs(left - right) > horizontalTolerance && compactHorizontally {
            let (small, large, side) = left < right ? (left, right, "left") : (right, left, "right")
            problems.append("\(px(small)) on the \(side) but \(px(large)) on the other side")
            severity = max(severity, large >= 3 * max(small, u) ? 3 : 2)
        }
        let tightVertical = min(top, bottom) < min(0.2 * contentHeight, 6 * u)
        let tightHorizontal = min(left, right) < min(0.3 * contentHeight, 8 * u) && container.rect.width > content.width
        if tightVertical && !problems.contains(where: { $0.contains("above") || $0.contains("below") }) {
            problems.append("only \(px(min(top, bottom))) of vertical padding, so the content looks cramped against the edge")
            severity = max(severity, min(top, bottom) < u ? 3 : 2)
        }
        if tightHorizontal && !problems.contains(where: { $0.contains("left") || $0.contains("right") }) {
            problems.append("only \(px(min(left, right))) of side padding, so the content crowds the edge")
            severity = max(severity, min(left, right) < u ? 3 : 2)
        }
        guard !problems.isEmpty else { return [] }

        let target = (top + bottom) / 2
        let sideTarget = (left + right) / 2
        var fix = "Give the content equal padding on every side of this surface"
        if abs(top - bottom) > verticalTolerance || tightVertical { fix += " (about \(px(max(target, min(contentHeight * 0.5, 12 * u)))) top and bottom" }
        else { fix += " (" }
        if abs(left - right) > horizontalTolerance || tightHorizontal {
            fix += (fix.hasSuffix("(") ? "" : ", ") + "about \(px(sideTarget)) left and right"
        }
        fix += ") so it sits visually centred."
        let title = "Uneven padding"
        return [RawFinding(category: .padding, severity: severity, title: title,
                           note: "\(title): this surface has \(problems.joined(separator: "; ")). \(fix) Measured padding: top \(px(top)), bottom \(px(bottom)), left \(px(left)), right \(px(right)).",
                           rect: box.insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil)]
    }

    /// Sibling chips or buttons that should share the same side padding.
    private static func paddingConsistency(_ row: [RuleElement], in all: [RuleElement], unit u: Double) -> [RawFinding] {
        let containers = row.filter { $0.kind == .container }.sorted { $0.rect.minX < $1.rect.minX }
        guard containers.count >= 2 else { return [] }
        struct Measured { var element: RuleElement; var left: Double; var right: Double }
        let measured: [Measured] = containers.compactMap { container in
            let children = all.filter { $0.parent == container.index }
            guard let first = children.first else { return nil }
            let content = children.map(\.rect).reduce(first.rect) { $0.union($1) }
            return Measured(element: container, left: content.minX - container.rect.minX, right: container.rect.maxX - content.maxX)
        }
        guard measured.count >= 2 else { return [] }
        // Only compare surfaces of about the same height; those are the ones that read as a set.
        let heights = measured.map { $0.element.rect.height }
        guard let tallest = heights.max(), let shortest = heights.min(), tallest - shortest <= max(2 * u, 0.12 * tallest) else { return [] }
        let lefts = measured.map(\.left)
        guard let maxLeft = lefts.max(), let minLeft = lefts.min(), maxLeft - minLeft > max(2 * u, 0.2 * maxLeft) else { return [] }
        guard let odd = measured.max(by: { abs($0.left - median(lefts)) < abs($1.left - median(lefts)) }) else { return [] }
        let usual = median(lefts)
        return [RawFinding(category: .padding, severity: 2, title: "Inconsistent side padding",
                           note: "Inconsistent side padding: these controls look like a set, but this one has \(px(odd.left)) of padding on its left edge while its neighbours use about \(px(usual)). Use one horizontal padding value for all of them.",
                           rect: odd.element.rect.insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil)]
    }

    // MARK: Gaps

    private static func gapRhythm(_ items: [RuleElement], vertical: Bool, unit u: Double) -> [RawFinding] {
        let sorted = items.sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        // Only items of a similar size read as a set (chips, list rows, icons). Unrelated page regions have no shared rhythm.
        let sizes = sorted.map { $0.rect.height }
        guard let tallest = sizes.max(), let shortest = sizes.min(), shortest > 0, tallest <= 1.8 * shortest else { return [] }
        var gaps: [Double] = []
        for pair in zip(sorted, sorted.dropFirst()) {
            gaps.append(vertical ? pair.1.rect.minY - pair.0.rect.maxY : pair.1.rect.minX - pair.0.rect.maxX)
        }
        // Overlapping neighbours mean the cluster is not a simple row or stack; do not guess.
        guard gaps.count >= 2, gaps.allSatisfy({ $0 >= -0.5 * u }) else { return [] }
        let gapValues = gaps.map { max(0, $0) }

        func tolerance(_ v: Double) -> Double { max(1.5 * u, 0.08 * v) }
        func agreeing(with v: Double) -> [Int] { gapValues.indices.filter { abs(gapValues[$0] - v) <= tolerance(v) } }
        let best = gapValues.map { agreeing(with: $0) }.max { $0.count < $1.count } ?? []

        var usual = 0.0
        var deviantIndex: Int?
        var cramped = false
        // The modal gap must describe at least half of the gaps; otherwise the group is not a regular rhythm.
        if best.count >= 2 && best.count < gapValues.count && best.count * 2 >= gapValues.count {
            usual = best.map { gapValues[$0] }.reduce(0, +) / Double(best.count)
            let others = gapValues.indices.filter { !best.contains($0) }
            for index in others.sorted(by: { abs(gapValues[$0] - usual) > abs(gapValues[$1] - usual) }) {
                let d = gapValues[index]
                // A gap much larger than the rest reads as a deliberate group break, not a mistake.
                if d > usual, d <= 1.8 * max(usual, u) { deviantIndex = index; break }
                if d < usual, d < 0.75 * usual { deviantIndex = index; cramped = d < 0.4 * usual; break }
            }
        } else if best.count == 1, let low = gapValues.min(), let high = gapValues.max(),
                  high - low > max(2 * u, 0.15 * high), high <= 1.5 * max(low, u) {
            // No two gaps agree: report the spread between the tightest and the loosest.
            usual = low
            deviantIndex = gapValues.firstIndex(of: high)
        }
        guard let index = deviantIndex else { return [] }
        let deviant = gapValues[index]
        let reference = gapValues.indices.first { abs(gapValues[$0] - usual) <= tolerance(usual) && $0 != index } ?? (index == 0 ? 1 : 0)
        let relative = abs(deviant - usual) / max(usual, u)
        let severity = cramped ? 3 : (relative >= 0.4 ? 3 : 2)
        let axis = vertical ? "vertical" : "horizontal"
        let order = vertical ? "top to bottom" : "left to right"
        let nearby = max(0, index - 2)...min(gapValues.count - 1, index + 2)
        let list = (nearby.lowerBound > 0 ? "…, " : "") + gapValues[nearby].map { px($0) }.joined(separator: ", ")
            + (nearby.upperBound < gapValues.count - 1 ? ", …" : "")
        let a = sorted[index], b = sorted[index + 1]
        let note: String
        if cramped {
            note = "Cramped spacing: items \(index + 1) and \(index + 2) (counting \(order)) are only \(px(deviant)) apart while the rest of this group uses about \(px(usual)). They read as touching. Increase this gap to \(px(usual)). Gaps measured \(order): \(list)."
        } else {
            note = "Uneven \(axis) spacing: gaps measured \(order) are \(list). The gap after item \(index + 1) is \(px(deviant)) where the others use \(px(usual)). Use one spacing value (\(px(usual))) between these items; if the larger gap is a deliberate group break, make it at least twice as large so it reads as intentional."
        }
        return [RawFinding(category: .spacing, severity: severity, title: cramped ? "Cramped spacing" : "Uneven spacing", note: note,
                           rect: a.rect.union(b.rect).insetBy(dx: -2 * u, dy: -2 * u),
                           gapA: gapSegment(sorted[reference], sorted[reference + 1], vertical: vertical),
                           gapB: gapSegment(a, b, vertical: vertical))]
    }

    private static func gapSegment(_ a: RuleElement, _ b: RuleElement, vertical: Bool) -> LayoutSegment {
        if vertical {
            let lo = max(a.rect.minX, b.rect.minX), hi = min(a.rect.maxX, b.rect.maxX)
            let x = hi > lo ? (lo + hi) / 2 : (a.rect.midX + b.rect.midX) / 2
            return LayoutSegment(from: CGPoint(x: x, y: a.rect.maxY), to: CGPoint(x: x, y: max(a.rect.maxY, b.rect.minY)))
        }
        let lo = max(a.rect.minY, b.rect.minY), hi = min(a.rect.maxY, b.rect.maxY)
        let y = hi > lo ? (lo + hi) / 2 : (a.rect.midY + b.rect.midY) / 2
        return LayoutSegment(from: CGPoint(x: a.rect.maxX, y: y), to: CGPoint(x: max(a.rect.maxX, b.rect.minX), y: y))
    }

    // MARK: Alignment

    private static func edgeAlignment(_ column: [RuleElement], unit u: Double) -> [RawFinding] {
        guard column.count >= 3 else { return [] }
        var findings: [RawFinding] = []
        for useLeft in [true, false] {
            let edge: (RuleElement) -> Double = { useLeft ? $0.rect.minX : $0.rect.maxX }
            let values = column.map(edge)
            let agreeing: (Double) -> [Int] = { v in column.indices.filter { abs(values[$0] - v) <= 0.75 * u } }
            guard let best = values.map({ agreeing($0) }).max(by: { $0.count < $1.count }), best.count >= 3 else { continue }
            // Right edges are only meaningful when most of the stack is right-aligned.
            if !useLeft && Double(best.count) < 0.6 * Double(column.count) { continue }
            let modal = best.map { values[$0] }.reduce(0, +) / Double(best.count)
            for (index, item) in column.enumerated() where !best.contains(index) {
                let offset = values[index] - modal
                guard abs(offset) > 0.75 * u, abs(offset) <= 3 * u else { continue }
                // Compare like with like: an icon beside a text column is not a misaligned text line.
                let peers = best.map { column[$0] }
                guard peers.allSatisfy({ $0.kind == item.kind }),
                      let tallest = ([item] + peers).map({ $0.rect.height }).max(),
                      let shortest = ([item] + peers).map({ $0.rect.height }).min(), tallest <= 1.8 * shortest else { continue }
                let side = useLeft ? "left" : "right"
                let direction = useLeft ? (offset > 0 ? "right" : "left") : (offset > 0 ? "right" : "left")
                findings.append(RawFinding(
                    category: .alignment, severity: 2, title: "Misaligned \(side) edge",
                    note: "Misaligned \(side) edge: this element's \(side) edge sits \(px(abs(offset))) too far \(direction) compared with the \(best.count) other elements in this stack, so it looks accidentally off-grid. Align it to the shared \(side) edge.",
                    rect: item.rect.insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil))
            }
        }
        return findings
    }

    private static func centreAlignment(_ row: [RuleElement], unit u: Double) -> [RawFinding] {
        guard row.count >= 2, row.count <= 12 else { return [] }
        let tops = row.map(\.rect.minY), bottoms = row.map(\.rect.maxY)
        // Deliberate top or bottom alignment (a tall thumbnail beside text) is fine.
        if let low = tops.min(), let high = tops.max(), high - low <= 0.75 * u { return [] }
        if let low = bottoms.min(), let high = bottoms.max(), high - low <= 0.75 * u { return [] }
        let centres = row.map(\.rect.midY)
        let middle = median(centres)
        let tallest = row.map(\.rect.height).max() ?? 0
        guard let odd = row.indices.max(by: { abs(centres[$0] - middle) < abs(centres[$1] - middle) }) else { return [] }
        let offset = centres[odd] - middle
        // Smaller than 1.2u is anti-aliasing; larger than a third of the row height is a different layout, not a slip.
        guard abs(offset) >= 1.2 * u, abs(offset) <= min(0.3 * tallest, 8 * u) else { return [] }
        let others = row.indices.filter { $0 != odd }
        let anchor = others.map { row[$0].rect }.reduce(row[others[0]].rect) { $0.union($1) }
        return [RawFinding(
            category: .alignment, severity: abs(offset) <= 3 * u ? 2 : 3, title: "Not vertically centred",
            note: "Not vertically centred: this element's centre is \(px(abs(offset))) \(offset > 0 ? "lower" : "higher") than the rest of its row, so items that should line up look off. Centre every item in the row on the same horizontal axis (align-items: center).",
            rect: row[odd].rect.union(anchor).insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil)]
    }

    private static func heightConsistency(_ row: [RuleElement], unit u: Double) -> [RawFinding] {
        let containers = row.filter { $0.kind == .container }
        guard containers.count >= 2, containers.count <= 10 else { return [] }
        let heights = containers.map(\.rect.height)
        guard let high = heights.max(), let low = heights.min() else { return [] }
        // About the same height but not the same: that reads as a mistake, not a different component.
        guard high - low > 1.2 * u, high - low <= max(5 * u, 0.12 * high) else { return [] }
        let usual = median(heights)
        guard let odd = containers.max(by: { abs($0.rect.height - usual) < abs($1.rect.height - usual) }) else { return [] }
        return [RawFinding(
            category: .sizing, severity: 2, title: "Inconsistent height",
            note: "Inconsistent height: controls in this row measure \(heights.sorted().map { px($0) }.joined(separator: ", ")) tall. This one is \(px(odd.rect.height)); the others are about \(px(usual)). Give controls of the same type one fixed height.",
            rect: odd.rect.insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil)]
    }

    // MARK: Contrast

    static func contrast(_ elements: [RuleElement], bitmap: LayoutBitmap, unit u: Double) -> [RawFinding] {
        var findings: [RawFinding] = []
        for element in elements where element.kind == .content && element.textLike {
            let height = element.rect.height
            guard height >= 5 * u, height <= 40 * u,
                  let measured = measureContrast(element.rect, bitmap: bitmap) else { continue }
            guard measured.ratio < 4.5 else { continue }
            let severity = measured.ratio < 3 ? 3 : 1
            findings.append(RawFinding(
                category: .contrast, severity: severity, title: "Low text contrast",
                note: "Low text contrast: this text measures about \(String(format: "%.1f", measured.ratio)):1 against its background (\(measured.foreground) on \(measured.background)). WCAG asks for at least 4.5:1 for normal text and 3:1 for large text. Darken the text or lighten the background.",
                rect: element.rect.insetBy(dx: -2 * u, dy: -2 * u), gapA: nil, gapB: nil))
        }
        return findings
    }

    private static func measureContrast(_ rect: CGRect, bitmap: LayoutBitmap)
        -> (ratio: Double, foreground: String, background: String)? {
        let s = bitmap.scale
        let x0 = max(0, Int((rect.minX * s).rounded(.down))), y0 = max(0, Int((rect.minY * s).rounded(.down)))
        let x1 = min(bitmap.width, Int((rect.maxX * s).rounded(.up))), y1 = min(bitmap.height, Int((rect.maxY * s).rounded(.up)))
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return nil }
        let ring = 3
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = (y * bitmap.width + x) * 4
            return (Int(bitmap.pixels[p]), Int(bitmap.pixels[p + 1]), Int(bitmap.pixels[p + 2]))
        }
        // Background = the most common colour in a thin band just outside the text.
        var counts: [Int: (count: Int, colour: (Int, Int, Int))] = [:]
        var sampled = 0
        for y in max(0, y0 - ring)..<min(bitmap.height, y1 + ring) {
            for x in max(0, x0 - ring)..<min(bitmap.width, x1 + ring) {
                if x >= x0 && x < x1 && y >= y0 && y < y1 { continue }
                let c = pixel(x, y)
                let key = ((c.0 >> 3) << 10) | ((c.1 >> 3) << 5) | (c.2 >> 3)
                counts[key, default: (0, c)].count += 1
                sampled += 1
            }
        }
        guard sampled > 0, let background = counts.values.max(by: { $0.count < $1.count }),
              Double(background.count) >= 0.6 * Double(sampled) else { return nil }
        let bg = background.colour
        var foreground = bg
        var farthest = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let c = pixel(x, y)
                let d = abs(c.0 - bg.0) + abs(c.1 - bg.1) + abs(c.2 - bg.2)
                if d > farthest { farthest = d; foreground = c }
            }
        }
        // Without a clear mark in the box there is no text to judge.
        guard farthest >= 36 else { return nil }
        let l1 = luminance(foreground), l2 = luminance(bg)
        let ratio = (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        return (ratio, hex(foreground), hex(bg))
    }

    private static func luminance(_ c: (Int, Int, Int)) -> Double {
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    private static func hex(_ c: (Int, Int, Int)) -> String { String(format: "#%02X%02X%02X", c.0, c.1, c.2) }

    // MARK: Guides

    /// Lines that several elements share. They are what a designer's grid overlay would show.
    static func guides(_ elements: [RuleElement], unit u: Double) -> [RawGuide] {
        let candidates = elements.filter { $0.rect.width >= 3 && $0.rect.height >= 3 }
        guard candidates.count >= 3, candidates.count <= 1500 else { return [] }
        func cluster(_ values: [Double], axis: LayoutGuide.Axis) -> [RawGuide] {
            let sorted = values.sorted()
            var result: [RawGuide] = []
            var start = 0
            while start < sorted.count {
                var end = start
                while end + 1 < sorted.count, sorted[end + 1] - sorted[start] <= 0.75 * u { end += 1 }
                let count = end - start + 1
                if count >= 3 {
                    let slice = sorted[start...end]
                    result.append(RawGuide(axis: axis, position: slice.reduce(0, +) / Double(count), count: count))
                }
                start = end + 1
            }
            return result
        }
        let xs = candidates.flatMap { [Double($0.rect.minX), Double($0.rect.maxX)] }
        let ys = candidates.flatMap { [Double($0.rect.minY), Double($0.rect.maxY)] }
        let all = cluster(xs, axis: .vertical) + cluster(ys, axis: .horizontal)
        return Array(all.sorted { $0.count > $1.count }.prefix(40))
    }

    // MARK: Helpers

    /// Groups siblings that sit on the same line (rows) or stack in the same column.
    private static func clusters(_ items: [RuleElement], rowsOf: Bool) -> [[RuleElement]] {
        func range(_ e: RuleElement) -> ClosedRange<Double> { rowsOf ? e.rect.minY...e.rect.maxY : e.rect.minX...e.rect.maxX }
        let sorted = items.sorted { range($0).lowerBound < range($1).lowerBound }
        var groups: [(anchor: ClosedRange<Double>, items: [RuleElement])] = []
        for item in sorted {
            let r = range(item)
            if let index = groups.firstIndex(where: { group in
                let overlap = min(group.anchor.upperBound, r.upperBound) - max(group.anchor.lowerBound, r.lowerBound)
                let shorter = min(group.anchor.upperBound - group.anchor.lowerBound, r.upperBound - r.lowerBound)
                return shorter > 0 && overlap >= 0.5 * shorter
            }) { groups[index].items.append(item) } else { groups.append((r, [item])) }
        }
        return groups.map(\.items)
    }

    /// Splits a line of items wherever the space between neighbours is large compared with the items themselves.
    private static func runs(_ items: [RuleElement], vertical: Bool) -> [[RuleElement]] {
        let sorted = items.sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        var result: [[RuleElement]] = []
        for item in sorted {
            if let last = result.last?.last {
                let gap = vertical ? item.rect.minY - last.rect.maxY : item.rect.minX - last.rect.maxX
                let size = max(last.rect.height, item.rect.height)
                if gap <= 2.5 * size { result[result.count - 1].append(item); continue }
            }
            result.append([item])
        }
        return result
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? Double(i.width * i.height / smaller) : 0
    }

    private static func median<T: BinaryFloatingPoint>(_ values: [T]) -> Double {
        let sorted = values.map { Double($0) }.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func px<T: BinaryFloatingPoint>(_ value: T) -> String { "\(Int(Double(value).rounded())) px" }
}
