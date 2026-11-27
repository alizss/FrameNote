import AppKit
import Foundation
import ImageIO
import FrameNoteCore

struct ReviewDraft: Codable, Sendable {
    var title: String
    var marks: [ReviewMark]
    var mediaFile: String
    var currentTime: Double
    var id: UUID? = nil
    var updatedAt: Date? = nil
}

struct SavedReview: Identifiable, Sendable {
    var id: UUID
    var draft: ReviewDraft
    var media: URL
}

/// Each reference owns its media and manifest; draft.json points to the latest review.
actor ReviewDrafts {
    private let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FrameNote/Draft", isDirectory: true)
    }

    func load() throws -> (ReviewDraft, URL)? {
        let manifest = folder.appendingPathComponent("draft.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        var draft = try JSONDecoder().decode(ReviewDraft.self, from: Data(contentsOf: manifest))
        let media = folder.appendingPathComponent(draft.mediaFile)
        guard FileManager.default.fileExists(atPath: media.path) else { return nil }
        if draft.id == nil {
            let id = UUID()
            let directory = folder.appendingPathComponent("Reviews/\(id.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(media.lastPathComponent)
            try FileManager.default.copyItem(at: media, to: target)
            draft.id = id
            draft.updatedAt = Date()
            draft.mediaFile = "Reviews/\(id.uuidString)/\(media.lastPathComponent)"
            let data = try JSONEncoder().encode(draft)
            try data.write(to: directory.appendingPathComponent("review.json"), options: .atomic)
            try data.write(to: manifest, options: .atomic)
            return (draft, target)
        }
        return (draft, media)
    }

    func list() throws -> [SavedReview] {
        _ = try load() // Carry forward the single draft from older versions.
        let root = folder.appendingPathComponent("Reviews")
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("review.json")),
                  let draft = try? JSONDecoder().decode(ReviewDraft.self, from: data), let id = draft.id else { return nil }
            return SavedReview(id: id, draft: draft, media: folder.appendingPathComponent(draft.mediaFile))
        }.sorted { ($0.draft.updatedAt ?? .distantPast) > ($1.draft.updatedAt ?? .distantPast) }
    }

    func save(title: String, marks: [ReviewMark], screenshot: CGImage?, videoURL: URL?,
              currentTime: Double, generation: UUID) throws {
        guard screenshot != nil || videoURL != nil else { return }
        let directory = folder.appendingPathComponent("Reviews/\(generation.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = screenshot == nil ? "media.mov" : "media.png"
        let destination = directory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) {
            if let screenshot {
                let buffer = NSMutableData()
                guard let writer = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else {
                    throw DesignerAssistantError.missingEvidence
                }
                CGImageDestinationAddImage(writer, screenshot, nil)
                guard CGImageDestinationFinalize(writer) else { throw DesignerAssistantError.missingEvidence }
                try (buffer as Data).write(to: destination, options: .atomic)
            } else if let videoURL {
                try FileManager.default.copyItem(at: videoURL, to: destination)
            }
        }
        let draft = ReviewDraft(title: title, marks: marks,
            mediaFile: "Reviews/\(generation.uuidString)/\(filename)", currentTime: currentTime,
            id: generation, updatedAt: Date())
        let data = try JSONEncoder().encode(draft)
        try data.write(to: directory.appendingPathComponent("review.json"), options: .atomic)
        try data.write(to: folder.appendingPathComponent("draft.json"), options: .atomic)
    }
}
