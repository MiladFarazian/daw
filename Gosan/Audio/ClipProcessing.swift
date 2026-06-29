import AVFoundation

/// Pure audio analysis/processing on a clip's source segment.
/// No app dependencies (output dir is passed in) so it's unit-testable.
enum ClipProcessing {
    /// Read a clip's source segment into a buffer.
    private static func readSegment(url: URL, offset: TimeInterval, duration: TimeInterval)
        -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let start = AVAudioFramePosition(offset * sr)
        let available = file.length - start
        guard available > 0 else { return nil }
        let frames = AVAudioFrameCount(min(available, AVAudioFramePosition(duration * sr)))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: buffer, frameCount: frames)) != nil else { return nil }
        return (buffer, format)
    }

    /// Peak absolute sample amplitude of a clip's segment (0...1+).
    static func peak(url: URL, offset: TimeInterval, duration: TimeInterval) -> Float? {
        guard let (buffer, format) = readSegment(url: url, offset: offset, duration: duration),
              let data = buffer.floatChannelData else { return nil }
        var peak: Float = 0
        for c in 0..<Int(format.channelCount) {
            let p = data[c]
            for i in 0..<Int(buffer.frameLength) { let a = abs(p[i]); if a > peak { peak = a } }
        }
        return peak
    }

    /// Write a reversed copy of a clip's segment to `outputDir`; returns the new file URL.
    static func reverse(url: URL, offset: TimeInterval, duration: TimeInterval, outputDir: URL) -> URL? {
        guard let (buffer, format) = readSegment(url: url, offset: offset, duration: duration),
              let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        for c in 0..<Int(format.channelCount) {
            let p = data[c]
            var i = 0, j = n - 1
            while i < j { let t = p[i]; p[i] = p[j]; p[j] = t; i += 1; j -= 1 }
        }
        let out = outputDir.appendingPathComponent("\(UUID().uuidString)-reversed.caf")
        guard let outFile = try? AVAudioFile(forWriting: out, settings: format.settings),
              (try? outFile.write(from: buffer)) != nil else { return nil }
        return out
    }
}
