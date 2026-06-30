import AVFoundation

/// Generates sidechain "ducking" volume automation from a trigger track's amplitude
/// envelope — the classic pump where a kick/loud source dips everything else.
/// Pure (file in → breakpoints out), so it's unit-testable.
enum Sidechain {
    /// gain(t) = 1 − depth · envelope(t), with a release tail so it ducks then recovers.
    static func duckingPoints(triggerURL: URL, depth: Float, release: TimeInterval,
                              window: TimeInterval = 0.025) -> [(time: TimeInterval, value: Float)] {
        guard let file = try? AVAudioFile(forReading: triggerURL) else { return [] }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let total = Int(file.length)
        guard total > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              (try? file.read(into: buffer)) != nil,
              let data = buffer.floatChannelData else { return [] }

        let n = Int(buffer.frameLength)
        let channels = Int(format.channelCount)
        let win = max(1, Int(window * sampleRate))

        // Per-window peak envelope.
        var env: [Float] = []
        var i = 0
        while i < n {
            let end = min(i + win, n)
            var peak: Float = 0
            for c in 0..<channels {
                let p = data[c]
                for j in i..<end { let a = abs(p[j]); if a > peak { peak = a } }
            }
            env.append(peak)
            i += win
        }
        guard !env.isEmpty else { return [] }

        // Release smoothing: the envelope decays slowly after a transient.
        let releaseCoef = Float(exp(-window / max(0.01, release)))
        var prev: Float = 0
        for k in env.indices {
            prev = max(env[k], prev * releaseCoef)
            env[k] = prev
        }

        // Normalize, convert to gain, thin out near-identical points.
        let maxEnv = max(0.0001, env.max() ?? 0)
        let clampedDepth = min(1, max(0, depth))
        var points: [(TimeInterval, Float)] = []
        var lastValue: Float = -1
        for (k, e) in env.enumerated() {
            let gain = max(0, 1 - clampedDepth * (e / maxEnv))
            let time = Double(k) * window
            if k == 0 || k == env.count - 1 || abs(gain - lastValue) > 0.03 {
                points.append((time, gain))
                lastValue = gain
            }
        }
        return points
    }
}
