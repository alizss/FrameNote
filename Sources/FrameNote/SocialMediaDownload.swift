import Foundation

/// Public-page extraction stays outside the UI actor. No browser cookies or login data are read.
enum SocialMediaDownload {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func isSocialPage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return ["x.com", "twitter.com", "instagram.com", "tiktok.com", "youtube.com", "youtu.be", "reddit.com", "vimeo.com", "facebook.com", "pinterest.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }

    static func download(_ url: URL, executable: URL? = nil) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw InspirationImportError.invalidURL
        }
        let paths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/yt-dlp").path]
        guard let binary = executable ?? paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map({ URL(fileURLWithPath: $0) }) else {
            throw Failure(message: "Social video import needs yt-dlp. Install it with brew install yt-dlp, then retry this link.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("framenote-social-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--ignore-config", "--no-playlist", "--playlist-items", "1", "--no-progress",
                             "--no-warnings", "--socket-timeout", "20", "--retries", "1",
                             "--max-filesize", "200M", "-f", "best[ext=mp4]/best",
                             "-o", directory.appendingPathComponent("media.%(ext)s").path, "--", url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline { throw Failure(message: "This link took too long to download. Try again.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        guard process.terminationStatus == 0,
              let media = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { ["mp4", "mov", "webm", "m4v"].contains($0.pathExtension) }) else {
            throw Failure(message: "Could not get a public video from this link. The post may be private, unavailable, or blocked by the site. Try another public link or open a local file.")
        }
        success = true
        return media
    }
}
