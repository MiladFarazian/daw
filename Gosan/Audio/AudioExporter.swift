import AVFoundation
import AudioToolbox

/// Bounces the timeline to a stereo WAV using AVAudioEngine's offline manual-rendering mode.
/// Builds a throwaway graph so it never disturbs live playback.
enum AudioExporter {
    enum ExportError: LocalizedError {
        case noContent
        case renderFailed
        var errorDescription: String? {
            switch self {
            case .noContent: return "Nothing to export."
            case .renderFailed: return "Offline render failed."
            }
        }
    }

    static func render(tracks: [Track], duration: TimeInterval, to url: URL,
                       from: TimeInterval = 0, aac: Bool = false, masterVolume: Float = 1.0,
                       sampleRate: Double = 44_100) throws {
        let totalFrames = AVAudioFramePosition((duration * sampleRate).rounded(.up))
        guard totalFrames > 0,
              let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw ExportError.noContent
        }

        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode
        mainMixer.outputVolume = max(0, min(1, masterVolume))
        let soloing = tracks.contains { $0.isSoloed }

        var players: [AVAudioPlayerNode] = []
        var synths: [(au: AVAudioUnit, program: Int)] = []
        var midiEvents: [MIDISupport.Event] = []
        struct Automated {
            let track: Track
            let mixer: AVAudioMixerNode; let eq: AVAudioUnitEQ
            let reverb: AVAudioUnitReverb; let delay: AVAudioUnitDelay
            let audible: Bool
        }
        var automated: [Automated] = []

        for track in tracks {
            let mixer = AVAudioMixerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            eq.bands[0].filterType = .lowShelf; eq.bands[0].frequency = 120; eq.bands[0].gain = track.eqLow; eq.bands[0].bypass = false
            eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 1000; eq.bands[1].bandwidth = 1.0; eq.bands[1].gain = track.eqMid; eq.bands[1].bypass = false
            eq.bands[2].filterType = .highShelf; eq.bands[2].frequency = 8000; eq.bands[2].gain = track.eqHigh; eq.bands[2].bypass = false
            let comp = AVAudioUnitEffect(audioComponentDescription:
                AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                          componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                          componentManufacturer: kAudioUnitManufacturer_Apple,
                                          componentFlags: 0, componentFlagsMask: 0))
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = track.reverb * 100
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.33; delay.feedback = 30; delay.wetDryMix = track.delay * 100
            [mixer, eq, comp, reverb, delay].forEach { engine.attach($0) }
            let threshold: Float = track.compress <= 0 ? 20 : 20 - track.compress * 50
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, threshold, 0)
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 5, 0)
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
            AudioUnitSetParameter(comp.audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.1, 0)

            // Source: a synth (instrument track) or a player (audio track) → mixer.
            var player: AVAudioPlayerNode?
            if track.isInstrument, let synth = MIDISupport.makeDLSSynth() {
                engine.attach(synth)
                engine.connect(synth, to: mixer, format: renderFormat)
                synths.append((synth, track.program))
                midiEvents += MIDISupport.events(for: track.notes, au: synth.audioUnit,
                                                 channel: track.midiChannel, from: from, sampleRate: sampleRate)
            } else {
                let node = AVAudioPlayerNode()
                engine.attach(node)
                let trackFormat = track.clips.first
                    .flatMap { try? AVAudioFile(forReading: $0.asset.url).processingFormat }
                engine.connect(node, to: mixer, format: trackFormat)
                player = node
            }

            // mixer → eq → comp → reverb → delay → [plugins…] → main.
            engine.connect(mixer, to: eq, format: renderFormat)
            engine.connect(eq, to: comp, format: renderFormat)
            engine.connect(comp, to: reverb, format: renderFormat)
            engine.connect(reverb, to: delay, format: renderFormat)
            var tail: AVAudioNode = delay
            for ref in track.plugins {
                guard let plugin = PluginHost.instantiate(ref) else { continue }
                engine.attach(plugin)
                engine.connect(tail, to: plugin, format: renderFormat)
                tail = plugin
            }
            engine.connect(tail, to: mainMixer, format: renderFormat)

            let audible = soloing ? track.isSoloed : !track.isMuted
            mixer.outputVolume = audible ? track.volume : 0
            mixer.pan = track.pan
            if track.hasAutomation {
                automated.append(Automated(track: track, mixer: mixer, eq: eq,
                                           reverb: reverb, delay: delay, audible: audible))
            }

            if let player {
                for clip in track.clips {
                    guard !clip.muted, let file = try? AVAudioFile(forReading: clip.asset.url) else { continue }
                    let fileRate = file.processingFormat.sampleRate
                    guard clip.startTime + clip.duration > from else { continue }
                    let intoClip = max(0, from - clip.startTime)
                    let startFrame = AVAudioFramePosition((clip.offset + intoClip) * fileRate)
                    let available = file.length - startFrame
                    guard available > 0 else { continue }
                    let frames = AVAudioFrameCount(max(0, min((clip.duration - intoClip) * fileRate, Double(available))))
                    guard frames > 0 else { continue }
                    let whenSeconds = max(0, clip.startTime - from)
                    let when = AVAudioTime(sampleTime: AVAudioFramePosition(whenSeconds * sampleRate), atRate: sampleRate)
                    let fadeIn = max(0, clip.fadeIn - intoClip)
                    if let buffer = ClipBuffer.faded(file: file, startFrame: startFrame, frames: frames,
                                                     fadeInFrames: Int(fadeIn * fileRate),
                                                     fadeOutFrames: Int(clip.fadeOut * fileRate),
                                                     gain: clip.gain, curve: clip.fadeCurve) {
                        player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
                    }
                }
                players.append(player)
            }
        }

        try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                             maximumFrameCount: 4096)
        try engine.start()
        players.forEach { $0.play() }
        for synth in synths { MIDISupport.program(synth.au.audioUnit, synth.program) }

        let settings: [String: Any] = aac
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
            : renderFormat.settings
        let outputFile = try AVAudioFile(forWriting: url, settings: settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw ExportError.renderFailed
        }

        // Apply volume/pan automation at the given timeline time.
        func updateAutomation(at time: TimeInterval) {
            for a in automated {
                let t = a.track
                if !t.volumeAutomation.isEmpty {
                    a.mixer.outputVolume = a.audible ? automationValue(t.volumeAutomation, at: time, default: t.volume) : 0
                }
                if !t.panAutomation.isEmpty { a.mixer.pan = automationValue(t.panAutomation, at: time, default: t.pan) }
                if !t.reverbAutomation.isEmpty { a.reverb.wetDryMix = automationValue(t.reverbAutomation, at: time, default: t.reverb) * 100 }
                if !t.delayAutomation.isEmpty { a.delay.wetDryMix = automationValue(t.delayAutomation, at: time, default: t.delay) * 100 }
                if !t.eqLowAutomation.isEmpty { a.eq.bands[0].gain = automationValue(t.eqLowAutomation, at: time, default: t.eqLow) }
                if !t.eqMidAutomation.isEmpty { a.eq.bands[1].gain = automationValue(t.eqMidAutomation, at: time, default: t.eqMid) }
                if !t.eqHighAutomation.isEmpty { a.eq.bands[2].gain = automationValue(t.eqHighAutomation, at: time, default: t.eqHigh) }
            }
        }

        // Render up to a target sample, writing each chunk. When automation is present,
        // step at ~control rate so envelopes are applied smoothly.
        let autoStep: AVAudioFrameCount = automated.isEmpty ? buffer.frameCapacity : 2048
        func renderUpTo(_ target: AVAudioFramePosition) throws {
            while engine.manualRenderingSampleTime < target {
                let cur = engine.manualRenderingSampleTime
                if !automated.isEmpty { updateAutomation(at: from + Double(cur) / sampleRate) }
                let remaining = target - cur
                let toRender = min(min(AVAudioFrameCount(remaining), buffer.frameCapacity), autoStep)
                switch try engine.renderOffline(toRender, to: buffer) {
                case .success:
                    try outputFile.write(from: buffer)
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw ExportError.renderFailed
                @unknown default:
                    throw ExportError.renderFailed
                }
            }
        }

        // Render to each MIDI event's time, fire it, then finish — sample-accurate.
        let sortedEvents = midiEvents.sorted { $0.sample < $1.sample }
        for event in sortedEvents where event.sample < totalFrames {
            try renderUpTo(event.sample)
            if event.isOn {
                MIDISupport.noteOn(event.au, pitch: event.pitch, velocity: event.velocity, channel: event.channel)
            } else {
                MIDISupport.noteOff(event.au, pitch: event.pitch, channel: event.channel)
            }
        }
        try renderUpTo(totalFrames)

        players.forEach { $0.stop() }
        engine.stop()
    }

    /// Peak-normalize a rendered WAV in place to `targetPeak` (≈ −1 dBFS by default).
    static func normalizeFile(at url: URL, targetPeak: Float = 0.89) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), channels = Int(format.channelCount)

        var peak: Float = 0
        for c in 0..<channels { let p = data[c]; for i in 0..<n { let a = abs(p[i]); if a > peak { peak = a } } }
        guard peak > 0.0001 else { return }
        let gain = min(targetPeak / peak, 8)            // cap boost to avoid blowing up near-silence
        guard abs(gain - 1) > 0.01 else { return }      // already at target
        for c in 0..<channels { let p = data[c]; for i in 0..<n { p[i] *= gain } }

        // Rewrite via a temp file, then swap.
        let tmp = url.deletingLastPathComponent().appendingPathComponent("norm-\(UUID().uuidString).wav")
        let outFile = try AVAudioFile(forWriting: tmp, settings: format.settings)
        try outFile.write(from: buffer)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
