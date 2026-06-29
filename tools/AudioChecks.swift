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
