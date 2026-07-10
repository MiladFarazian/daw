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
        // both the half-tempo (bar) and double-tempo (subdivision) peaks — and weight
        // by a log-normal tempo prior around 120 BPM (Ellis-style). The prior kills
        // NON-octave sub-multiples (×2.5, ×1.5 lags that ride a subdivision grid);
        // octave misses stay harmless because callers fold octaves anyway.
        var bestLag = -1
        var bestScore: Float = 0
        for lag in minLag...maxLag {
            let bpmAtLag = rate * 60.0 / Double(lag)
            let oct = log2(bpmAtLag / 120.0)
            let prior = Float(exp(-(oct * oct) / (2 * 0.4 * 0.4)))
            let score = (ac(lag) + 0.5 * ac(lag * 2) + 0.33 * ac(lag * 3)) * prior
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

    // MARK: - Spectral balance

    /// Energy shares in three bands (low < 250 Hz · mid 250–4k · high > 4k), summing to 1.
    /// One-pole lowpasses — crude but monotone, deterministic, and plenty for comparison bars.
    static func bandBalance(_ x: [Float], sampleRate: Double) -> (low: Float, mid: Float, high: Float)? {
        guard x.count > 1024, sampleRate > 8000 else { return nil }
        func lowpassed(_ input: [Float], cutoff: Double) -> [Float] {
            let a = Float(1 - exp(-2 * Double.pi * cutoff / sampleRate))
            var y: Float = 0
            var out = [Float](repeating: 0, count: input.count)
            for i in 0..<input.count { y += a * (input[i] - y); out[i] = y }
            return out
        }
        func energy(_ v: [Float]) -> Float {
            var s: Float = 0
            for e in v { s += e * e }
            return s
        }
        let eLow = energy(lowpassed(x, cutoff: 250))
        let eLowMid = energy(lowpassed(x, cutoff: 4000))
        let eTotal = energy(x)
        let low = eLow
        let mid = max(0, eLowMid - eLow)
        let high = max(0, eTotal - eLowMid)
        let sum = low + mid + high
        guard sum > 0 else { return nil }
        return (low / sum, mid / sum, high / sum)
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

// MARK: - Reference Match (E3 — score your track against a reference you love)

/// One dimension of a reference comparison, ready for display.
struct MatchDimension: Identifiable {
    let id = UUID()
    let name: String
    let yours: String
    let reference: String
    let score: Double        // 0…1
    let tip: String?         // nil when close enough to leave alone
}

enum ReferenceMatch {

    /// Everything we measure about one piece of audio.
    struct Metrics {
        var bpm: Double?
        var key: (root: Int, minor: Bool)?
        var lufs: Double?
        var balance: (low: Float, mid: Float, high: Float)?
    }

    /// Measure a file (mono-mixed; analysis capped at 60 s, loudness over the whole file).
    static func metrics(url: URL, duration: TimeInterval) -> Metrics {
        let a = AudioAnalysis.analyze(url: url, offset: 0, duration: min(duration, 60))
        var m = Metrics(bpm: a.bpm, key: a.key, lufs: Loudness.integratedLUFS(url: url), balance: nil)
        if let file = try? AVAudioFile(forReading: url) {
            let sr = file.processingFormat.sampleRate
            let want = AVAudioFrameCount(min(Double(file.length), 60 * sr))
            if want > 0, let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want),
               (try? file.read(into: buf, frameCount: want)) != nil {
                m.balance = AudioAnalysis.bandBalance(PitchTune.monoSamples(buf), sampleRate: sr)
            }
        }
        return m
    }

    /// Compare your metrics against the reference's — one row per measurable dimension.
    /// Pure; every score is 0…1 and every tip is a concrete move, not a vibe.
    static func compare(yours: Metrics, reference: Metrics) -> [MatchDimension] {
        var dims: [MatchDimension] = []

        if let y = yours.bpm, let r = reference.bpm {
            let rate = AudioAnalysis.foldedRate(srcBPM: y, targetBPM: r)
            let off = abs(log2(rate))
            let score = max(0, 1 - off / 0.32)                      // ~25% off → 0
            let tip: String? = off < 0.02 ? nil
                : String(format: "Reference sits at ~%.0f BPM — try %@ toward %.0f.",
                         r, rate > 1 ? "speeding up" : "slowing down", r)
            dims.append(MatchDimension(name: "Tempo",
                                       yours: String(format: "%.0f BPM", y),
                                       reference: String(format: "%.0f BPM", r),
                                       score: score, tip: tip))
        }

        if let y = yours.key, let r = reference.key {
            let sameRoot = y.root == r.root
            let relative = (y.minor && !r.minor && (y.root + 3) % 12 == r.root)
                        || (!y.minor && r.minor && (r.root + 3) % 12 == y.root)
            let score: Double = (sameRoot && y.minor == r.minor) ? 1.0 : relative ? 0.85 : 0.3
            let shift = AudioAnalysis.semitoneShift(from: y.root, to: r.root)
            let tip: String? = score >= 0.85 ? nil
                : String(format: "Reference is in %@ %@ — transposing %+d st gets you there.",
                         noteName(r.root), r.minor ? "minor" : "major", shift)
            dims.append(MatchDimension(name: "Key",
                                       yours: "\(noteName(y.root)) \(y.minor ? "minor" : "major")",
                                       reference: "\(noteName(r.root)) \(r.minor ? "minor" : "major")",
                                       score: score, tip: tip))
        }

        if let y = yours.lufs, let r = reference.lufs, y.isFinite, r.isFinite {
            let diff = y - r
            let score = max(0, 1 - abs(diff) / 12)
            let tip: String? = abs(diff) < 1.5 ? nil
                : diff < 0 ? String(format: "Reference is ~%.0f dB louder — push the master (or run a master pass).", -diff)
                           : String(format: "You're ~%.0f dB hotter than the reference — ease the master back.", diff)
            dims.append(MatchDimension(name: "Loudness",
                                       yours: String(format: "%.1f LUFS", y),
                                       reference: String(format: "%.1f LUFS", r),
                                       score: score, tip: tip))
        }

        if let y = yours.balance, let r = reference.balance {
            let dLow = Double(abs(y.low - r.low)), dMid = Double(abs(y.mid - r.mid)), dHigh = Double(abs(y.high - r.high))
            let score = max(0, 1 - (dLow + dMid + dHigh) / 2 * 1.8)
            var tip: String?
            let diffs: [(name: String, gap: Float)] = [("lows", r.low - y.low),
                                                       ("mids", r.mid - y.mid),
                                                       ("highs", r.high - y.high)]
            if let biggest = diffs.max(by: { abs($0.gap) < abs($1.gap) }), abs(biggest.gap) > 0.08 {
                tip = biggest.gap > 0
                    ? "Reference has noticeably more \(biggest.name) — bring yours up (EQ or arrangement)."
                    : "Reference has fewer \(biggest.name) than you — carve some out."
            }
            func pct(_ b: (low: Float, mid: Float, high: Float)) -> String {
                String(format: "%.0f · %.0f · %.0f %%", b.low * 100, b.mid * 100, b.high * 100)
            }
            dims.append(MatchDimension(name: "Balance (L·M·H)",
                                       yours: pct(y), reference: pct(r),
                                       score: score, tip: tip))
        }

        return dims
    }

    /// Headline number: the mean of whatever dimensions were measurable.
    static func overall(_ dims: [MatchDimension]) -> Double {
        guard !dims.isEmpty else { return 0 }
        return dims.map(\.score).reduce(0, +) / Double(dims.count)
    }
}

/// Payload for the Reference Match sheet.
struct ReferenceMatchResult: Identifiable {
    let id = UUID()
    let referenceName: String
    let dimensions: [MatchDimension]
    let overall: Double
}
