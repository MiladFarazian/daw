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
        self.name = url.deletingPathExtension().lastPathComponent
        self.duration = duration
        self.sampleRate = sampleRate
        self.peaks = peaks
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
    var name: String { asset.name }

    init(asset: AudioAsset, startTime: TimeInterval = 0) {
        self.asset = asset
        self.startTime = startTime
        self.offset = 0
        self.duration = asset.duration
    }
}

/// One horizontal lane with its own mixer settings.
struct Track: Identifiable {
    let id = UUID()
    var name: String
    var colorIndex: Int
    var volume: Float = 0.8
    var pan: Float = 0
    var isMuted = false
    var isSoloed = false
    var clips: [Clip] = []

    var endTime: TimeInterval { clips.map { $0.startTime + $0.duration }.max() ?? 0 }

    init(name: String, colorIndex: Int) {
        self.name = name
        self.colorIndex = colorIndex
    }
}
