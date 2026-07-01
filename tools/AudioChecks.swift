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

        // O) Compressor: a loud constant tone (above threshold) should come out lower than bypass.
        func renderComp(_ amount: Float, _ name: String) throws -> Float {
            var t = Track(name: name, colorIndex: 0); t.compress = amount
            t.clips = [Clip(asset: asset, startTime: 0.0)]
            let out = tmp.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            try AudioExporter.render(tracks: [t], duration: 2.0, to: out)
            return try rms(out, 0.5, 1.5)
        }
        let dry = try renderComp(0, "comp0.wav"), squashed = try renderComp(0.9, "comp9.wav")
        let compRatio = dry > 0 ? squashed / dry : 1
        print(String(format: "   (compressor: heavy/bypass RMS ratio %.3f)", compRatio))
        check("compressor reduces a loud tone", compRatio < 0.85)

        // P) AAC (.m4a) export: readable, right length, has audio.
        var aacTrack = Track(name: "AAC", colorIndex: 0); aacTrack.clips = [Clip(asset: asset, startTime: 0.0)]
        let outP = tmp.appendingPathComponent("p.m4a")
        try? FileManager.default.removeItem(at: outP)
        try AudioExporter.render(tracks: [aacTrack], duration: 2.0, to: outP, aac: true)
        let aacLen = try lengthSeconds(outP), aacBody = try rms(outP, 0.3, 1.7)
        print(String(format: "   (AAC export: %.3fs)", aacLen))
        check("AAC (m4a) export is readable + right length", abs(aacLen - 2.0) < 0.25 && aacBody > 0.1)

        // Q) Muted clip contributes silence.
        var muteTrack = Track(name: "MuteClip", colorIndex: 0)
        var muteClip = Clip(asset: asset, startTime: 0.0); muteClip.muted = true
        muteTrack.clips = [muteClip]
        let outQ = tmp.appendingPathComponent("q.wav")
        try? FileManager.default.removeItem(at: outQ)
        try AudioExporter.render(tracks: [muteTrack], duration: 2.0, to: outQ)
        check("muted clip → silence", try rms(outQ, 0, 2.0) < 0.001)

        // R) Silence detection (for Trim Silence): 0.5s silence, 1s tone, 0.5s silence.
        let paddedURL = tmp.appendingPathComponent("padded.wav")
        try writePaddedTone(to: paddedURL, silenceHead: 0.5, tone: 1.0, silenceTail: 0.5)
        let bounds = ClipProcessing.silenceBounds(url: paddedURL, offset: 0, duration: 2.0)
        print(String(format: "   (silence bounds: lead %.3fs, tail %.3fs)", bounds?.leading ?? -1, bounds?.trailing ?? -1))
        check("silence detection finds head + tail",
              bounds != nil && abs(bounds!.leading - 0.5) < 0.05 && abs(bounds!.trailing - 0.5) < 0.05)

        // S) Equal-power fade is louder mid-fade than linear (0.707 vs 0.5 at the midpoint).
        func fadeMidRMS(curve: Int, _ name: String) throws -> Float {
            var t = Track(name: name, colorIndex: 0)
            var clip = Clip(asset: asset, startTime: 0.0); clip.fadeIn = 1.0; clip.fadeCurve = curve
            t.clips = [clip]
            let out = tmp.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            try AudioExporter.render(tracks: [t], duration: 2.0, to: out)
            return try rms(out, 0.45, 0.55) // around the fade midpoint
        }
        let linMid = try fadeMidRMS(curve: 0, "fade-lin.wav"), eqMid = try fadeMidRMS(curve: 1, "fade-eq.wav")
        let fadeRatio = linMid > 0 ? eqMid / linMid : 0
        print(String(format: "   (equal-power / linear mid-fade ratio: %.2f, expect ~1.41)", fadeRatio))
        check("equal-power fade is louder mid-fade than linear", fadeRatio > 1.2)

        // T) Bounce bakes a track's volume (bounce == single-track offline render).
        func trackVolRMS(_ vol: Float, _ name: String) throws -> Float {
            var t = Track(name: name, colorIndex: 0); t.volume = vol
            t.clips = [Clip(asset: asset, startTime: 0.0)]
            let out = tmp.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: out)
            try AudioExporter.render(tracks: [t], duration: 2.0, to: out)
            return try rms(out, 0.2, 1.8)
        }
        let vFull = try trackVolRMS(1.0, "vol-full.wav"), vHalf = try trackVolRMS(0.5, "vol-half.wav")
        let volRatio = vFull > 0 ? vHalf / vFull : 0
        print(String(format: "   (half/full track-volume ratio: %.2f, expect ~0.5)", volRatio))
        check("track volume bakes into bounce/export", volRatio > 0.4 && volRatio < 0.6)

        // T2) LUFS loudness: a 0.5-amplitude tone reads a sane integrated LUFS + peak ≈ -6 dBFS.
        let lufs = Loudness.integratedLUFS(url: toneURL)
        let peakDB = Loudness.peakDBFS(url: toneURL)
        print(String(format: "   (loudness: %@ LUFS, peak %@ dBFS)",
                     lufs.map { String(format: "%.1f", $0) } ?? "nil",
                     peakDB.map { String(format: "%.1f", $0) } ?? "nil"))
        check("integrated LUFS + peak are sane",
              lufs != nil && lufs! > -16 && lufs! < -4
                  && peakDB != nil && abs(peakDB! - (-6.02)) < 0.6)

        // U) Pitch shift raises/lowers the fundamental (zero-crossing rate tracks pitch).
        let zcBase = try zeroCrossings(toneURL, 0.5, 1.5)
        let upURL = ClipProcessing.pitchShift(url: toneURL, offset: 0, duration: 2.0, semitones: 12, outputDir: tmp)
        let downURL = ClipProcessing.pitchShift(url: toneURL, offset: 0, duration: 2.0, semitones: -12, outputDir: tmp)
        let zcUp = (try? upURL.map { try zeroCrossings($0, 0.5, 1.5) } ?? 0) ?? 0
        let zcDown = (try? downURL.map { try zeroCrossings($0, 0.5, 1.5) } ?? 0) ?? 0
        print(String(format: "   (zero-crossings: base %d, +12st %d, -12st %d)", zcBase, zcUp, zcDown))
        check("pitch up raises the fundamental", Double(zcUp) > Double(zcBase) * 1.5)
        check("pitch down lowers the fundamental", zcDown > 0 && Double(zcDown) < Double(zcBase) * 0.7)

        // V) Normalize-on-export lifts a quiet mix to ≈ target peak.
        var quietTrack = Track(name: "Quiet", colorIndex: 0)
        var quietClip = Clip(asset: asset, startTime: 0.0); quietClip.gain = 0.5
        quietTrack.clips = [quietClip]; quietTrack.volume = 1.0
        let outV = tmp.appendingPathComponent("v.wav")
        try? FileManager.default.removeItem(at: outV)
        try AudioExporter.render(tracks: [quietTrack], duration: 2.0, to: outV)
        let beforePeak = try peakOf(outV)
        try AudioExporter.normalizeFile(at: outV)
        let afterPeak = try peakOf(outV)
        print(String(format: "   (normalize peak: %.3f → %.3f, target ~0.89)", beforePeak, afterPeak))
        check("normalize lifts a quiet mix to ~target peak", beforePeak < 0.6 && abs(afterPeak - 0.89) < 0.05)

        // W) MIDI instrument track renders a note (built-in DLS synth), at the right time.
        var midiTrack = Track(name: "MIDI", colorIndex: 0)
        midiTrack.isInstrument = true
        midiTrack.notes = [MIDINote(pitch: 60, start: 0.5, duration: 1.0, velocity: 110)]
        let outW = tmp.appendingPathComponent("midi.wav")
        try? FileManager.default.removeItem(at: outW)
        try AudioExporter.render(tracks: [midiTrack], duration: 2.0, to: outW)
        let midiHead = try rms(outW, 0.0, 0.4), midiBody = try rms(outW, 0.6, 1.4)
        print(String(format: "   (MIDI render: head %.4f, note %.4f)", midiHead, midiBody))
        check("MIDI instrument renders a note at the right time", midiBody > 0.005 && midiHead < midiBody * 0.4)

        // W2) Drum-kit note renders via channel 9 (GM drum map).
        var drumTrack = Track(name: "Drums", colorIndex: 0)
        drumTrack.isInstrument = true; drumTrack.isDrumKit = true
        drumTrack.notes = [MIDINote(pitch: 36, start: 0.5, duration: 0.2, velocity: 120)]   // kick
        let outW2 = tmp.appendingPathComponent("drum.wav")
        try? FileManager.default.removeItem(at: outW2)
        try AudioExporter.render(tracks: [drumTrack], duration: 1.5, to: outW2)
        let drumHead = try rms(outW2, 0.0, 0.4), drumBody = try rms(outW2, 0.5, 0.9)
        print(String(format: "   (drum render: head %.4f, hit %.4f)", drumHead, drumBody))
        check("drum kit renders on channel 9", drumBody > 0.005 && drumHead < drumBody * 0.5)

        // W3) Arpeggiator: a C-major chord (1s) at 1/4 rate → 4 cycling single notes.
        let chord = [MIDINote(pitch: 60, start: 0, duration: 1.0),
                     MIDINote(pitch: 64, start: 0, duration: 1.0),
                     MIDINote(pitch: 67, start: 0, duration: 1.0)]
        let arp = arpeggiate(chord, rate: 0.25, pattern: .up)
        let arpPitches = arp.map(\.pitch)
        print("   (arp pitches: \(arpPitches))")
        check("arpeggiator cycles chord pitches at the rate",
              arp.count == 4 && arpPitches == [60, 64, 67, 60]
                  && abs(arp[1].start - 0.25) < 0.001)

        // W4) Chord generator: C-major I chord = C-E-G (60-64-67); A-minor i = A-C-E.
        let cMajorI = chordProgression(root: 0, scale: .major, degrees: [0], barDuration: 2.0, octave: 4)
        let aMinorI = chordProgression(root: 9, scale: .minor, degrees: [0], barDuration: 2.0, octave: 4)
        print("   (C maj I: \(cMajorI.map(\.pitch)), A min i: \(aMinorI.map(\.pitch)))")
        check("chord generator builds correct triads",
              cMajorI.map(\.pitch) == [60, 64, 67] && aMinorI.map(\.pitch) == [69, 72, 76])

        // W8) Scale lock: in C major, C#(61)→C(60) or D(62); E(64) stays; A minor snaps too.
        let cSharpSnap = snapToScale(61, root: 0, scale: .major)   // C# → nearest white key
        print("   (scale snap: C#→\(cSharpSnap), E→\(snapToScale(64, root: 0, scale: .major)))")
        check("scale lock snaps to the key",
              (cSharpSnap == 60 || cSharpSnap == 62)                // C# → C or D
                  && snapToScale(64, root: 0, scale: .major) == 64  // E stays
                  && snapToScale(61, root: 9, scale: .minor) == 60) // C# in A-minor → C

        // W9) Humanize nudges timing/velocity within bounds, deterministically per seed.
        let straight = [MIDINote(pitch: 60, start: 1.0, duration: 0.5, velocity: 100),
                        MIDINote(pitch: 62, start: 2.0, duration: 0.5, velocity: 100)]
        let human = humanize(straight, timing: 0.02, velocity: 10, seed: 42)
        let inBounds = zip(straight, human).allSatisfy {
            abs($0.start - $1.start) <= 0.0201 && abs($0.velocity - $1.velocity) <= 10
                && $1.velocity >= 1 && $1.velocity <= 127
        }
        let changed = zip(straight, human).contains { $0.start != $1.start || $0.velocity != $1.velocity }
        let deterministic = humanize(straight, timing: 0.02, velocity: 10, seed: 42).map(\.start) == human.map(\.start)
        check("humanize varies notes within bounds (seeded)", inBounds && changed && deterministic)

        // W10) MIDI file round-trip: write notes → read back → same pitches + ~same timing.
        let midiNotes = [MIDINote(pitch: 60, start: 0.0, duration: 0.5, velocity: 100),
                         MIDINote(pitch: 64, start: 0.5, duration: 0.5, velocity: 90),
                         MIDINote(pitch: 67, start: 1.0, duration: 1.0, velocity: 110)]
        let midiData = MIDIFile.write(notes: midiNotes, tempo: 120)
        let readBack = MIDIFile.read(midiData)
        let rbPitches = readBack?.notes.map(\.pitch) ?? []
        print("   (MIDI round-trip: \(rbPitches), tempo \(readBack.map { String(format: "%.0f", $0.tempo) } ?? "nil"))")
        check("MIDI file round-trips notes + tempo",
              readBack != nil && rbPitches == [60, 64, 67]
                  && abs((readBack!.tempo) - 120) < 1
                  && abs((readBack!.notes[2].start) - 1.0) < 0.01
                  && abs((readBack!.notes[2].duration) - 1.0) < 0.02)

        // W5) Musical typing maps the keyboard to MIDI (A=C4=60, J=B4=71 at octave 4).
        let mtA = MusicalTyping.pitch(keyCode: 0, octave: 4)     // A → C4
        let mtJ = MusicalTyping.pitch(keyCode: 38, octave: 4)    // J → B4
        let mtAup = MusicalTyping.pitch(keyCode: 0, octave: 5)   // A at octave 5 → C5
        print("   (musical typing: A=\(mtA ?? -1), J=\(mtJ ?? -1), A@oct5=\(mtAup ?? -1))")
        check("musical typing maps keys to MIDI pitches",
              mtA == 60 && mtJ == 71 && mtAup == 72 && MusicalTyping.pitch(keyCode: 99, octave: 4) == nil)

        // W6) Drum preset: "Four on the Floor" puts a kick on each beat.
        let fourFloor = DrumPatterns.all.first { $0.name == "Four on the Floor" }!
        let beat = DrumPatterns.notes(fourFloor, bars: 1, stepDur: 0.1)
        let kicks = beat.filter { $0.pitch == 36 }.map(\.start).sorted()
        print("   (four-on-floor kicks at: \(kicks))")
        check("drum preset lays a kick on every beat",
              kicks.count == 4 && abs(kicks[1] - 0.4) < 0.001 && abs(kicks[3] - 1.2) < 0.001)

        // W7) Tempo-matched loops: a 120-BPM loop into a 140-BPM project speeds up (rate ~1.17).
        let fit = loopFitRate(loopBPM: 120, projectBPM: 140)
        print("   (loop fit rate 120→140: \(fit.map { String(format: "%.3f", $0) } ?? "nil"))")
        check("loop fit rate matches tempo ratio",
              fit != nil && abs(fit! - 1.1667) < 0.01
                  && loopFitRate(loopBPM: 120, projectBPM: 120) == nil
                  && loopFitRate(loopBPM: nil, projectBPM: 140) == nil)

        // W8) Tempo track: constant tempo lays even beats; a step change halves the spacing.
        let evenBeats = beatTimes(base: 120, points: [], until: 2.0)   // expect 0,0.5,1.0,1.5,2.0
        let evenOK = evenBeats.count == 5 && zip(evenBeats, [0, 0.5, 1.0, 1.5, 2.0]).allSatisfy { abs($0 - $1) < 1e-6 }
        // 120 BPM until t=1 (beats at 0,0.5,1.0), then 240 BPM (beats at 1.25,1.5,1.75,2.0).
        let stepBeats = beatTimes(base: 120, points: [TempoPoint(time: 1.0, bpm: 240)], until: 2.0)
        let stepOK = zip(stepBeats.suffix(4), [1.25, 1.5, 1.75, 2.0]).allSatisfy { abs($0 - $1) < 1e-6 }
        print("   (tempo map step beats: \(stepBeats.map { String(format: "%.2f", $0) }.joined(separator: ",")))")
        check("tempo track integrates step tempo changes", evenOK && stepOK
                  && abs(tempoAt(1.5, base: 120, points: [TempoPoint(time: 1.0, bpm: 240)]) - 240) < 1e-6)

        // W9) Take folder: a 6.2s cycle recording over a 2s loop → one take per pass.
        let tw = cycleTakeWindows(recorded: 6.2, loopLength: 2.0)
        let twOK = tw.count == 3 && tw.map(\.offset) == [0, 2, 4] && tw.allSatisfy { abs($0.duration - 2) < 1e-6 }
        let shortTake = cycleTakeWindows(recorded: 0.4, loopLength: 2.0)   // under half a pass → nothing
        print("   (cycle takes 6.2/2.0: offsets \(tw.map { String(format: "%.0f", $0.offset) }.joined(separator: ",")))")
        check("cycle recording splits into one take per pass", twOK && shortTake.isEmpty)

        // W10) Drummer: complexity adds density, output is deterministic, fills drop toms.
        let simpleKit = drummerPerformance(DrummerSettings(style: 3, complexity: 0, intensity: 0.7, swing: 0, fillEvery: 0),
                                           bars: 2, stepDur: 0.125, seed: 7)
        let busyKit = drummerPerformance(DrummerSettings(style: 3, complexity: 1, intensity: 0.9, swing: 0.3, fillEvery: 0),
                                         bars: 2, stepDur: 0.125, seed: 7)
        let busyAgain = drummerPerformance(DrummerSettings(style: 3, complexity: 1, intensity: 0.9, swing: 0.3, fillEvery: 0),
                                           bars: 2, stepDur: 0.125, seed: 7)
        let filled = drummerPerformance(DrummerSettings(style: 3, complexity: 0.8, intensity: 0.8, swing: 0, fillEvery: 2),
                                        bars: 2, stepDur: 0.125, seed: 7)
        let fillInBar2 = filled.contains { [45, 48, 50].contains($0.pitch) && $0.start >= 2.0 }
        let sameEachRun = busyKit.map(\.pitch) == busyAgain.map(\.pitch) && busyKit.map(\.start) == busyAgain.map(\.start)
        print("   (drummer density: simple \(simpleKit.count) → busy \(busyKit.count), fill \(fillInBar2))")
        check("drummer scales density, stays deterministic, and lays fills",
              busyKit.count > simpleKit.count && sameEachRun && fillInBar2)

        // X) Volume automation (1 → 0 over the clip) fades the export out.
        var autoTrack = Track(name: "Auto", colorIndex: 0)
        autoTrack.clips = [Clip(asset: asset, startTime: 0.0)]
        autoTrack.volume = 1.0
        autoTrack.volumeAutomation = [AutomationPoint(time: 0, value: 1.0),
                                      AutomationPoint(time: 2.0, value: 0.0)]
        let outX = tmp.appendingPathComponent("auto.wav")
        try? FileManager.default.removeItem(at: outX)
        try AudioExporter.render(tracks: [autoTrack], duration: 2.0, to: outX)
        let early = try rms(outX, 0.1, 0.4), late = try rms(outX, 1.6, 1.9)
        print(String(format: "   (volume automation: early %.3f, late %.3f)", early, late))
        check("volume automation fades the mix down", early > 0.1 && late < early * 0.3)

        // Y) Plugin host: audio still flows through an inserted Audio Unit (chain wiring).
        var pluginTrack = Track(name: "Plugin", colorIndex: 0)
        pluginTrack.clips = [Clip(asset: asset, startTime: 0.0)]
        // Apple's built-in lowpass effect, inserted as a plugin (default cutoff passes 440 Hz).
        pluginTrack.plugins = [PluginRef(name: "AULowpass",
                                         type: kAudioUnitType_Effect,
                                         subType: kAudioUnitSubType_LowPassFilter,
                                         manufacturer: kAudioUnitManufacturer_Apple)]
        let outY = tmp.appendingPathComponent("plugin.wav")
        try? FileManager.default.removeItem(at: outY)
        try AudioExporter.render(tracks: [pluginTrack], duration: 2.0, to: outY)
        let pluginBody = try rms(outY, 0.3, 1.7)
        print(String(format: "   (plugin chain: body %.3f)", pluginBody))
        check("audio flows through an inserted Audio Unit plugin", pluginBody > 0.05)

        // Z) Imported names drop the "<uuid>-" library prefix.
        let uuidName = URL(fileURLWithPath: "/x/\(UUID().uuidString)-My Song.wav")
        let plainName = URL(fileURLWithPath: "/x/My Song.wav")
        let cleaned = AudioAsset.displayName(for: uuidName)
        print("   (display name: '\(cleaned)')")
        check("imported display name strips the uuid prefix",
              cleaned == "My Song" && AudioAsset.displayName(for: plainName) == "My Song")

        // AA) Master volume scales the final mixdown.
        var mvTrack = Track(name: "MV", colorIndex: 0); mvTrack.volume = 1.0
        mvTrack.clips = [Clip(asset: asset, startTime: 0.0)]
        let mvFull = tmp.appendingPathComponent("mv1.wav"), mvHalf = tmp.appendingPathComponent("mv05.wav")
        try? FileManager.default.removeItem(at: mvFull); try? FileManager.default.removeItem(at: mvHalf)
        try AudioExporter.render(tracks: [mvTrack], duration: 2.0, to: mvFull, masterVolume: 1.0)
        try AudioExporter.render(tracks: [mvTrack], duration: 2.0, to: mvHalf, masterVolume: 0.5)
        let mvRatio = try rms(mvFull, 0.2, 1.8) > 0 ? rms(mvHalf, 0.2, 1.8) / rms(mvFull, 0.2, 1.8) : 0
        print(String(format: "   (master 0.5/1.0 ratio: %.2f)", mvRatio))
        check("master volume scales the mixdown", mvRatio > 0.4 && mvRatio < 0.6)

        // AB) Sidechain ducking: gain dips during a trigger hit, recovers after.
        let trigURL = tmp.appendingPathComponent("trigger.wav")
        try writePaddedTone(to: trigURL, silenceHead: 0.4, tone: 0.2, silenceTail: 0.8)
        let duck = Sidechain.duckingPoints(triggerURL: trigURL, depth: 0.8, release: 0.15)
        func duckGain(at t: Double) -> Float {
            // step-sample the generated breakpoints
            var v: Float = 1
            for p in duck where p.time <= t { v = p.value }
            return v
        }
        let duringHit = duckGain(at: 0.5), afterHit = duckGain(at: 1.3)
        print(String(format: "   (sidechain gain: during-hit %.2f, after %.2f)", duringHit, afterHit))
        check("sidechain ducks during the trigger, recovers after",
              !duck.isEmpty && duringHit < 0.5 && afterHit > 0.85)

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

    static func writePaddedTone(to url: URL, silenceHead: Double, tone: Double, silenceTail: Double,
                                sampleRate: Double = 44_100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let total = silenceHead + tone + silenceTail
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(total * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        let headEnd = Int(silenceHead * sampleRate), toneEnd = Int((silenceHead + tone) * sampleRate)
        for i in 0..<Int(frames) {
            ch[i] = (i >= headEnd && i < toneEnd)
                ? Float(sin(2 * .pi * 440 * Double(i) / sampleRate)) * 0.5 : 0
        }
        try file.write(from: buffer)
    }

    /// Count sign changes on channel 0 over [a, b] seconds — a cheap fundamental-pitch proxy.
    static func zeroCrossings(_ url: URL, _ a: Double, _ b: Double) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sr = format.sampleRate
        let start = AVAudioFramePosition(a * sr)
        let frames = AVAudioFrameCount((b - a) * sr)
        guard frames > 0, start < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        file.framePosition = start
        try file.read(into: buffer, frameCount: frames)
        guard let p = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        var count = 0, prev: Float = 0
        for i in 0..<n {
            let s = p[i]
            if i > 0 && ((prev < 0 && s >= 0) || (prev > 0 && s <= 0)) { count += 1 }
            prev = s
        }
        return count
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

    /// Absolute peak across the whole file (all channels).
    static func peakOf(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return 0 }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        for c in 0..<Int(format.channelCount) { let p = data[c]; for i in 0..<n { let a = abs(p[i]); if a > peak { peak = a } } }
        return peak
    }
}
