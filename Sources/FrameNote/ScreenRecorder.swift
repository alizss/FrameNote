@preconcurrency import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

@MainActor
final class ScreenRecorder {
    private var session: ScreenRecordingSession?

    var isRecording: Bool { session != nil }

    func start() async throws {
        guard session == nil else { return }
        let shareable: SCShareableContent
        do {
            shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.actionableCaptureError(error)
        }
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
        do {
            try await newSession.start()
        } catch {
            throw Self.actionableCaptureError(error)
        }
        session = newSession
    }

    private static func actionableCaptureError(_ error: Error) -> Error {
        let captureError = error as NSError
        guard captureError.domain == SCStreamErrorDomain,
              captureError.code == SCStreamError.userDeclined.rawValue else { return error }
        return RecorderError.screenRecordingPermission
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
    case screenRecordingPermission
    case recordingOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No screen is available to record."
        case .notRecording: "There is no active recording."
        case .noFrames: "No video frames were recorded. Try again after granting Screen Recording permission."
        case .screenRecordingPermission: "Turn on FrameNote in Privacy & Security → Screen & System Audio Recording, then reopen it."
        case .recordingOutputUnavailable: "macOS could not prepare a video file for recording. Restart FrameNote and try again."
        }
    }
}

private final class ScreenRecordingSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private let outputURL: URL
    private let stream: SCStream
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    // Retain the native output through finalization. NSObject keeps this property
    // available on macOS 14, where ScreenCaptureKit's recording-output API is absent.
    private var nativeOutput: NSObject?
    private var nativeDelegate: NSObject?
    private let queue = DispatchQueue(label: "dev.framenote.recorder.frames")
    private var didStartSession = false
    private var captureError: Error?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, outputURL: URL) throws {
        self.outputURL = outputURL
        stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        super.init()

        if #available(macOS 15.0, *) {
            let outputConfiguration = SCRecordingOutputConfiguration()
            outputConfiguration.outputURL = outputURL
            outputConfiguration.outputFileType = .mov
            outputConfiguration.videoCodecType = AVVideoCodecType.h264
            let delegate = NativeRecordingDelegate()
            let output = SCRecordingOutput(configuration: outputConfiguration, delegate: delegate)
            try stream.addRecordingOutput(output)
            nativeOutput = output
            nativeDelegate = delegate
        } else {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: configuration.width,
                AVVideoHeightKey: configuration.height,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw RecorderError.noFrames }
            writer.add(input)
            self.writer = writer
            self.input = input
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        }
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stop() async throws -> URL {
        do {
            try await stream.stopCapture()
        } catch {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        if #available(macOS 15.0, *), nativeOutput != nil {
            do {
                // stopCapture stops the native recording output; wait for its
                // completion callback before handing the file to AVPlayer.
                guard let delegate = nativeDelegate as? NativeRecordingDelegate else {
                    throw RecorderError.recordingOutputUnavailable
                }
                try await delegate.waitForFinalization()
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                    throw RecorderError.noFrames
                }
                return outputURL
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                throw error
            }
        }

        guard let writer, let input else {
            try? FileManager.default.removeItem(at: outputURL)
            throw RecorderError.recordingOutputUnavailable
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
        guard let writer, let input else { return }
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

@available(macOS 15.0, *)
private final class NativeRecordingDelegate: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        complete(.failure(error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        complete(.success(()))
    }

    func waitForFinalization() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
