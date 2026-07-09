import Foundation
import AVFoundation

/// Offline musical analysis of audio: tempo (BPM) and key detection.
/// Pure DSP, no engine/hardware — verifiable in the headless harness.
enum AudioAnalysis {

    // MARK: - Mono + decimation helpers

    /// Box-average decimate by an integer factor (cheap anti-aliased downsample —
    /// plenty for onset/chroma analysis, same approach as PitchTune's curve pass).
    static func decimate(_ x: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        let n = x.count / factor
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            let base = i * factor
            for j in 0..<factor { s += x[base + j] }
            out[i] = s / Float(factor)
        }
        return out
    }

    // MARK: - Tempo

    /// Half-wave-rectified log-energy flux (the onset strength envelope) and its rate in Hz.
    static func onsetEnvelope(_ x: [Float], sampleRate: Double, hop: Int = 128) -> (flux: [Float], rate: Double) {
        let win = hop * 2
        guard x.count >= win * 4 else { return ([], 0) }
        var energies: [Float] = []
        energies.reserveCapacity(x.count / hop)
        var i = 0
        while i + win <= x.count {
            var e: Float = 0
            for j in i..<(i + win) { e += x[j] * x[j] }
            energies.append(log1p(20 * (e / Float(win)).squareRoot()))
            i += hop
        }
        var flux = [Float](repeating: 0, count: energies.count)
        for k in 1..<energies.count { flux[k] = max(0, energies[k] - energies[k - 1]) }
        return (flux, sampleRate / Double(hop))
    }

    /// Detect tempo from mono samples. Searches 50–200 BPM by autocorrelating the onset
    /// envelope, weighs harmonic support (so the beat wins over the bar or the subdivision),
    /// folds the result into 70–180, and snaps to an integer when very close.
    /// Returns nil when the signal has no usable periodicity (or is too short: needs ~4s).
    static func detectBPM(_ x: [Float], sampleRate: Double) -> Double? {
        // Work at ~11 kHz regardless of input rate.
        let factor = max(1, Int((sampleRate / 11_025.0).rounded()))
        let y = decimate(x, by: factor)
        let sr = sampleRate / Double(factor)
        let (rawFlux, rate) = onsetEnvelope(y, sampleRate: sr)
        guard rate > 0, rawFlux.count > Int(rate * 4) else { return nil }

        // Mean-center so silence doesn't correlate with itself.
        var flux = rawFlux
        let mean = flux.reduce(0, +) / Float(flux.count)
        for i in 0..<flux.count { flux[i] -= mean }

        let n = flux.count
        func ac(_ lag: Int) -> Float {
            guard lag > 0, lag < n - 1 else { return 0 }
            var s: Float = 0
            for i in 0..<(n - lag) { s += flux[i] * flux[i + lag] }
            return s / Float(n - lag)
        }

        let minLag = max(2, Int(rate * 60.0 / 200.0))
        let maxLag = min(n / 2, Int(rate * 60.0 / 50.0))
        guard maxLag > minLag + 2 else { return nil }

        var zero: Float = 0
        for i in 0..<n { zero += flux[i] * flux[i] }
        zero /= Float(n)
        guard zero > 0 else { return nil }

        // Score each candidate period with its harmonics so the true beat beats
        // both the half-tempo (bar) and double-tempo (subdivision) peaks.
        var bestLag = -1
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            let score = ac(lag) + 0.5 * ac(lag * 2) + 0.33 * ac(lag * 3)
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 0, ac(bestLag) > zero * 0.05 else { return nil }

        // Parabolic interpolation on the raw autocorrelation for sub-lag precision.
        let l = Double(bestLag)
        let a = Double(ac(bestLag - 1)), b = Double(ac(bestLag)), c = Double(ac(bestLag + 1))
        let denom = a - 2 * b + c
        let shift = denom != 0 ? 0.5 * (a - c) / denom : 0
        let period = (l + max(-0.5, min(0.5, shift))) / rate

        var bpm = 60.0 / period
        while bpm < 70 { bpm *= 2 }
        while bpm >= 180 { bpm /= 2 }
        let snapped = bpm.rounded()
        return abs(bpm - snapped) <= 0.35 ? snapped : bpm
    }

    // MARK: - Key

    /// 12-bin chroma via a Goertzel bank over MIDI notes 36…83, framed so sustained
    /// and moving material both register. Normalized to unit max.
    static func chroma(_ x: [Float], sampleRate: Double) -> [Float] {
        let factor = max(1, Int((sampleRate / 11_025.0).rounded()))
        let y = decimate(x, by: factor)
        let sr = sampleRate / Double(factor)
        let frame = 8192, hop = 4096
        guard y.count >= frame else { return [] }

        var bins = [Float](repeating: 0, count: 12)
        var start = 0
        while start + frame <= y.count {
            for midi in 36...83 {
                let f = 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
                guard f < sr / 2 * 0.9 else { continue }
                // Goertzel magnitude at frequency f over this frame.
                let w = 2.0 * Double.pi * f / sr
                let coeff = Float(2.0 * cos(w))
                var s0: Float = 0, s1: Float = 0, s2: Float = 0
                for i in start..<(start + frame) {
                    s0 = y[i] + coeff * s1 - s2
                    s2 = s1; s1 = s0
                }
                let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
                bins[midi % 12] += max(0, power).squareRoot()
            }
            start += hop
        }
        let peak = bins.max() ?? 0
        guard peak > 0 else { return [] }
        return bins.map { $0 / peak }
    }

    /// Krumhansl–Schmuckler key profiles.
    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = Float(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num: Float = 0, da: Float = 0, db: Float = 0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let d = (da * db).squareRoot()
        return d > 0 ? num / d : 0
    }

    /// Detect the key of mono samples: (root pitch class 0=C…11=B, minor?).
    /// Returns nil when the chroma is empty or no profile correlates convincingly.
    static func detectKey(_ x: [Float], sampleRate: Double) -> (root: Int, minor: Bool)? {
        let c = chroma(x, sampleRate: sampleRate)
        guard c.count == 12 else { return nil }
        // Percussive/atonal gates: tonal material has a few strong pitch classes and a
        // near-silent rest; broadband transients smear medium energy across many bins —
        // and pile it into the chromatic NEIGHBORS of the peak, which harmony never does.
        let muddy = c.filter { $0 >= 0.18 && $0 < 0.5 }.count
        guard muddy <= 5 else { return nil }
        if let peakIdx = c.indices.max(by: { c[$0] < c[$1] }) {
            let up = c[(peakIdx + 1) % 12], down = c[(peakIdx + 11) % 12]
            guard up < 0.5, down < 0.5 else { return nil }
        }
        var best: (score: Float, root: Int, minor: Bool) = (-2, 0, false)
        for root in 0..<12 {
            // Rotate the chroma so index 0 is the candidate root.
            var rotated = [Float](repeating: 0, count: 12)
            for i in 0..<12 { rotated[i] = c[(i + root) % 12] }
            let maj = pearson(rotated, majorProfile)
            let min = pearson(rotated, minorProfile)
            if maj > best.score { best = (maj, root, false) }
            if min > best.score { best = (min, root, true) }
        }
        guard best.score > 0.35 else { return nil }
        return (best.root, best.minor)
    }

    // MARK: - Fit math

    /// The time-stretch rate that conforms a loop at `srcBPM` to `targetBPM`, folding the
    /// source by octaves (×2 / ÷2) so a double- or half-time detection never causes a 2×
    /// speed change. rate > 1 = faster/shorter (matches ClipProcessing.timeStretch).
    static func foldedRate(srcBPM: Double, targetBPM: Double) -> Double {
        guard srcBPM > 0, targetBPM > 0 else { return 1 }
        var best = 1.0
        var bestDist = Double.infinity
        for k in -2...2 {
            let adjusted = srcBPM * pow(2.0, Double(k))
            let rate = targetBPM / adjusted
            let dist = abs(log2(rate))
            if dist < bestDist { bestDist = dist; best = rate }
        }
        return best
    }

    /// Smallest signed semitone shift from a detected root pitch class to a target one (−6…+5).
    static func semitoneShift(from root: Int, to target: Int) -> Int {
        var d = (target - root) % 12
        if d > 6 { d -= 12 }
        if d < -6 { d += 12 }
        return d
    }

    // MARK: - File convenience

    /// Analyze a clip segment (mono-mixed, capped at `maxSeconds`): detected BPM + key.
    static func analyze(url: URL, offset: TimeInterval, duration: TimeInterval,
                        maxSeconds: Double = 30) -> (bpm: Double?, key: (root: Int, minor: Bool)?) {
        guard let file = try? AVAudioFile(forReading: url) else { return (nil, nil) }
        let sr = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, offset) * sr)
        let want = AVAudioFrameCount(min(duration, maxSeconds) * sr)
        guard startFrame < file.length, want > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: min(want, AVAudioFrameCount(file.length - startFrame)))
        else { return (nil, nil) }
        file.framePosition = startFrame
        guard (try? file.read(into: buf, frameCount: buf.frameCapacity)) != nil else { return (nil, nil) }
        let mono = PitchTune.monoSamples(buf)
        guard !mono.isEmpty else { return (nil, nil) }
        return (detectBPM(mono, sampleRate: sr), detectKey(mono, sampleRate: sr))
    }
}
