import AppKit
import UniformTypeIdentifiers

struct ClipboardMedia {
    let url: URL
    let source: String
    let temporary: Bool

    @MainActor static func read(_ board: NSPasteboard = .general) throws -> Self {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            return Self(url: url, source: url.lastPathComponent, temporary: false)
        }
        // Prefer raw animation/video over image previews, which can contain just one frame.
        for type in board.types ?? [] {
            guard let contentType = UTType(type.rawValue), contentType == .gif || contentType.conforms(to: .movie),
                  let data = board.data(forType: type), !data.isEmpty else { continue }
            return try temporaryFile(data, suffix: contentType.preferredFilenameExtension ?? "mp4")
        }
        for type in [NSPasteboard.PasteboardType.URL, .string] {
            if let text = board.string(forType: type)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let url = URL(string: text), ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
                return Self(url: url, source: text, temporary: false)
            }
        }
        if let image = NSImage(pasteboard: board), let data = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) {
            return try temporaryFile(png, suffix: "png")
        }
        throw InspirationImportError.unsupported
    }

    private static func temporaryFile(_ data: Data, suffix: String) throws -> Self {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inspiration-paste-\(UUID().uuidString).\(suffix)")
        try data.write(to: url, options: .atomic)
        return Self(url: url, source: "Pasted \(suffix.uppercased())", temporary: true)
    }
}

/// Resolve media advertised in HTML without requiring a browser or a site-specific downloader.
enum MediaPageResolver {
    static func candidates(in html: String, base: URL) -> [URL] {
        func matches(_ pattern: String, in text: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
            let text = text as NSString
            return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)).map { match in
                (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
            }
        }
        func decode(_ value: String) -> String {
            value.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "\\/", with: "/")
        }
        var values: [String] = []
        for tag in matches("<(?:meta|video|source)\\b[^>]*>", in: html).map({ $0[0] }) {
            var attributes: [String: String] = [:]
            for attribute in matches("([a-z_:]+)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag) {
                attributes[attribute[1].lowercased()] = decode(attribute[2])
            }
            if tag.lowercased().hasPrefix("<meta") {
                let key = attributes["property"] ?? attributes["name"] ?? ""
                if ["og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream"].contains(key), let content = attributes["content"] { values.append(content) }
            } else if let src = attributes["src"] { values.append(src) }
        }
        for match in matches("\"contentUrl\"\\s*:\\s*\"([^\"]+)\"", in: html) { values.append(decode(match[1])) }
        // Public galleries sometimes advertise the original only as a download link.
        for match in matches("href\\s*=\\s*[\"']([^\"']+\\.(?:mp4|mov|m4v|gif)(?:\\?[^\"']*)?)[\"']", in: html) { values.append(decode(match[1])) }
        var seen = Set<URL>()
        return values.compactMap { value in
            guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { return nil }
            return url
        }
    }
}
