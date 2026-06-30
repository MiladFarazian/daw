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

/// One horizontal lane with its own mixer settings.
struct Track: Identifiable {
    let id = UUID()
    var name: String
    var colorIndex: Int
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
    var program: Int = 0         // General-MIDI program (0 = grand piano)
    var notes: [MIDINote] = []

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
