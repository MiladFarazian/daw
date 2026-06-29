import Foundation

/// A serializable snapshot of a project. Audio is referenced by filename in the
/// app library (Application Support/Gosan/Imports); waveforms are recomputed on load.
struct ProjectDocument: Codable {
    var version = 1
    var name: String
    var tempo: Double
    var pixelsPerSecond: Double
    var tracks: [TrackData]
    var markers: [Marker] = []
    var masterEqLow: Float = 0
    var masterEqMid: Float = 0
    var masterEqHigh: Float = 0
    var beatsPerBar: Int = 4

    struct TrackData: Codable {
        var name: String
        var colorIndex: Int
        var volume: Float
        var pan: Float
        var reverb: Float = 0
        var delay: Float = 0
        var compress: Float = 0
        var eqLow: Float = 0
        var eqMid: Float = 0
        var eqHigh: Float = 0
        var isMuted: Bool
        var isSoloed: Bool
        var clips: [ClipData]
    }

    struct ClipData: Codable {
        var assetFile: String       // filename within the library
        var assetName: String
        var sampleRate: Double
        var assetDuration: TimeInterval
        var startTime: TimeInterval
        var offset: TimeInterval
        var duration: TimeInterval
        var fadeIn: TimeInterval = 0
        var fadeOut: TimeInterval = 0
        var gain: Float = 1.0
    }
}
