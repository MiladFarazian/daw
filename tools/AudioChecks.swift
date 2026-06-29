import AVFoundation

// Headless behavioral checks for the audio core (offline export) and the project
// document format. Compiled against the real Gosan sources via `make verify`.
// Offline rendering needs no audio hardware, so this runs anywhere (incl. CI).
@main
struct AudioChecks {
    static func main() throws {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL")  \(name)")
            if !condition { failures += 1 }
        }

        let tmp = FileManager.default.temporaryDirectory
        let toneURL = tmp.appendingPathComponent("gosan-tone.wav")
        try writeTone(to: toneURL, freq: 440, seconds: 2.0)
        let asset = AudioAsset(url: toneURL, duration: 2.0, sampleRate: 44_100, peaks: [])

        // A) Placement: clip at 0.5s on a 2.5s timeline.
        var a = Track(name: "A", colorIndex: 0)
        a.clips = [Clip(asset: asset, startTime: 0.5)]
        let outA = tmp.appendingPathComponent("a.wav")
        try? FileManager.default.removeItem(at: outA)
        try AudioExporter.render(tracks: [a], duration: 2.5, to: outA)
        let aLen = try lengthSeconds(outA), aPre = try rms(outA, 0, 0.4), aIn = try rms(outA, 1.0, 2.0)
        check("export placement + length + level", abs(aLen - 2.5) < 0.05 && aPre < 0.01 && aIn > 0.1)

        // B) Trim: offset 1.0s into the source, duration 0.5s.
        var b = Track(name: "B", colorIndex: 0)
        var bc = Clip(asset: asset, startTime: 0.0); bc.offset = 1.0; bc.duration = 0.5
        b.clips = [bc]
        let outB = tmp.appendingPathComponent("b.wav")
        try? FileManager.default.removeItem(at: outB)
        try AudioExporter.render(tracks: [b], duration: 0.5, to: outB)
        let bLen = try lengthSeconds(outB), bIn = try rms(outB, 0.05, 0.45)
        check("export trim (offset + duration)", abs(bLen - 0.5) < 0.05 && bIn > 0.1)

        // C) Mute: a muted track must contribute silence.
        var c = Track(name: "C", colorIndex: 0); c.isMuted = true
        c.clips = [Clip(asset: asset, startTime: 0.0)]
        let outC = tmp.appendingPathComponent("c.wav")
        try? FileManager.default.removeItem(at: outC)
        try AudioExporter.render(tracks: [c], duration: 1.0, to: outC)
        check("export mute -> silence", try rms(outC, 0, 1.0) < 0.001)

        // D) Project document Codable round-trip.
        let doc = ProjectDocument(name: "Demo", tempo: 128, pixelsPerSecond: 90, tracks: [
            .init(name: "T", colorIndex: 2, volume: 0.7, pan: 0.2, isMuted: false, isSoloed: true,
                  clips: [.init(assetFile: "x.wav", assetName: "x", sampleRate: 44_100,
                                assetDuration: 3.0, startTime: 1.0, offset: 0.25, duration: 2.0)])
        ])
        let decoded = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        check("project save/load round-trip",
              decoded.name == "Demo" && decoded.tempo == 128 && decoded.tracks.first?.isSoloed == true
              && decoded.tracks.first?.clips.first?.offset == 0.25
              && decoded.tracks.first?.clips.first?.duration == 2.0)

        // E) Portable package: bundles audio + round-trips the document.
        let pkg = tmp.appendingPathComponent("Demo.gosan")
        try? FileManager.default.removeItem(at: pkg)
        try ProjectPackage.write(doc, assetURLs: ["tone.wav": toneURL], to: pkg)
        let (readDoc, audioDir) = try ProjectPackage.read(pkg)
        let bundled = FileManager.default.fileExists(atPath: audioDir.appendingPathComponent("tone.wav").path)
        check("portable package bundles audio + round-trips", bundled && readDoc.name == "Demo")

        // F) Split: the two halves (matching what splitClipAtPlayhead produces) export to
        //    continuous audio across the cut point.
        var split = Track(name: "Split", colorIndex: 0)
        var left = Clip(asset: asset, startTime: 0.0); left.offset = 0; left.duration = 1.0
        var right = Clip(asset: asset, startTime: 1.0); right.offset = 1.0; right.duration = 1.0
        split.clips = [left, right]
        let outF = tmp.appendingPathComponent("f.wav")
        try? FileManager.default.removeItem(at: outF)
        try AudioExporter.render(tracks: [split], duration: 2.0, to: outF)
        let fLen = try lengthSeconds(outF), fEarly = try rms(outF, 0.1, 0.9), fLate = try rms(outF, 1.1, 1.9)
        check("split halves export to continuous audio", abs(fLen - 2.0) < 0.05 && fEarly > 0.1 && fLate > 0.1)

        // G) Fade-in: the clip head should ramp up (quiet start, full body).
        var fadeTrack = Track(name: "Fade", colorIndex: 0)
        var fadeClip = Clip(asset: asset, startTime: 0.0); fadeClip.fadeIn = 0.5
        fadeTrack.clips = [fadeClip]
        let outG = tmp.appendingPathComponent("g.wav")
        try? FileManager.default.removeItem(at: outG)
        try AudioExporter.render(tracks: [fadeTrack], duration: 2.0, to: outG)
        let gEarly = try rms(outG, 0.0, 0.1), gFull = try rms(outG, 1.0, 1.5)
        check("fade-in ramps up (quiet head, full body)", gEarly < gFull * 0.4 && gFull > 0.1)

        // H) Clip gain: render at 1.0x and 0.5x and check the ratio is ~half (robust to
        //    any constant mono→stereo scaling).
        func renderGain(_ g: Float, _ name: String) throws -> Float {
            var t = Track(name: name, colorIndex: 0)
            var clip = Clip(asset: asset, startTime: 0.0); clip.gain = g
            t.clips = [clip]
            let out = tmp.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            try AudioExporter.render(tracks: [t], duration: 2.0, to: out)
            return try rms(out, 0.2, 1.8)
        }
        let full = try renderGain(1.0, "h1.wav"), half = try renderGain(0.5, "h05.wav")
        let ratio = full > 0 ? half / full : 0
        check("clip gain 0.5x halves the level", ratio > 0.45 && ratio < 0.55)

        // I) Per-track reverb: a 1s clip with reverb should ring out after it ends.
        var revTrack = Track(name: "Rev", colorIndex: 0); revTrack.reverb = 0.8
        var revClip = Clip(asset: asset, startTime: 0.0); revClip.duration = 1.0
        revTrack.clips = [revClip]
        let outI = tmp.appendingPathComponent("i.wav")
        try? FileManager.default.removeItem(at: outI)
        try AudioExporter.render(tracks: [revTrack], duration: 3.0, to: outI)
        let dryTail = try rms(outI, 1.3, 2.5) // (with reverb this should be non-zero)
        print(String(format: "   (reverb tail RMS after clip end: %.4f)", dryTail))
        check("reverb rings out after the clip", dryTail > 0.004)

        // J) Per-track delay: a 1s clip with delay should echo after it ends.
        var delTrack = Track(name: "Del", colorIndex: 0); delTrack.delay = 0.6
        var delClip = Clip(asset: asset, startTime: 0.0); delClip.duration = 1.0
        delTrack.clips = [delClip]
        let outJ = tmp.appendingPathComponent("j.wav")
        try? FileManager.default.removeItem(at: outJ)
        try AudioExporter.render(tracks: [delTrack], duration: 3.0, to: outJ)
        let echo = try rms(outJ, 1.2, 2.0)
        print(String(format: "   (delay echo RMS after clip end: %.4f)", echo))
        check("delay echoes after the clip", echo > 0.02)

        // K) Peak analysis used by Normalize (the tone's amplitude is 0.5).
        let pk = ClipProcessing.peak(url: toneURL, offset: 0, duration: 2.0) ?? 0
        check("peak analysis (~0.5)", abs(pk - 0.5) < 0.03)

        // L) Reverse mirrors the envelope: a quiet→loud ramp becomes loud→quiet.
        let rampURL = tmp.appendingPathComponent("ramp.wav")
        try writeRamp(to: rampURL, seconds: 2.0)
        let revURL = ClipProcessing.reverse(url: rampURL, offset: 0, duration: 2.0, outputDir: tmp)
        let revEarly = revURL != nil ? try rms(revURL!, 0.1, 0.8) : 0
        let revLate = revURL != nil ? try rms(revURL!, 1.2, 1.9) : 0
        check("reverse mirrors the envelope (loud→quiet)", revURL != nil && revEarly > revLate * 1.5)

        // M) Range export (loop bounce): a clip 0.5–2.5s, exported from 0.5s for 2s, fills the file.
        var rangeTrack = Track(name: "Range", colorIndex: 0)
        rangeTrack.clips = [Clip(asset: asset, startTime: 0.5)]
        let outM = tmp.appendingPathComponent("m.wav")
        try? FileManager.default.removeItem(at: outM)
        try AudioExporter.render(tracks: [rangeTrack], duration: 2.0, to: outM, from: 0.5)
        let mLen = try lengthSeconds(outM), mStart = try rms(outM, 0.0, 0.2), mBody = try rms(outM, 0.5, 1.5)
        check("range export (from offset) bounces the right window",
              abs(mLen - 2.0) < 0.05 && mStart > 0.1 && mBody > 0.1)

        // N) Time-stretch: a 1s segment at 0.5× speed should become ~2s, tone still present.
        let stretched = ClipProcessing.timeStretch(url: toneURL, offset: 0, duration: 1.0, rate: 0.5, outputDir: tmp)
        var stLen = 0.0, stBody: Float = 0
        if let s = stretched { stLen = try lengthSeconds(s); stBody = try rms(s, 0.8, 1.4) }
        print(String(format: "   (time-stretch 0.5x: 1.0s → %.3fs)", stLen))
        check("time-stretch 0.5x doubles the length", stretched != nil && abs(stLen - 2.0) < 0.2 && stBody > 0.1)

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        if failures > 0 { exit(1) }
    }

    // MARK: helpers

    static func writeTone(to url: URL, freq: Double, seconds: Double, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) { ch[i] = Float(sin(2 * .pi * freq * Double(i) / sampleRate)) * 0.5 }
        try file.write(from: buffer)
    }

    static func writeRamp(to url: URL, seconds: Double, sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let env = Float(i) / Float(frames) * 0.8 // 0 → 0.8
            ch[i] = env * Float(sin(2 * .pi * 440 * Double(i) / sampleRate))
        }
        try file.write(from: buffer)
    }

    static func rms(_ url: URL, _ a: Double, _ b: Double) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let sr = f.processingFormat.sampleRate
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let data = buf.floatChannelData![0]; let n = Int(buf.frameLength)
        let lo = max(0, min(n, Int(a * sr))), hi = max(0, min(n, Int(b * sr)))
        guard hi > lo else { return 0 }
        var s: Float = 0; for i in lo..<hi { s += data[i] * data[i] }
        return (s / Float(hi - lo)).squareRoot()
    }

    static func lengthSeconds(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
