import AVFoundation

/// Reads an audio file and produces a normalized peak envelope plus metadata.
/// Pure and stateless so it can run off the main actor during import.
enum WaveformLoader {
    static func load(url: URL, targetBuckets: Int = 1600) -> (peaks: [Float], duration: TimeInterval, sampleRate: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(file.length)

        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        let duration = Double(file.length) / sampleRate
        let bucketSize = max(1, frames / targetBuckets)

        var peaks: [Float] = []
        peaks.reserveCapacity(frames / bucketSize + 1)

        var index = 0
        while index < frames {
            let end = min(index + bucketSize, frames)
            var peak: Float = 0
            var sample = index
            while sample < end {
                var magnitude: Float = 0
                for channel in 0..<channelCount {
                    magnitude += abs(channels[channel][sample])
                }
                magnitude /= Float(channelCount)
                if magnitude > peak { peak = magnitude }
                sample += 1
            }
            peaks.append(peak)
            index += bucketSize
        }

        if let maxPeak = peaks.max(), maxPeak > 0 {
            peaks = peaks.map { min(1, $0 / maxPeak) }
        }
        return (peaks, duration, sampleRate)
    }
}
