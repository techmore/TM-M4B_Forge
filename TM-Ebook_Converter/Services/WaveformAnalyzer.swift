import AVFoundation
import Foundation

enum WaveformAnalyzer {
    nonisolated static func samples(for url: URL, targetSampleCount: Int = 900) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = max(1, file.length)
        let bucketCount = max(64, targetSampleCount)
        var peaks = Array(repeating: Float(0), count: bucketCount)
        let bufferFrameCapacity: AVAudioFrameCount = 8192

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: bufferFrameCapacity) else {
            return peaks
        }

        var globalFrame: AVAudioFramePosition = 0
        while globalFrame < frameCount {
            try file.read(into: buffer, frameCount: min(bufferFrameCapacity, AVAudioFrameCount(frameCount - globalFrame)))
            guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { break }

            let channels = Int(buffer.format.channelCount)
            let frames = Int(buffer.frameLength)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += abs(channelData[channel][frame])
                }
                let amplitude = channels > 0 ? sum / Float(channels) : 0
                let bucket = min(bucketCount - 1, Int((globalFrame + AVAudioFramePosition(frame)) * AVAudioFramePosition(bucketCount) / frameCount))
                peaks[bucket] = max(peaks[bucket], amplitude)
            }

            globalFrame += AVAudioFramePosition(frames)
        }

        let maxPeak = max(peaks.max() ?? 0, 0.001)
        return peaks.map { min(1, $0 / maxPeak) }
    }
}
