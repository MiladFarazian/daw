import AVFoundation

/// ITU-R BS.1770 integrated loudness (LUFS) + peak — the standard streaming loudness
/// measure. Pure (file in → numbers out), so it's unit-testable.
enum Loudness {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Double
        func process(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let xn = x[i]
                let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                y[i] = yn; x2 = x1; x1 = xn; y2 = y1; y1 = yn
            }
            return y
        }
    }
    // K-weighting (48 kHz reference coefficients; close enough at 44.1 kHz for a readout).
    private static let shelf = Biquad(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                      a1: -1.69065929318241, a2: 0.73248077421585)
    private static let highpass = Biquad(b0: 1.0, b1: -2.0, b2: 1.0,
                                         a1: -1.99004745483398, a2: 0.99007225036621)

    /// Integrated loudness (LUFS) with absolute (−70) + relative (−10 LU) gating.
    static func integratedLUFS(url: URL) -> Double? {
        guard let (channels, sr) = readChannels(url: url), let first = channels.first else { return nil }
        let weighted = channels.map { highpass.process(shelf.process($0)) }
        let n = first.count
        let blockSize = Int(0.4 * sr)          // 400 ms
        let step = max(1, Int(0.1 * sr))       // 100 ms (75% overlap)
        guard blockSize > 0, n >= blockSize else { return nil }

        func loudness(_ power: Double) -> Double { power > 0 ? -0.691 + 10 * log10(power) : -.infinity }

        var powers: [Double] = []
        var start = 0
        while start + blockSize <= n {
            var power = 0.0
            for ch in weighted {
                var sum = 0.0
                for i in start..<(start + blockSize) { sum += ch[i] * ch[i] }
                power += sum / Double(blockSize)   // channel weight 1.0 for L/R
            }
            powers.append(power)
            start += step
        }
        guard !powers.isEmpty else { return nil }

        let absGated = powers.filter { loudness($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let meanAbs = absGated.reduce(0, +) / Double(absGated.count)
        let threshold = loudness(meanAbs) - 10
        let gated = absGated.filter { loudness($0) > threshold }
        let final = gated.isEmpty ? absGated : gated
        return loudness(final.reduce(0, +) / Double(final.count))
    }

    /// Sample peak in dBFS (a good approximation of true peak for a readout).
    static func peakDBFS(url: URL) -> Double? {
        guard let (channels, _) = readChannels(url: url) else { return nil }
        var peak = 0.0
        for ch in channels { for s in ch { let a = abs(s); if a > peak { peak = a } } }
        return peak > 0 ? 20 * log10(peak) : -.infinity
    }

    private static func readChannels(url: URL) -> (channels: [[Double]], sr: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
        let n = Int(buffer.frameLength)
        var channels: [[Double]] = []
        for c in 0..<Int(format.channelCount) {
            var arr = [Double](repeating: 0, count: n)
            let p = data[c]
            for i in 0..<n { arr[i] = Double(p[i]) }
            channels.append(arr)
        }
        return (channels, format.sampleRate)
    }
}
