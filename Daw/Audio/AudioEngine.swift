import AVFoundation

/// Owns the AVAudioEngine graph: one player + mixer per track, summed into a main mixer.
/// Designed for multi-track sample-synchronized playback from any timeline position.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()

    private struct TrackNode {
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
    }
    private var nodes: [UUID: TrackNode] = [:]

    init() {
        engine.attach(mainMixer)
        engine.connect(mainMixer, to: engine.outputNode, format: nil)
    }

    /// Make sure every track has audio nodes attached and the mix reflects current state.
    func prepare(tracks: [Track]) {
        for track in tracks where nodes[track.id] == nil {
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()
            engine.attach(player)
            engine.attach(mixer)

            let format = track.clips.first
                .flatMap { try? AVAudioFile(forReading: $0.asset.url).processingFormat }
                ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

            engine.connect(player, to: mixer, format: format)
            engine.connect(mixer, to: mainMixer, format: nil)
            nodes[track.id] = TrackNode(player: player, mixer: mixer)
        }
        applyMix(tracks: tracks)
        if !engine.isRunning { try? engine.start() }
    }

    /// Apply volume / pan / mute / solo to the per-track mixers.
    func applyMix(tracks: [Track]) {
        let soloing = tracks.contains { $0.isSoloed }
        for track in tracks {
            guard let node = nodes[track.id] else { continue }
            let audible = soloing ? track.isSoloed : !track.isMuted
            node.mixer.outputVolume = audible ? track.volume : 0
            node.mixer.pan = track.pan
        }
    }

    /// Start synchronized playback of all tracks from `position` seconds on the timeline.
    func play(tracks: [Track], from position: TimeInterval) {
        prepare(tracks: tracks)

        let lead = 0.12 // schedule slightly in the future so every node starts together
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        let t0 = AVAudioTime(hostTime: startHost)

        for track in tracks {
            guard let node = nodes[track.id] else { continue }
            node.player.stop()

            for clip in track.clips {
                guard let file = try? AVAudioFile(forReading: clip.asset.url) else { continue }
                let sampleRate = file.processingFormat.sampleRate
                let clipEnd = clip.startTime + clip.asset.duration
                guard clipEnd > position else { continue }

                let intoClip = max(0, position - clip.startTime)
                let startFrame = AVAudioFramePosition(intoClip * sampleRate)
                let remaining = file.length - startFrame
                guard remaining > 0 else { continue }

                let whenSeconds = max(0, clip.startTime - position)
                let when = AVAudioTime(hostTime: t0.hostTime + AVAudioTime.hostTime(forSeconds: whenSeconds))
                node.player.scheduleSegment(file,
                                            startingFrame: startFrame,
                                            frameCount: AVAudioFrameCount(remaining),
                                            at: when)
            }
            node.player.play(at: t0)
        }
    }

    func stop() {
        for node in nodes.values { node.player.stop() }
    }
}
