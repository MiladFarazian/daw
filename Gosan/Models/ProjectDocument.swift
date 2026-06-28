import Foundation

/// A serializable snapshot of a project. Audio is referenced by filename in the
/// app library (Application Support/Gosan/Imports); waveforms are recomputed on load.
struct ProjectDocument: Codable {
    var version = 1
    var name: String
    var tempo: Double
    var pixelsPerSecond: Double
    var tracks: [TrackData]

    struct TrackData: Codable {
        var name: String
        var colorIndex: Int
        var volume: Float
        var pan: Float
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
    }
}
