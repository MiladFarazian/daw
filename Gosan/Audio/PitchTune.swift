import AVFoundation

/// Vocal pitch correction: detect the sung pitch over time (YIN), snap it toward the project's
/// scale, and re-render the audio tuned. Detection + snap math are pure and unit-tested; the
/// render is verified by measuring the output pitch.
enum PitchTune {

    // MARK: - Pure analysis

    /// Fundamental frequency (Hz) of a mono frame via the YIN difference function, or nil when
    /// the frame is unvoiced / too quiet / has no clear pitch. Pure.
    static func detectPitch(_ x: [Float], sampleRate: Double,
                            minHz: Double = 70, maxHz: Double = 1000) -> Double? {
        let n = x.count
        guard n > 64, sampleRate > 0 else { return nil }
        // Energy gate — skip silence / unvoiced.
        var energy = 0.0
        for s in x { energy += Double(s) * Double(s) }
        guard sqrt(energy / Double(n)) > 0.01 else { return nil }

        let minLag = max(2, Int(sampleRate / maxHz))
        let maxLag = min(n - 1, Int(sampleRate / minHz))
        guard maxLag > minLag else { return nil }

        // YIN difference function + cumulative mean normalization.
        var d = [Double](repeating: 0, count: maxLag + 1)
        for lag in 1...maxLag {
            var sum = 0.0
            for i in 0..<(n - lag) {
                let diff = Double(x[i]) - Double(x[i + lag])
                sum += diff * diff
            }
            d[lag] = sum
        }
        var cmnd = [Double](repeating: 1, count: maxLag + 1)
        var running = 0.0
        for lag in 1...maxLag {
            running += d[lag]
            cmnd[lag] = running > 0 ? d[lag] * Double(lag) / running : 1
        }

        // First dip below threshold (a real period), else the global minimum.
        let threshold = 0.15
        var bestLag = -1
        var lag = minLag
        while lag <= maxLag {
            if cmnd[lag] < threshold {
                while lag + 1 <= maxLag && cmnd[lag + 1] < cmnd[lag] { lag += 1 }  // deepen to local min
                bestLag = lag
                break
            }
            lag += 1
        }
        if bestLag < 0 {
            var best = Double.greatestFiniteMagnitude
            for l in minLag...maxLag where cmnd[l] < best { best = cmnd[l]; bestLag = l }
            if best > 0.3 { return nil }   // nothing periodic enough
        }
        guard bestLag > 0 else { return nil }

        // Parabolic interpolation for sub-sample precision.
        var lagF = Double(bestLag)
        if bestLag > minLag && bestLag < maxLag {
            let s0 = cmnd[bestLag - 1], s1 = cmnd[bestLag], s2 = cmnd[bestLag + 1]
            let denom = s0 + s2 - 2 * s1
            if denom != 0 { lagF += (s0 - s2) / (2 * denom) }
        }
        return lagF > 0 ? sampleRate / lagF : nil
    }

    /// The nearest MIDI note in `scalePCs` (pitch classes 0–11; empty = chromatic) to `hz`. Pure.
    static func nearestScaleMidi(hz: Double, scalePCs: [Int]) -> Int {
        let midi = 69.0 + 12.0 * log2(hz / 440.0)
        let center = Int(midi.rounded())
        let pcs = scalePCs.isEmpty ? Array(0..<12) : scalePCs
        var best = center
        var bestErr = Double.greatestFiniteMagnitude
        for m in (center - 7)...(center + 7) {
            let pc = ((m % 12) + 12) % 12
            guard pcs.contains(pc) else { continue }
            let err = abs(Double(m) - midi)
            if err < bestErr { bestErr = err; best = m }
        }
        return best
    }

    /// How far (cents) to shift `hz` toward its nearest scale note, scaled by `strength` (0…1). Pure.
    static func correctionCents(hz: Double, scalePCs: [Int], strength: Double) -> Double {
        guard hz > 0 else { return 0 }
        let target = Double(nearestScaleMidi(hz: hz, scalePCs: scalePCs))
        let current = 69.0 + 12.0 * log2(hz / 440.0)
        let full = (target - current) * 100.0
        return max(-1200, min(1200, full * max(0, min(1, strength))))
    }

    /// Per-hop cents corrections for a mono signal — the automation curve the render follows.
    /// Analysis runs on a ~8 kHz decimation (vocals are well under 1 kHz), which keeps the
    /// O(window·lag) YIN cost tractable in real time. Pure.
    static func correctionCurve(_ mono: [Float], sampleRate: Double, hop: Int, window: Int,
                                scalePCs: [Int], strength: Double) -> [Double] {
        guard hop > 0, mono.count > 0, sampleRate > 0 else { return [] }
        // Box-average decimate to ~8 kHz (crude anti-alias + downsample).
        let factor = max(1, Int(sampleRate / 8000))
        let dsRate = sampleRate / Double(factor)
        var ds = [Float](); ds.reserveCapacity(mono.count / factor + 1)
        var i = 0
        while i < mono.count {
            var acc: Float = 0, c = 0
            var j = i
            while j < min(mono.count, i + factor) { acc += mono[j]; c += 1; j += 1 }
            ds.append(acc / Float(max(1, c)))
            i += factor
        }
        let dsWindow = max(256, window / factor)
        let hops = (mono.count + hop - 1) / hop
        var curve = [Double](repeating: 0, count: hops)
        for k in 0..<hops {
            let dsStart = (k * hop) / factor
            let dsEnd = min(ds.count, dsStart + dsWindow)
            guard dsEnd - dsStart > 64 else { continue }
            if let hz = detectPitch(Array(ds[dsStart..<dsEnd]), sampleRate: dsRate) {
                curve[k] = correctionCents(hz: hz, scalePCs: scalePCs, strength: strength)
            }   // unvoiced/consonant frames stay at 0 (no bend)
        }
        return curve
    }

    // MARK: - Render

    /// Mix a buffer to a mono sample array.
    static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength), ch = Int(buffer.format.channelCount)
        var out = [Float](repeating: 0, count: n)
        for c in 0..<ch { let p = data[c]; for i in 0..<n { out[i] += p[i] } }
        if ch > 1 { let inv = 1 / Float(ch); for i in 0..<n { out[i] *= inv } }
        return out
    }

    /// Tune a clip's segment to `scalePCs`, rendering a new file. Pitch is corrected per hop via
    /// an offline AVAudioUnitTimePitch whose cents parameter follows the correction curve.
    static func tune(url: URL, offset: TimeInterval, duration: TimeInterval,
                     scalePCs: [Int], strength: Float, outputDir: URL) -> URL? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let sr = format.sampleRate
        let start = AVAudioFramePosition(offset * sr)
        let available = file.length - start
        guard available > 0 else { return nil }
        let frames = AVAudioFrameCount(min(available, AVAudioFramePosition(duration * sr)))
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        file.framePosition = start
        guard (try? file.read(into: input, frameCount: frames)) != nil else { return nil }

        let hop = 512, window = 2048
        let mono = monoSamples(input)
        let curve = correctionCurve(mono, sampleRate: sr, hop: hop, window: window,
                                    scalePCs: scalePCs, strength: Double(strength))

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(player); engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: AVAudioFrameCount(hop))
            try engine.start()
        } catch { return nil }
        player.scheduleBuffer(input, at: nil, options: [], completionHandler: nil)
        player.play()

        let out = outputDir.appendingPathComponent("\(UUID().uuidString)-tuned.caf")
        guard let outFile = try? AVAudioFile(forWriting: out, settings: format.settings),
              let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                             frameCapacity: AVAudioFrameCount(hop)) else {
            engine.stop(); return nil
        }
        let outFrames = AVAudioFramePosition(input.frameLength)
        var k = 0
        while engine.manualRenderingSampleTime < outFrames {
            timePitch.pitch = Float(curve.isEmpty ? 0 : curve[min(k, curve.count - 1)])
            let remaining = outFrames - engine.manualRenderingSampleTime
            let toRender = AVAudioFrameCount(min(Int64(hop), remaining))
            guard toRender > 0, let status = try? engine.renderOffline(toRender, to: scratch) else { break }
            if status == .success { try? outFile.write(from: scratch) } else if status == .error { break }
            k += 1
        }
        player.stop(); engine.stop()
        return out
    }
}
