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

    // Metronome
    private let metronomePlayer = AVAudioPlayerNode()
    private lazy var clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private lazy var normalClick = makeClick(freq: 1000, amp: 0.4)
    private lazy var accentClick = makeClick(freq: 1500, amp: 0.6)

    init() {
        engine.attach(mainMixer)
        engine.connect(mainMixer, to: engine.outputNode, format: nil)
        engine.attach(metronomePlayer)
        engine.connect(metronomePlayer, to: mainMixer, format: clickFormat)
    }

    private func makeClick(freq: Double, amp: Float) -> AVAudioPCMBuffer? {
        let sr = clickFormat.sampleRate
        let frames = AVAudioFrameCount(sr * 0.045)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for ch in 0..<Int(clickFormat.channelCount) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                let t = Double(i) / sr
                p[i] = amp * Float(exp(-t * 80)) * Float(sin(2 * .pi * freq * t))
            }
        }
        return buffer
    }

    /// Schedule clicks on the beat grid, synced to the same t0 as playback.
    private func scheduleMetronome(tempo: Double, from position: TimeInterval, t0: AVAudioTime) {
        metronomePlayer.stop()
        guard tempo > 0 else { return }
        let beat = 60.0 / tempo
        let firstBeat = Int(ceil(position / beat - 0.0001))
        for k in 0..<256 {
            let index = firstBeat + k
            let whenSeconds = Double(index) * beat - position
            guard whenSeconds >= 0 else { continue }
            let when = AVAudioTime(hostTime: t0.hostTime + AVAudioTime.hostTime(forSeconds: whenSeconds))
            if let buffer = (index % 4 == 0) ? accentClick : normalClick {
                metronomePlayer.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
            }
        }
        metronomePlayer.play(at: t0)
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
    func play(tracks: [Track], from position: TimeInterval, metronome: Bool = false, tempo: Double = 120) {
        prepare(tracks: tracks)

        let lead = 0.12 // schedule slightly in the future so every node starts together
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        let t0 = AVAudioTime(hostTime: startHost)

        if metronome { scheduleMetronome(tempo: tempo, from: position, t0: t0) }

        for track in tracks {
            guard let node = nodes[track.id] else { continue }
            node.player.stop()

            for clip in track.clips {
                guard let file = try? AVAudioFile(forReading: clip.asset.url) else { continue }
                let sampleRate = file.processingFormat.sampleRate
                let clipEnd = clip.startTime + clip.duration
                guard clipEnd > position else { continue }

                // How far into the clip's visible region playback begins.
                let intoClip = max(0, position - clip.startTime)
                let startFrame = AVAudioFramePosition((clip.offset + intoClip) * sampleRate)
                let available = file.length - startFrame
                guard available > 0 else { continue }
                let wanted = AVAudioFramePosition((clip.duration - intoClip) * sampleRate)
                let frames = AVAudioFrameCount(max(0, min(wanted, available)))
                guard frames > 0 else { continue }

                let whenSeconds = max(0, clip.startTime - position)
                let when = AVAudioTime(hostTime: t0.hostTime + AVAudioTime.hostTime(forSeconds: whenSeconds))
                // Fade-in only applies if we begin at the clip's head; fade-out is at its tail.
                let fadeInFrames = Int(max(0, clip.fadeIn - intoClip) * sampleRate)
                let fadeOutFrames = Int(clip.fadeOut * sampleRate)
                if let buffer = ClipBuffer.faded(file: file, startFrame: startFrame, frames: frames,
                                                 fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames) {
                    node.player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
                }
            }
            node.player.play(at: t0)
        }
    }

    func stop() {
        for node in nodes.values { node.player.stop() }
        metronomePlayer.stop()
    }

    /// Tear down all track nodes (used when switching projects).
    func reset() {
        stop()
        for node in nodes.values {
            engine.detach(node.player)
            engine.detach(node.mixer)
        }
        nodes.removeAll()
    }
}
