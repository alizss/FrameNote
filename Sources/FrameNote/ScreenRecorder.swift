@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenRecorder {
    private var session: ScreenRecordingSession?

    var isRecording: Bool { session != nil }

    func start() async throws {
        guard session == nil else { return }
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = shareable.displays.first else {
            throw RecorderError.noDisplay
        }
        let ownApplication = shareable.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplication.map { [$0] } ?? [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("FrameNote-\(UUID().uuidString).mov")
        let newSession = try ScreenRecordingSession(filter: filter, configuration: configuration, outputURL: output)
        try await newSession.start()
        session = newSession
    }

    func stop() async throws -> URL {
        guard let session else { throw RecorderError.notRecording }
        self.session = nil
        return try await session.stop()
    }
}

private enum RecorderError: LocalizedError {
    case noDisplay
    case notRecording
    case noFrames

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No screen is available to record."
        case .notRecording: "There is no active recording."
        case .noFrames: "No video frames were recorded. Try again after granting Screen Recording permission."
        }
    }
}

private final class ScreenRecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let outputURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let stream: SCStream
    private let queue = DispatchQueue(label: "dev.framenote.recorder.frames")
    private var didStartSession = false
    private var captureError: Error?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, outputURL: URL) throws {
        self.outputURL = outputURL
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(18_000_000, max(6_000_000, configuration.width * configuration.height * 2)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.noFrames }
        writer.add(input)
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        do {
            try await stream.stopCapture()
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let captureError {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: captureError)
                    return
                }
                guard didStartSession else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                input.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: outputURL)
                    } else {
                        continuation.resume(throwing: writer.error ?? RecorderError.noFrames)
                    }
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if !didStartSession {
            guard writer.startWriting() else {
                captureError = writer.error ?? RecorderError.noFrames
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            didStartSession = true
        }
        if input.isReadyForMoreMediaData && !input.append(sampleBuffer) {
            captureError = writer.error ?? RecorderError.noFrames
        }
    }
}
