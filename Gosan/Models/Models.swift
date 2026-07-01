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
    var name: String { customName ?? asset.name }

    init(asset: AudioAsset, startTime: TimeInterval = 0) {
        self.asset = asset
        self.startTime = startTime
        self.offset = 0
        self.duration = asset.duration
    }
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
