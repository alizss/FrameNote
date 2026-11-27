import AppKit
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

struct ImportedInspiration: Sendable {
    var url: URL
    var isVideo: Bool
    var duration: Double
}

enum InspirationImportError: LocalizedError {
    case invalidURL, webpage, unsupported, tooLarge, conversion
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Paste an http or https link to a video, GIF, or image."
        case .webpage: "This page does not expose a downloadable video or GIF. Copy its direct media link or download the file and paste it here."
        case .unsupported: "Could not read this media. Choose a video, GIF, PNG, or JPEG."
        case .tooLarge: "This file is too large. Choose a file under 200 MB."
        case .conversion: "Could not prepare this GIF as a playable clip."
        }
    }
}

actor InspirationImporter {
    static let shared = InspirationImporter()
    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameNote/Imported Inspiration", isDirectory: true)
    }

    func importReference(_ source: URL) async throws -> ImportedInspiration {
        if !source.isFileURL && SocialMediaDownload.isSocialPage(source) {
            return try await importSocial(source)
        }
        do { return try await importMedia(source) }
        catch InspirationImportError.webpage {
            return try await importSocial(source)
        }
    }

    private func importSocial(_ source: URL) async throws -> ImportedInspiration {
        let local = try await SocialMediaDownload.download(source)
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        return try await importMedia(local)
    }

    typealias DownloadMedia = @Sendable (URLRequest) async throws -> (URL, URLResponse)

    func importMedia(_ source: URL,
                     download: DownloadMedia = { try await URLSession.shared.download(for: $0) }, pageDepth: Int = 0) async throws -> ImportedInspiration {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let local: URL
        var downloaded: URL?
        defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) } }
        if source.isFileURL { local = source }
        else {
            guard ["https", "http"].contains(source.scheme?.lowercased() ?? ""), source.host != nil else { throw InspirationImportError.invalidURL }
            var request = URLRequest(url: source); request.timeoutInterval = 45
            let (temporary, response) = try await download(request)
            downloaded = temporary
            guard let response = response as? HTTPURLResponse else { throw InspirationImportError.unsupported }
            guard (200..<300).contains(response.statusCode) else {
                if [401, 403].contains(response.statusCode) { throw InspirationImportError.webpage }
                throw InspirationImportError.unsupported
            }
            if response.mimeType?.contains("html") == true {
                guard pageDepth < 2, (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 5 * 1024 * 1024 else { throw InspirationImportError.webpage }
                let html = try String(contentsOf: temporary, encoding: .utf8)
                for candidate in MediaPageResolver.candidates(in: html, base: response.url ?? source).prefix(6) where candidate != source {
                    do { return try await importMedia(candidate, download: download, pageDepth: pageDepth + 1) }
                    catch is CancellationError { throw CancellationError() }
                    catch { if Task.isCancelled { throw CancellationError() } }
                }
                throw InspirationImportError.webpage
            }
            // URLSession uses a .tmp suffix; AVFoundation needs the media's actual container suffix.
            let suffix = response.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
                ?? response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension }.flatMap { $0.isEmpty ? nil : $0 }
                ?? (source.pathExtension.isEmpty ? "bin" : source.pathExtension)
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("inspiration-download-\(UUID().uuidString)").appendingPathExtension(suffix)
            try FileManager.default.moveItem(at: temporary, to: staged)
            downloaded = staged
            local = staged
        }
        let bytes = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes <= 200 * 1024 * 1024 else { throw InspirationImportError.tooLarge }
        try Task.checkCancellation()
        if let images = CGImageSourceCreateWithURL(local as CFURL, nil), CGImageSourceGetCount(images) > 0 {
            if CGImageSourceGetCount(images) > 1 {
                let destination = folder.appendingPathComponent("inspiration-\(UUID().uuidString).mov")
                try await convertAnimation(images, into: destination)
                let duration = try await AVURLAsset(url: destination).load(.duration).seconds
                return ImportedInspiration(url: destination, isVideo: true, duration: duration)
            }
            guard let image = CGImageSourceCreateImageAtIndex(images, 0, nil) else { throw InspirationImportError.unsupported }
            let destination = folder.appendingPathComponent("inspiration-\(UUID().uuidString).png")
            guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw InspirationImportError.unsupported }
            CGImageDestinationAddImage(writer, image, nil)
            guard CGImageDestinationFinalize(writer) else { throw InspirationImportError.unsupported }
            return ImportedInspiration(url: destination, isVideo: false, duration: 0)
        }
        let asset = AVURLAsset(url: local)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { throw InspirationImportError.unsupported }
        // Preserve the container suffix when available, including downloaded files without a suffix.
        let ext = local.pathExtension.lowercased()
        let destination = folder.appendingPathComponent("inspiration-\(UUID().uuidString).\(["mp4", "mov", "m4v", "webm"].contains(ext) ? ext : "mp4")")
        try FileManager.default.copyItem(at: local, to: destination)
        return ImportedInspiration(url: destination, isVideo: true, duration: duration)
    }

    private func convertAnimation(_ source: CGImageSource, into url: URL) async throws {
        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw InspirationImportError.conversion }
        let scale = min(1, 1280 / Double(max(first.width, first.height)))
        let width = max(2, Int(Double(first.width) * scale) / 2 * 2)
        let height = max(2, Int(Double(first.height) * scale) / 2 * 2)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var complete = false
        defer { if !complete { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) } }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw InspirationImportError.conversion }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? InspirationImportError.conversion }
        writer.startSession(atSourceTime: .zero)
        var time = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw InspirationImportError.conversion }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? InspirationImportError.conversion }
                try await Task.sleep(for: .milliseconds(2))
            }
            guard let pool = adaptor.pixelBufferPool else { throw InspirationImportError.conversion }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw InspirationImportError.conversion }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else { CVPixelBufferUnlockBaseAddress(buffer, []); throw InspirationImportError.conversion }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60000)) else { throw writer.error ?? InspirationImportError.conversion }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1
            time += max(0.02, delay)
        }
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 60000))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? InspirationImportError.conversion }
        complete = true
    }
}

struct InspirationImportView: View {
    @ObservedObject var store: ReviewStore
    @Environment(\.dismiss) private var dismiss
    var pasteOnOpen = false
    var onImported: () -> Void = {}
    @State private var urlText = ""
    @State private var busy = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add a reference").font(.title2.weight(.semibold))
            Text("Paste a link or choose an image, GIF, or video.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Paste a video, GIF, image, or page URL", text: $urlText).textFieldStyle(.roundedBorder)
                .onSubmit { importURL() }.disabled(busy)
            HStack {
                Button("Open link") { importURL() }.disabled(busy || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Choose file…") { chooseFile() }.disabled(busy)
                Button("Paste media") { paste() }.disabled(busy)
            }
            Text("Public social videos are downloaded automatically. Private or restricted posts may be unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            if busy { HStack { ProgressView().controlSize(.small); Text("Preparing inspiration…") }.font(.callout) }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 480)
        .onAppear { if pasteOnOpen { paste() } }
        .onDisappear { task?.cancel() }
    }

    private func importURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { error = InspirationImportError.invalidURL.localizedDescription; return }
        start(url, source: url.absoluteString)
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .image]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { start(url, source: url.lastPathComponent) }
    }
    private func paste() {
        do {
            let media = try ClipboardMedia.read()
            start(media.url, source: media.source, cleanup: media.temporary)
        } catch { self.error = "Copy a video file, GIF, image, or media link, then paste here." }
    }
    private func start(_ url: URL, source: String, cleanup: Bool = false) {
        busy = true; error = nil
        task = Task {
            defer { if cleanup { try? FileManager.default.removeItem(at: url) } }
            do {
                try await store.importInspiration(url, source: source)
                busy = false; onImported(); dismiss()
            } catch is CancellationError { busy = false }
            catch { self.error = error.localizedDescription; busy = false }
        }
    }
}
