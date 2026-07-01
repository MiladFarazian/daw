import Foundation

/// A decoded audio file plus a downsampled peak envelope for waveform drawing.
/// Reference type so clips can share the same underlying asset cheaply.
final class AudioAsset: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let duration: TimeInterval
    let sampleRate: Double
    var peaks: [Float]

    init(url: URL, duration: TimeInterval, sampleRate: Double, peaks: [Float]) {
        self.url = url
        self.name = AudioAsset.displayName(for: url)
        self.duration = duration
        self.sampleRate = sampleRate
        self.peaks = peaks
    }

    /// Library files are stored as "<uuid>-<original>". Strip the uuid prefix for display.
    static func displayName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base.count > 37 {
            let split = base.index(base.startIndex, offsetBy: 36)
            if base[split] == "-", UUID(uuidString: String(base[..<split])) != nil {
                return String(base[base.index(after: split)...])
            }
        }
        return base
    }
}

/// A placement of an asset on a track's timeline.
struct Clip: Identifiable {
    let id = UUID()
    var asset: AudioAsset
    var startTime: TimeInterval = 0   // position on the timeline
    var offset: TimeInterval = 0      // trim in from the asset's head
    var duration: TimeInterval        // visible length (≤ asset.duration - offset)
    var fadeIn: TimeInterval = 0      // fade-in length from the clip's head
    var fadeOut: TimeInterval = 0     // fade-out length to the clip's tail
    var fadeCurve = 0                 // 0 = linear, 1 = equal-power
    var gain: Float = 1.0             // linear clip gain
    var muted = false
    var customName: String?           // user-set name; falls back to the asset name

    // Take folder: alternate performances of this region (cycle-record stacks passes here).
    // Empty = a plain single-take clip. The active take's offset/duration are mirrored into
    // this clip's `offset`/`duration`, so playback and export read the active take for free.
    var takes: [Take] = []
    var activeTake: Int = 0
    var hasTakes: Bool { takes.count > 1 }

    var name: String { customName ?? asset.name }

    init(asset: AudioAsset, startTime: TimeInterval = 0) {
        self.asset = asset
        self.startTime = startTime
        self.offset = 0
        self.duration = asset.duration
    }
}

/// One recorded performance inside a take folder. Takes from a single cycle-record pass
/// share the clip's underlying `asset` and differ only by `offset` into that file.
struct Take: Identifiable {
    let id = UUID()
    var offset: TimeInterval
    var duration: TimeInterval
    var name: String
}

/// Split a continuous cycle recording of `recorded` seconds into equal takes of
/// `loopLength` each. A pass counts if at least half of it was captured. Pure.
func cycleTakeWindows(recorded: TimeInterval, loopLength: TimeInterval) -> [Take] {
    guard loopLength > 0.05, recorded > 0.05 else { return [] }
    var takes: [Take] = []
    var offset = 0.0
    while offset + loopLength * 0.5 <= recorded {
        takes.append(Take(offset: offset, duration: min(loopLength, recorded - offset),
                          name: "Take \(takes.count + 1)"))
        offset += loopLength
    }
    return takes
}

/// A named position on the timeline.
struct Marker: Identifiable, Codable {
    var id = UUID()
    var time: TimeInterval
    var name: String
}

/// A MIDI note on an instrument track. Times are in seconds on the timeline.
struct MIDINote: Identifiable, Equatable {
    let id = UUID()
    var pitch: Int                  // 0...127 (60 = middle C)
    var start: TimeInterval
    var duration: TimeInterval
    var velocity: Int = 100         // 1...127
}

/// A breakpoint in an automation envelope (value is parameter-specific).
struct AutomationPoint: Identifiable, Equatable {
    let id = UUID()
    var time: TimeInterval
    var value: Float
}

/// An installed Audio Unit effect inserted on a track.
struct PluginRef: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32
    var stateData: Data?            // archived full-state (kAudioUnitProperty_ClassInfo)
}

/// One row in the timeline: a group header or a track lane (so the header column
/// and the lane area iterate the same list and stay aligned).
enum TimelineRow: Identifiable {
    case group(TrackGroup)
    case track(Track)

    var id: String {
        switch self {
        case .group(let g): return "g-\(g.id.uuidString)"
        case .track(let t): return "t-\(t.id.uuidString)"
        }
    }
}

/// A folder grouping several tracks, with bus-style controls.
struct TrackGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var colorIndex: Int
    var collapsed = false
    var volume: Float = 1.0   // multiplies member volumes
    var muted = false
    var soloed = false

    init(id: UUID = UUID(), name: String, colorIndex: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
    }
}

/// One horizontal lane with its own mixer settings.
struct Track: Identifiable {
    let id = UUID()
    var name: String
    var colorIndex: Int
    var groupID: UUID?
    var volume: Float = 0.8
    var pan: Float = 0
    var reverb: Float = 0        // 0...1 reverb send
    var delay: Float = 0         // 0...1 delay send
    var compress: Float = 0      // 0...1 compression amount
    var eqLow: Float = 0         // dB
    var eqMid: Float = 0         // dB
    var eqHigh: Float = 0        // dB
    var isMuted = false
    var isSoloed = false
    var clips: [Clip] = []

    // Instrument (MIDI) tracks
    var isInstrument = false
    var isDrumKit = false        // GM drum map on MIDI channel 9 (for the step sequencer)
    var program: Int = 0         // General-MIDI program (0 = grand piano)
    var instrumentPlugin: PluginRef?   // an AU instrument to use instead of the built-in GM synth
    var notes: [MIDINote] = []

    var midiChannel: UInt8 { isDrumKit ? 9 : 0 }

    // Automation envelopes (empty = no automation; values 0...1 for volume, -1...1 for pan)
    var volumeAutomation: [AutomationPoint] = []
    var panAutomation: [AutomationPoint] = []
    var reverbAutomation: [AutomationPoint] = []   // 0...1 reverb send
    var delayAutomation: [AutomationPoint] = []    // 0...1 delay send
    var eqLowAutomation: [AutomationPoint] = []    // dB
    var eqMidAutomation: [AutomationPoint] = []    // dB
    var eqHighAutomation: [AutomationPoint] = []   // dB

    var hasAutomation: Bool {
        !volumeAutomation.isEmpty || !panAutomation.isEmpty || !reverbAutomation.isEmpty
            || !delayAutomation.isEmpty || !eqLowAutomation.isEmpty
            || !eqMidAutomation.isEmpty || !eqHighAutomation.isEmpty
    }

    // Insert effects (Audio Unit plugins), in chain order
    var plugins: [PluginRef] = []

    var endTime: TimeInterval {
        let clipEnd = clips.map { $0.startTime + $0.duration }.max() ?? 0
        let noteEnd = notes.map { $0.start + $0.duration }.max() ?? 0
        return max(clipEnd, noteEnd)
    }

    init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }
}

/// Time-stretch rate to fit a loop recorded at `loopBPM` into a `projectBPM` project.
/// nil when unknown or already matching (rate>1 speeds the loop up).
func loopFitRate(loopBPM: Int?, projectBPM: Double) -> Float? {
    guard let bpm = loopBPM, bpm > 0, projectBPM > 0 else { return nil }
    let rate = Float(projectBPM / Double(bpm))
    return abs(rate - 1) > 0.01 ? rate : nil
}

/// A tempo change on the tempo track (step change; the base tempo applies before the first).
struct TempoPoint: Identifiable, Equatable, Codable {
    var id = UUID()
    var time: TimeInterval
    var bpm: Double
}

/// The BPM in effect at `time` given a base tempo + step tempo changes.
func tempoAt(_ time: TimeInterval, base: Double, points: [TempoPoint]) -> Double {
    var bpm = base
    for p in points.sorted(by: { $0.time < $1.time }) where p.time <= time { bpm = p.bpm }
    return bpm
}

/// Times (seconds) of each beat from 0…`until`, integrating step tempo changes. Pure.
func beatTimes(base: Double, points: [TempoPoint], until: TimeInterval) -> [TimeInterval] {
    guard until >= 0 else { return [] }
    var times: [TimeInterval] = []
    var t = 0.0
    var guardCount = 0
    while t <= until && guardCount < 200_000 {
        times.append(t)
        t += 60.0 / max(30, tempoAt(t, base: base, points: points))
        guardCount += 1
    }
    return times
}

enum MusicScale: Int, Codable { case major, minor }

/// Snap a MIDI pitch to the nearest tone in `root`+`scale` (pitch class–based). Pure.
func snapToScale(_ pitch: Int, root: Int, scale: MusicScale) -> Int {
    let steps = scale == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
    let pc = ((pitch - root) % 12 + 12) % 12
    if steps.contains(pc) { return pitch }
    var bestOffset = 0, bestDist = 12
    for delta in -6...6 where delta != 0 {
        let candidatePC = ((pc + delta) % 12 + 12) % 12
        if steps.contains(candidatePC) && abs(delta) < bestDist { bestDist = abs(delta); bestOffset = delta }
    }
    return pitch + bestOffset
}

/// Build a diatonic triad progression as MIDI notes (one chord per bar). Pure.
/// `root` 0=C…11=B; `degrees` are 0-based scale degrees (0=I, 1=ii … 6=vii°).
func chordProgression(root: Int, scale: MusicScale, degrees: [Int],
                      barDuration: TimeInterval, octave: Int = 4) -> [MIDINote] {
    let steps = scale == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
    let base = root + 12 * (octave + 1)   // MIDI: C4 = 60 = 0 + 12*5
    var notes: [MIDINote] = []
    for (bar, degree) in degrees.enumerated() {
        let start = Double(bar) * barDuration
        for offset in [0, 2, 4] {              // root / third / fifth, stacked in the scale
            let index = degree + offset
            let pitch = base + steps[index % 7] + 12 * (index / 7)
            notes.append(MIDINote(pitch: min(127, max(0, pitch)), start: start,
                                  duration: barDuration * 0.95, velocity: 88))
        }
    }
    return notes
}

/// A named drum-machine preset: which GM drum hits land on which 16th steps (per bar).
struct DrumPreset { let name: String; let hits: [(pitch: Int, steps: [Int])] }

enum DrumPatterns {
    // GM drums: 36 kick, 38 snare, 39 clap, 42 closed hat, 46 open hat, 56 cowbell.
    static let all: [DrumPreset] = [
        DrumPreset(name: "Four on the Floor", hits: [(36, [0, 4, 8, 12]), (39, [4, 12]), (42, [2, 6, 10, 14]), (46, [14])]),
        DrumPreset(name: "Boom Bap", hits: [(36, [0, 10]), (38, [4, 12]), (42, [0, 2, 4, 6, 8, 10, 12, 14])]),
        DrumPreset(name: "Trap", hits: [(36, [0, 6, 11]), (38, [8]), (42, [0, 2, 4, 6, 8, 10, 12, 13, 14, 15])]),
        DrumPreset(name: "Rock", hits: [(36, [0, 8]), (38, [4, 12]), (42, [0, 2, 4, 6, 8, 10, 12, 14])]),
        DrumPreset(name: "Disco", hits: [(36, [0, 4, 8, 12]), (38, [4, 12]), (46, [2, 6, 10, 14]), (42, [0, 4, 8, 12])]),
        DrumPreset(name: "Afro House", hits: [(36, [0, 3, 6, 10]), (39, [4, 12]), (42, [2, 6, 10, 14]), (56, [1, 5, 9, 13])])
    ]

    /// Generate notes for a preset, tiled across `bars` (16 steps per bar).
    static func notes(_ preset: DrumPreset, bars: Int, stepDur: TimeInterval) -> [MIDINote] {
        var result: [MIDINote] = []
        for bar in 0..<max(1, bars) {
            let base = Double(bar * 16) * stepDur
            for hit in preset.hits {
                for step in hit.steps {
                    result.append(MIDINote(pitch: hit.pitch, start: base + Double(step) * stepDur,
                                           duration: stepDur * 0.9, velocity: 110))
                }
            }
        }
        return result
    }
}

/// Taste knobs for the auto-drummer — a few intuitive dials instead of note editing.
struct DrummerSettings: Equatable {
    var style: Int = 0            // index into DrumPatterns.all
    var complexity: Double = 0.5  // 0 = skeletal, 1 = busy (ghosts, hats, syncopation)
    var intensity: Double = 0.7   // 0 = soft, 1 = hard-hitting (velocity + accents)
    var swing: Double = 0.0       // 0 = straight, 1 = hard shuffle
    var fillEvery: Int = 4        // 0 = no fills; else a drum fill on every Nth bar
}

/// Generate a humanized drum performance from a style + taste knobs. Pure and deterministic
/// (same settings + seed → identical notes), so it's fully testable and undo-friendly.
func drummerPerformance(_ s: DrummerSettings, bars: Int, stepDur: TimeInterval, seed: UInt64) -> [MIDINote] {
    let styles = DrumPatterns.all
    guard !styles.isEmpty, stepDur > 0 else { return [] }
    let preset = styles[min(max(0, s.style), styles.count - 1)]
    let kick = 36, snare = 38, clap = 39, closedHat = 42, openHat = 46
    let toms = [50, 48, 45]        // high → low, for fills
    let barSteps = 16

    let baseVel = 52.0 + s.intensity * 58.0    // ≈ 52…110
    func vel(_ v: Double) -> Int { max(1, min(127, Int(v.rounded()))) }
    // Swing pushes odd 16ths later (up to ~60% of a step).
    func swung(_ step: Int, _ base: Double) -> Double {
        base + Double(step) * stepDur + (step % 2 == 1 ? s.swing * stepDur * 0.6 : 0)
    }

    var out: [MIDINote] = []
    for bar in 0..<max(1, bars) {
        var rng = SeededRNG(state: seed &+ UInt64(bar) &* 2654435761)
        func chance(_ p: Double) -> Bool { Double(rng.next() % 1000) / 1000.0 < p }
        let barBase = Double(bar * barSteps) * stepDur
        let isFill = s.fillEvery > 0 && (bar + 1) % s.fillEvery == 0
        var placed = Set<Int>()    // pitch*100+step, to avoid double hits
        func add(_ pitch: Int, _ step: Int, _ v: Double, dur: Double = 0.9) {
            guard step >= 0, step < barSteps, placed.insert(pitch * 100 + step).inserted else { return }
            let accent = step % 4 == 0 ? 12.0 : 0
            out.append(MIDINote(pitch: pitch, start: swung(step, barBase),
                                duration: stepDur * dur, velocity: vel(v + accent)))
        }

        // 1) The style's backbone (on a fill bar, clear the last beat for the fill — kick stays).
        for hit in preset.hits {
            for step in hit.steps where !(isFill && step >= 12 && hit.pitch != kick) {
                add(hit.pitch, step, baseVel)
            }
        }

        if !isFill {
            // 2) Complexity adds hats, ghost snares, and kick syncopation.
            let hatEvery = s.complexity > 0.66 ? 1 : (s.complexity > 0.33 ? 2 : 4)
            for step in stride(from: 0, to: barSteps, by: hatEvery) {
                add(closedHat, step, baseVel * (step % 4 == 0 ? 0.85 : 0.6))
            }
            for step in stride(from: 1, to: barSteps, by: 2) where chance(s.complexity * 0.5) {
                add(snare, step, baseVel * 0.32, dur: 0.5)                  // ghost note
            }
            for step in [3, 7, 11, 14] where chance(s.complexity * 0.4) {
                add(kick, step, baseVel * 0.9)                             // pushed kick
            }
            if chance(s.complexity * 0.5) { add(openHat, 14, baseVel * 0.7, dur: 1.4) }
        } else {
            // 3) A crescendo tom/snare fill across the last beat.
            let rollSteps = s.complexity > 0.5 ? [12, 13, 14, 15] : [12, 14]
            for (i, step) in rollSteps.enumerated() {
                let cresc = baseVel * (0.7 + 0.3 * Double(i) / Double(max(1, rollSteps.count - 1)))
                add(toms[min(i, toms.count - 1)], step, cresc)
                if chance(0.5) { add(snare, step, cresc * 0.9, dur: 0.5) }
            }
        }
    }
    return out.sorted { $0.start < $1.start }
}

/// How the auto-bassist plays under the chords.
struct BassSettings: Equatable {
    var pattern: Int = 0     // 0 roots, 1 octaves, 2 walking, 3 arpeggio, 4 pump
    var octave: Int = 2      // bass register (2 ≈ C2)
    var drive: Double = 0.6  // 0 soft … 1 hard (velocity)
}

/// The chord root (pitch class 0–11) sounding in each bar of `notes` — the lowest note in
/// the bar, a reliable bass anchor for chord-generator / imported parts. nil = silent bar. Pure.
func chordRootsPerBar(_ notes: [MIDINote], secPerBar: Double, bars: Int) -> [Int?] {
    guard secPerBar > 0 else { return [] }
    return (0..<max(1, bars)).map { bar in
        let start = Double(bar) * secPerBar, end = start + secPerBar
        let inBar = notes.filter { $0.start < end - 1e-6 && $0.start + $0.duration > start + 1e-6 }
        guard let lowest = inBar.min(by: { $0.pitch < $1.pitch }) else { return nil }
        return ((lowest.pitch % 12) + 12) % 12
    }
}

/// Generate a bassline that follows `roots` (one chord root per bar) in the chosen pattern.
/// Pure and deterministic — testable, undo-friendly.
func bassPerformance(roots: [Int?], settings s: BassSettings, secPerBar: Double) -> [MIDINote] {
    guard secPerBar > 0, !roots.isEmpty else { return [] }
    func clamp(_ n: Int) -> Int { max(24, min(55, n)) }              // C1…G3
    func rootNote(_ pc: Int) -> Int { clamp((s.octave + 1) * 12 + ((pc % 12) + 12) % 12) }
    let vel = max(1, min(127, 60 + Int(s.drive * 55)))
    func walk(_ r: Int, to target: Int) -> [Int] { [r, r + 7, r + 5, target - 1] }  // root·5·4·leading tone

    var out: [MIDINote] = []
    for (bar, rootPC) in roots.enumerated() {
        guard let pc = rootPC else { continue }
        let base = Double(bar) * secPerBar
        let r = rootNote(pc)
        let nextR = rootNote((bar + 1 < roots.count ? roots[bar + 1] : nil) ?? pc)
        func emit(_ pitch: Int, _ step: Double, _ len: Double) {
            out.append(MIDINote(pitch: clamp(pitch), start: base + step, duration: len, velocity: vel))
        }
        switch s.pattern {
        case 1:                                                     // octaves on the beat
            for b in 0..<4 { emit(b % 2 == 0 ? r : r + 12, Double(b) * secPerBar / 4, secPerBar / 4 * 0.9) }
        case 2:                                                     // walking quarter notes
            for (i, p) in walk(r, to: nextR).enumerated() { emit(p, Double(i) * secPerBar / 4, secPerBar / 4 * 0.9) }
        case 3:                                                     // arpeggio eighths
            let arp = [r, r + 7, r + 12, r + 7]
            for i in 0..<8 { emit(arp[i % arp.count], Double(i) * secPerBar / 8, secPerBar / 8 * 0.9) }
        case 4:                                                     // pump — offbeat eighths
            for b in 0..<4 { emit(r, (Double(b) + 0.5) * secPerBar / 4, secPerBar / 4 * 0.45) }
        default:                                                    // roots — sustained whole note
            emit(r, 0, secPerBar * 0.98)
        }
    }
    return out
}

/// Re-voice a chord: plain triad, or richer diatonic colors that make it "sound new".
enum ChordColor: Int, CaseIterable, Identifiable {
    case triad, seventh, ninth, sus4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .triad: return "Triads"
        case .seventh: return "7ths"
        case .ninth: return "9ths"
        case .sus4: return "Sus4"
        }
    }
    /// Scale-degree offsets (stacked thirds) above the chord root.
    var degrees: [Int] {
        switch self {
        case .triad: return [0, 2, 4]
        case .seventh: return [0, 2, 4, 6]
        case .ninth: return [0, 2, 4, 6, 8]
        case .sus4: return [0, 3, 4]          // fourth replaces the third
        }
    }
}

/// Quantize note starts to `grid`, then push the off-beats late by `amount`·grid — a shared
/// swing feel. Idempotent for amount < 0.5 (it re-quantizes first), so safe to re-apply. Pure.
func applySwing(_ notes: [MIDINote], amount: Double, grid: TimeInterval) -> [MIDINote] {
    guard grid > 0 else { return notes }
    return notes.map { n in
        let step = (n.start / grid).rounded()
        var t = step * grid
        if abs(Int(step)) % 2 == 1 { t += amount * grid }
        return MIDINote(pitch: n.pitch, start: max(0, t), duration: n.duration, velocity: n.velocity)
    }
}

/// Swap chords for related ones to reharmonize a progression (changes the roots, not just voicing).
enum ChordSub: Int, CaseIterable, Identifiable {
    case relative, bright, jazzy
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .relative: return "Relative (moodier)"
        case .bright: return "Bright (lift)"
        case .jazzy: return "Jazzy (tritone)"
        }
    }
}

/// Move a MIDI pitch by `steps` scale degrees within `pool`, staying near its octave. Pure.
func moveDiatonic(_ midi: Int, steps: Int, pool: [Int]) -> Int {
    guard !pool.isEmpty else { return midi }
    let pc = ((midi % 12) + 12) % 12
    let idx = pool.firstIndex(of: pc) ?? pool.indices.min(by: { abs(pool[$0] - pc) < abs(pool[$1] - pc) })!
    let n = pool.count
    let target = idx + steps
    let octShift = Int(floor(Double(target) / Double(n)))
    let newPc = pool[((target % n) + n) % n]
    return (midi - pc) + newPc + 12 * octShift
}

/// Reharmonize a progression by substituting each bar's chord: a shared-tone third-relation
/// (relative/bright, stays in key) or a chromatic tritone dom7 (jazzy). Keeps the first chord as
/// a tonic anchor. Pure and deterministic.
func substituteChords(_ notes: [MIDINote], sub: ChordSub, pool poolIn: [Int],
                      secPerBar: Double, bars: Int) -> [MIDINote] {
    guard secPerBar > 0 else { return [] }
    let pool = (poolIn.isEmpty ? [0, 2, 4, 5, 7, 9, 11] : poolIn).sorted()
    var out: [MIDINote] = []
    for bar in 0..<max(1, bars) {
        let start = Double(bar) * secPerBar, end = start + secPerBar
        let inBar = notes.filter { $0.start < end - 1e-6 && $0.start + $0.duration > start + 1e-6 }
        guard let root = inBar.map(\.pitch).min() else { continue }
        func emit(_ pitch: Int) {
            out.append(MIDINote(pitch: min(127, max(0, pitch)), start: start,
                                duration: secPerBar * 0.95, velocity: 88))
        }
        // Keep bar 0 as the tonic anchor so the progression still resolves home.
        if bar == 0 {
            var scale: [Int] = [], p = root
            while scale.count < 5 && p < root + 26 { if pool.contains(((p % 12) + 12) % 12) { scale.append(p) }; p += 1 }
            for d in [0, 2, 4] where d < scale.count { emit(scale[d]) }
            continue
        }
        switch sub {
        case .jazzy:
            for iv in [0, 4, 7, 10] { emit(root + 6 + iv) }        // dom7 a tritone away (chromatic)
        default:
            let newRoot = moveDiatonic(root, steps: sub == .relative ? -2 : 2, pool: pool)
            var scale: [Int] = [], p = newRoot
            while scale.count < 5 && p < newRoot + 26 { if pool.contains(((p % 12) + 12) % 12) { scale.append(p) }; p += 1 }
            for d in [0, 2, 4] where d < scale.count { emit(scale[d]) }
        }
    }
    return out
}

/// Reharmonize a chord track (one chord per bar) with the chosen color, staying diatonic to
/// `pool` and keeping each chord's root register. Pure. Chords voiced as stacked scale thirds.
func reharmonize(_ notes: [MIDINote], color: ChordColor, pool poolIn: [Int],
                 secPerBar: Double, bars: Int) -> [MIDINote] {
    guard secPerBar > 0 else { return [] }
    let pool = (poolIn.isEmpty ? [0, 2, 4, 5, 7, 9, 11] : poolIn).sorted()
    var out: [MIDINote] = []
    for bar in 0..<max(1, bars) {
        let start = Double(bar) * secPerBar, end = start + secPerBar
        let inBar = notes.filter { $0.start < end - 1e-6 && $0.start + $0.duration > start + 1e-6 }
        guard let root = inBar.map(\.pitch).min() else { continue }
        // Consecutive scale degrees ascending from the root (each entry = one scale step up).
        var scale: [Int] = []
        var p = root
        while scale.count < 12 && p < root + 26 {
            if pool.contains(((p % 12) + 12) % 12) { scale.append(p) }
            p += 1
        }
        for d in color.degrees where d < scale.count {
            out.append(MIDINote(pitch: min(127, scale[d]), start: start,
                                duration: secPerBar * 0.95, velocity: 88))
        }
    }
    return out
}

/// One part of a song's arrangement. Sections share the vibe's chords but vary which parts
/// play and how hard, so the song breathes (sparse intro → full chorus → outro).
struct SongSection: Equatable {
    let name: String
    let bars: Int
    let bass: Bool
    let melody: Bool
    let drums: Bool
    let drumComplexity: Double
    let intensity: Double
    let melodyDensity: Double

    /// A conventional pop form with dynamic contrast between sections.
    static let defaultForm: [SongSection] = [
        SongSection(name: "Intro",  bars: 2, bass: false, melody: false, drums: true,
                    drumComplexity: 0.3, intensity: 0.5, melodyDensity: 0),
        SongSection(name: "Verse",  bars: 4, bass: true,  melody: true,  drums: true,
                    drumComplexity: 0.45, intensity: 0.7, melodyDensity: 0.35),
        SongSection(name: "Chorus", bars: 4, bass: true,  melody: true,  drums: true,
                    drumComplexity: 0.7, intensity: 0.95, melodyDensity: 0.6),
        SongSection(name: "Verse",  bars: 4, bass: true,  melody: true,  drums: true,
                    drumComplexity: 0.5, intensity: 0.75, melodyDensity: 0.4),
        SongSection(name: "Chorus", bars: 4, bass: true,  melody: true,  drums: true,
                    drumComplexity: 0.75, intensity: 1.0, melodyDensity: 0.65),
        SongSection(name: "Outro",  bars: 2, bass: true,  melody: false, drums: true,
                    drumComplexity: 0.35, intensity: 0.55, melodyDensity: 0)
    ]

    /// The starting bar of each section (cumulative), plus the total length. Pure.
    static func layout(_ form: [SongSection]) -> (starts: [Int], totalBars: Int) {
        var starts: [Int] = []
        var cursor = 0
        for s in form { starts.append(cursor); cursor += s.bars }
        return (starts, cursor)
    }
}

/// A one-click starting point: a genre feel that bundles a progression, tempo, and settings
/// for the chord / bass / melody / drum generators so they all match out of the gate.
struct SongVibe: Identifiable, Equatable {
    let id: Int
    let name: String
    let blurb: String
    let minor: Bool
    let degrees: [Int]        // 0-indexed diatonic scale degrees, one chord per bar
    let tempo: Double
    let drumStyle: Int        // index into DrumPatterns.all
    let complexity: Double    // drummer
    let swing: Double         // drummer
    let bassPattern: Int
    let melodyDensity: Double
    let melodyMotion: Double

    static let all: [SongVibe] = [
        SongVibe(id: 0, name: "Pop", blurb: "bright I–V–vi–IV, four-on-the-floor",
                 minor: false, degrees: [0, 4, 5, 3], tempo: 116, drumStyle: 0,
                 complexity: 0.5, swing: 0, bassPattern: 1, melodyDensity: 0.5, melodyMotion: 0.4),
        SongVibe(id: 1, name: "Lo-fi", blurb: "hazy minor, swung boom-bap",
                 minor: true, degrees: [0, 5, 2, 6], tempo: 80, drumStyle: 1,
                 complexity: 0.45, swing: 0.35, bassPattern: 0, melodyDensity: 0.35, melodyMotion: 0.3),
        SongVibe(id: 2, name: "Trap", blurb: "dark minor, rolling hats, 808s",
                 minor: true, degrees: [0, 5, 3, 6], tempo: 140, drumStyle: 2,
                 complexity: 0.7, swing: 0, bassPattern: 4, melodyDensity: 0.3, melodyMotion: 0.35),
        SongVibe(id: 3, name: "House", blurb: "four-on-the-floor, pumping bass",
                 minor: false, degrees: [0, 4, 5, 3], tempo: 124, drumStyle: 4,
                 complexity: 0.6, swing: 0, bassPattern: 4, melodyDensity: 0.7, melodyMotion: 0.5),
        SongVibe(id: 4, name: "R&B", blurb: "smooth minor, walking bass",
                 minor: true, degrees: [0, 5, 3, 4], tempo: 92, drumStyle: 1,
                 complexity: 0.5, swing: 0.2, bassPattern: 2, melodyDensity: 0.5, melodyMotion: 0.55)
    ]
}

/// The chord (set of pitch classes 0–11) sounding in each bar of `notes`. Pure.
func chordTonesPerBar(_ notes: [MIDINote], secPerBar: Double, bars: Int) -> [[Int]] {
    guard secPerBar > 0 else { return [] }
    return (0..<max(1, bars)).map { bar in
        let start = Double(bar) * secPerBar, end = start + secPerBar
        let inBar = notes.filter { $0.start < end - 1e-6 && $0.start + $0.duration > start + 1e-6 }
        return Array(Set(inBar.map { ((($0.pitch % 12) + 12) % 12) })).sorted()
    }
}

/// How the auto-melody sits over the chords.
struct MelodySettings: Equatable {
    var density: Double = 0.5    // sparse (held notes) … busy (eighths)
    var motion: Double = 0.4     // smooth (stepwise) … leapy (chord jumps)
    var register: Int = 5        // octave center (5 ≈ C5)
}

/// Generate a singable topline that lands chord tones on strong beats and steps through the
/// scale between them, with smooth voice-leading. Pure and deterministic given `seed`.
func melodyLine(chords: [[Int]], pool poolIn: [Int], settings s: MelodySettings,
                secPerBar: Double, seed: UInt64) -> [MIDINote] {
    guard secPerBar > 0, !chords.isEmpty else { return [] }
    let pool = (poolIn.isEmpty ? [0, 2, 4, 5, 7, 9, 11] : poolIn).sorted()
    let center = (s.register + 1) * 12
    let (bandLo, bandHi) = (center - 3, center + 14)
    func inBand(_ set: Set<Int>) -> [Int] { (bandLo...bandHi).filter { set.contains((($0 % 12) + 12) % 12) } }
    let scalePitches = inBand(Set(pool))
    guard !scalePitches.isEmpty else { return [] }
    func nearest(_ arr: [Int], to prev: Int) -> Int { arr.min(by: { abs($0 - prev) < abs($1 - prev) }) ?? prev }

    let stepDur = secPerBar / 16
    var out: [MIDINote] = []
    var prev = center
    for (bar, chordPCs) in chords.enumerated() {
        var rng = SeededRNG(state: seed &+ UInt64(bar) &* 0x9E3779B1)
        func chance(_ p: Double) -> Bool { Double(rng.next() % 1000) / 1000 < p }
        let base = Double(bar) * secPerBar
        let chordPitches = inBand(Set(chordPCs.isEmpty ? pool : chordPCs))
        let steps = s.density < 0.33 ? [0, 8] : (s.density < 0.66 ? [0, 4, 8, 12] : [0, 2, 4, 6, 8, 10, 12, 14])
        for st in steps {
            let strong = st % 8 == 0
            let target: Int
            if strong || chance(s.motion) {
                target = nearest(chordPitches, to: prev)                 // land a chord tone
            } else {
                let idx = scalePitches.firstIndex(of: nearest(scalePitches, to: prev)) ?? 0
                let ni = max(0, min(scalePitches.count - 1, idx + (chance(0.5) ? 1 : -1)))
                target = scalePitches[ni]                                // step through the scale
            }
            let nextStep = steps.first(where: { $0 > st }) ?? 16
            let dur = max(stepDur * 0.5, Double(nextStep - st) * stepDur * 0.9)
            out.append(MIDINote(pitch: max(bandLo, min(bandHi, target)),
                                start: base + Double(st) * stepDur, duration: dur, velocity: 92))
            prev = target
        }
    }
    return out
}

/// Small seedable RNG so humanize is deterministic for tests (the app passes a random seed).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Nudge note timing (± `timing` seconds) and velocity (± `velocity`) so a part feels human. Pure.
func humanize(_ notes: [MIDINote], timing: TimeInterval, velocity: Int, seed: UInt64) -> [MIDINote] {
    var rng = SeededRNG(state: seed | 1)
    return notes.map { note in
        var n = note
        if timing > 0 { n.start = max(0, note.start + Double.random(in: -timing...timing, using: &rng)) }
        if velocity > 0 { n.velocity = min(127, max(1, note.velocity + Int.random(in: -velocity...velocity, using: &rng))) }
        return n
    }
}

enum ArpPattern { case up, down, upDown }

/// Turn chords (notes sharing a start) into an arpeggio: single notes cycling the
/// chord's pitches at `rate`, across each chord's duration. Pure → unit-testable.
func arpeggiate(_ notes: [MIDINote], rate: TimeInterval, pattern: ArpPattern) -> [MIDINote] {
    guard rate > 0, !notes.isEmpty else { return notes }
    let sorted = notes.sorted { $0.start < $1.start }
    let tol = rate * 0.5

    // Group notes into chords by near-equal start time.
    var chords: [[MIDINote]] = []
    for note in sorted {
        if let first = chords.last?.first, abs(note.start - first.start) < tol {
            chords[chords.count - 1].append(note)
        } else {
            chords.append([note])
        }
    }

    var result: [MIDINote] = []
    for chord in chords {
        let start = chord.map(\.start).min() ?? 0
        let end = chord.map { $0.start + $0.duration }.max() ?? start
        var pitches = Array(Set(chord.map(\.pitch))).sorted()
        guard !pitches.isEmpty, end > start else { continue }
        switch pattern {
        case .up: break
        case .down: pitches.reverse()
        case .upDown: if pitches.count > 2 { pitches += pitches.dropFirst().dropLast().reversed() }
        }
        let velocity = chord.map(\.velocity).max() ?? 100
        var t = start, i = 0
        while t < end - 0.0001 {
            result.append(MIDINote(pitch: pitches[i % pitches.count], start: t,
                                   duration: min(rate, end - t), velocity: velocity))
            t += rate; i += 1
        }
    }
    return result
}

/// Sample an automation envelope at `time` (linear between points; flat outside).
func automationValue(_ points: [AutomationPoint], at time: TimeInterval, default def: Float) -> Float {
    guard let first = points.first else { return def }
    if time <= first.time { return first.value }
    guard let last = points.last else { return def }
    if time >= last.time { return last.value }
    for i in 1..<points.count where points[i].time >= time {
        let a = points[i - 1], b = points[i]
        let span = b.time - a.time
        if span <= 0 { return b.value }
        let t = Float((time - a.time) / span)
        return a.value + (b.value - a.value) * t
    }
    return last.value
}
