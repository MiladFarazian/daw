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

    /// Seconds of near-silence at the start and end of a clip's segment.
    static func silenceBounds(url: URL, offset: TimeInterval, duration: TimeInterval,
                              threshold: Float = 0.01) -> (leading: TimeInterval, trailing: TimeInterval)? {
        guard let (buffer, format) = readSegment(url: url, offset: offset, duration: duration),
              let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let sr = format.sampleRate
        func loud(_ i: Int) -> Bool {
            for c in 0..<channels where abs(data[c][i]) > threshold { return true }
            return false
        }
        var first = 0
        while first < n && !loud(first) { first += 1 }
        guard first < n else { return nil } // all silence
        var last = n - 1
        while last > first && !loud(last) { last -= 1 }
        return (Double(first) / sr, Double(n - 1 - last) / sr)
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

    /// Time-stretch a clip's segment by `rate` (rate < 1 = slower/longer; pitch preserved)
    /// via an offline AVAudioUnitTimePitch render. Writes a new file; returns its URL.
    static func timeStretch(url: URL, offset: TimeInterval, duration: TimeInterval,
                            rate: Float, outputDir: URL) -> URL? {
        guard rate > 0, rate != 1,
              let (input, format) = readSegment(url: url, offset: offset, duration: duration) else { return nil }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = rate
        engine.attach(player); engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            try engine.start()
        } catch { return nil }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        let outFrames = AVAudioFramePosition((Double(input.frameLength) / Double(rate)).rounded(.up))
        let out = outputDir.appendingPathComponent("\(UUID().uuidString)-stretched.caf")
        guard let outFile = try? AVAudioFile(forWriting: out, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            engine.stop(); return nil
        }
        while engine.manualRenderingSampleTime < outFrames {
            let remaining = outFrames - engine.manualRenderingSampleTime
            let toRender = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            guard toRender > 0, let status = try? engine.renderOffline(toRender, to: buffer) else { break }
            if status == .success { try? outFile.write(from: buffer) } else if status == .error { break }
        }
        player.stop(); engine.stop()
        return out
    }
}
