@preconcurrency import AVFoundation
import CoreGraphics

public enum VideoEvidence {
    /// Preserve exact sampling where possible; clips can have an undecodable tail after the last video frame.
    public static func frame(from generator: AVAssetImageGenerator, at requested: CMTime) throws -> (image: CGImage, time: CMTime) {
        var actual = CMTime.zero
        do {
            return (try generator.copyCGImage(at: requested, actualTime: &actual), actual)
        } catch {
            let before = generator.requestedTimeToleranceBefore
            let after = generator.requestedTimeToleranceAfter
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            defer {
                generator.requestedTimeToleranceBefore = before
                generator.requestedTimeToleranceAfter = after
            }
            return (try generator.copyCGImage(at: requested, actualTime: &actual), actual)
        }
    }
}
