@preconcurrency import AVFoundation
import Foundation

/// Index presentation timestamps without decoding pixels, including variable-rate imports.
enum VideoFrameIndex {
    static func load(_ url: URL) async throws -> [Double] {
        let task = Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [Double]() }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? NSError(domain: "FrameNote", code: 1) }
            defer { reader.cancelReading() }
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if time.isFinite { times.append(time) }
            }
            if let error = reader.error { throw error }
            return Array(Set(times)).sorted()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    static func adjacent(to time: Double, direction: Int, times: [Double]) -> Double? {
        guard !times.isEmpty else { return nil }
        // Upper bound avoids mistaking floating-point rounding for another frame.
        var low = 0, high = times.count
        let epsilon = 0.000001
        while low < high {
            let mid = (low + high) / 2
            if times[mid] <= time + epsilon { low = mid + 1 } else { high = mid }
        }
        if direction > 0 { return times[min(low, times.count - 1)] }
        var index = max(0, low - 1)
        if abs(times[index] - time) < epsilon { index = max(0, index - 1) }
        return times[index]
    }
}
