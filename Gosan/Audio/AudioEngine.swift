import AVFoundation
import AudioToolbox

/// Owns the AVAudioEngine graph: one player + mixer per track, summed into a main mixer.
/// Designed for multi-track sample-synchronized playback from any timeline position.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let mainMixer = AVAudioMixerNode()

    private struct TrackNode {
        let player: AVAudioPlayerNode
        let mixer: AVAudioMixerNode
        let eq: AVAudioUnitEQ
        let comp: AVAudioUnitEffect
        let reverb: AVAudioUnitReverb
        let delay: AVAudioUnitDelay
    }
    private var nodes: [UUID: TrackNode] = [:]

    private static func makeCompressor() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription:
            AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                      componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                      componentManufacturer: kAudioUnitManufacturer_Apple,
                                      componentFlags: 0, componentFlagsMask: 0))
    }

    /// amount 0 = off (threshold above any signal); higher = lower threshold = more compression.
    private func configureCompressor(_ comp: AVAudioUnitEffect, amount: Float) {
        let au = comp.audioUnit
        let threshold: Float = amount <= 0 ? 20 : 20 - amount * 50   // +20 dB (off) → -30 dB
        AudioUnitSetParameter(au, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, threshold, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 5, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.1, 0)
    }

    private func configureEQ(_ eq: AVAudioUnitEQ) {
        let low = eq.bands[0]; low.filterType = .lowShelf; low.frequency = 120; low.bypass = false
        let mid = eq.bands[1]; mid.filterType = .parametric; mid.frequency = 1000; mid.bandwidth = 1.0; mid.bypass = false
        let high = eq.bands[2]; high.filterType = .highShelf; high.frequency = 8000; high.bypass = false
    }

    // Metronome
    private let metronomePlayer = AVAudioPlayerNode()
    private lazy var clickFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private lazy var normalClick = makeClick(freq: 1000, amp: 0.4)
    private lazy var accentClick = makeClick(freq: 1500, amp: 0.6)

    /// Called on a realtime thread with the master output peak (0...1). Hop to main yourself.
    var onLevel: ((Float) -> Void)?

    // Master bus: mainMixer → master EQ → peak limiter → output.
    private let masterEQ = AVAudioUnitEQ(numberOfBands: 3)
    private let masterLimiter = AVAudioUnitEffect(audioComponentDescription:
        AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                  componentSubType: kAudioUnitSubType_PeakLimiter,
                                  componentManufacturer: kAudioUnitManufacturer_Apple,
                                  componentFlags: 0, componentFlagsMask: 0))

    func setMasterEQ(low: Float, mid: Float, high: Float) {
        masterEQ.bands[0].gain = low
        masterEQ.bands[1].gain = mid
        masterEQ.bands[2].gain = high
    }

    init() {
        configureEQ(masterEQ)
        engine.attach(mainMixer)
        engine.attach(masterEQ)
        engine.attach(masterLimiter)
        engine.connect(mainMixer, to: masterEQ, format: nil)
        engine.connect(masterEQ, to: masterLimiter, format: nil)
        engine.connect(masterLimiter, to: engine.outputNode, format: nil)
        engine.attach(metronomePlayer)
        engine.connect(metronomePlayer, to: mainMixer, format: clickFormat)

        mainMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            var peak: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                let p = channels[c]
                for i in 0..<n { let a = abs(p[i]); if a > peak { peak = a } }
            }
            self?.onLevel?(min(1, peak))
        }
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
    private func scheduleMetronome(tempo: Double, from position: TimeInterval, t0: AVAudioTime, beatsPerBar: Int) {
        metronomePlayer.stop()
        guard tempo > 0 else { return }
        let beat = 60.0 / tempo
        let firstBeat = Int(ceil(position / beat - 0.0001))
        for k in 0..<256 {
            let index = firstBeat + k
            let whenSeconds = Double(index) * beat - position
            guard whenSeconds >= 0 else { continue }
            let when = AVAudioTime(hostTime: t0.hostTime + AVAudioTime.hostTime(forSeconds: whenSeconds))
            if let buffer = (index % max(1, beatsPerBar) == 0) ? accentClick : normalClick {
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
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            configureEQ(eq)
            let comp = Self.makeCompressor()
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = 0
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.33
            delay.feedback = 30
            delay.wetDryMix = 0
            [player, mixer, eq, comp, reverb, delay].forEach { engine.attach($0) }

            let format = track.clips.first
                .flatMap { try? AVAudioFile(forReading: $0.asset.url).processingFormat }
                ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

            // player → mixer → eq → comp → reverb → delay → main. Effects sit after the mixer
            // so they always see stereo (the AUs reject a mono input).
            let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
            engine.connect(player, to: mixer, format: format)
            engine.connect(mixer, to: eq, format: stereo)
            engine.connect(eq, to: comp, format: stereo)
            engine.connect(comp, to: reverb, format: stereo)
            engine.connect(reverb, to: delay, format: stereo)
            engine.connect(delay, to: mainMixer, format: stereo)
            nodes[track.id] = TrackNode(player: player, mixer: mixer, eq: eq, comp: comp, reverb: reverb, delay: delay)
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
            node.reverb.wetDryMix = track.reverb * 100
            node.delay.wetDryMix = track.delay * 100
            node.eq.bands[0].gain = track.eqLow
            node.eq.bands[1].gain = track.eqMid
            node.eq.bands[2].gain = track.eqHigh
            configureCompressor(node.comp, amount: track.compress)
        }
    }

    /// Start synchronized playback of all tracks from `position` seconds on the timeline.
    func play(tracks: [Track], from position: TimeInterval, metronome: Bool = false,
              tempo: Double = 120, beatsPerBar: Int = 4) {
        prepare(tracks: tracks)

        let lead = 0.12 // schedule slightly in the future so every node starts together
        let startHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead)
        let t0 = AVAudioTime(hostTime: startHost)

        if metronome { scheduleMetronome(tempo: tempo, from: position, t0: t0, beatsPerBar: beatsPerBar) }

        for track in tracks {
            guard let node = nodes[track.id] else { continue }
            node.player.stop()

            for clip in track.clips {
                guard !clip.muted, let file = try? AVAudioFile(forReading: clip.asset.url) else { continue }
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
                                                 fadeInFrames: fadeInFrames, fadeOutFrames: fadeOutFrames,
                                                 gain: clip.gain, curve: clip.fadeCurve) {
                    node.player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
                }
            }
            node.player.play(at: t0)
        }
    }

    /// Play one bar of metronome clicks, then call `completion` (for a recording count-in).
    func playCountIn(tempo: Double, beatsPerBar: Int, completion: @escaping () -> Void) {
        guard tempo > 0 else { completion(); return }
        if !engine.isRunning { try? engine.start() }
        let beat = 60.0 / tempo
        let lead = 0.1
        let t0 = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
        metronomePlayer.stop()
        let bpb = max(1, beatsPerBar)
        for i in 0..<bpb {
            let when = AVAudioTime(hostTime: t0.hostTime + AVAudioTime.hostTime(forSeconds: Double(i) * beat))
            if let buffer = (i == 0) ? accentClick : normalClick {
                metronomePlayer.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
            }
        }
        metronomePlayer.play(at: t0)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(bpb) * beat + lead) { completion() }
    }

    func stop() {
        for node in nodes.values { node.player.stop() }
        metronomePlayer.stop()
    }

    /// Tear down all track nodes (used when switching projects).
    func reset() {
        stop()
        for node in nodes.values {
            [node.player, node.mixer, node.eq, node.comp, node.reverb, node.delay].forEach { engine.detach($0) }
        }
        nodes.removeAll()
    }
}
