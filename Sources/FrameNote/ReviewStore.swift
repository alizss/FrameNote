import AppKit
import Combine
import Foundation
import FrameNoteCore

@MainActor
final class ReviewStore: ObservableObject {
    @Published var screenshot: NSImage?
    @Published var reference: NSImage?
    @Published var marks: [ReviewMark] = []
    @Published var title = "UI feedback"
    @Published var tool: MarkKind = .point
    @Published var compare = false
    @Published var comparisonFraction = 0.5
    @Published var status = "Choose a screenshot or capture a window to start."
    @Published var isCapturing = false
    @Published var lastExport: URL?

    func importScreenshot() {
        guard let url = chooseImage() else { return }
        guard let image = NSImage(contentsOf: url) else {
            status = "Could not read that image. Choose a PNG or JPEG."
            return
        }
        screenshot = image
        marks = []
        lastExport = nil
        compare = false
        status = "Screenshot ready. Select a tool and mark the image."
    }

    func importReference() {
        guard let url = chooseImage() else { return }
        guard let image = NSImage(contentsOf: url) else {
            status = "Could not read the reference image."
            return
        }
        reference = image
        compare = true
        status = "Drag the compare slider to inspect before and after."
    }

    private func chooseImage() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    func captureWindow() {
        guard !isCapturing else { return }
        isCapturing = true
        status = "Click the window you want to capture. Press Escape to cancel."
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("framenote-\(UUID().uuidString).png")
        Task {
            let result: Int32 = await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", "-w", "-x", destination.path]
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus
                } catch {
                    return -1
                }
            }.value
            defer {
                try? FileManager.default.removeItem(at: destination)
                isCapturing = false
            }
            guard result == 0, let image = NSImage(contentsOf: destination) else {
                status = result == 0 ? "Capture cancelled." : "Capture failed. Check Screen Recording permission for FrameNote."
                return
            }
            screenshot = image
            marks = []
            lastExport = nil
            compare = false
            status = "Window captured. Select a tool and mark the image."
        }
    }

    func addMark(start: UnitPoint2D, end: UnitPoint2D?) {
        guard screenshot != nil else { return }
        marks.append(ReviewMark(kind: tool, start: start, end: tool == .point ? nil : end, note: ""))
        status = "Mark \(marks.count) added. Add a note in the right panel."
    }

    func export() {
        guard let screenshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the feedback report."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try ReviewExporter.export(
                screenshot: screenshot,
                reference: reference,
                title: title,
                marks: marks,
                into: parent
            )
            lastExport = folder
            status = "Exported feedback to \(folder.lastPathComponent)."
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    func revealExport() {
        guard let lastExport else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExport])
    }
}
