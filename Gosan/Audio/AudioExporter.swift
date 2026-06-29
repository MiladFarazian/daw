import AVFoundation

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

    static func render(tracks: [Track], duration: TimeInterval, to url: URL, sampleRate: Double = 44_100) throws {
        let totalFrames = AVAudioFramePosition((duration * sampleRate).rounded(.up))
        guard totalFrames > 0,
              let renderFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw ExportError.noContent
        }

        let engine = AVAudioEngine()
        let mainMixer = engine.mainMixerNode
        let soloing = tracks.contains { $0.isSoloed }

        // One player per track, scheduled at timeline positions.
        var players: [AVAudioPlayerNode] = []
        for track in tracks {
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 3)
            eq.bands[0].filterType = .lowShelf; eq.bands[0].frequency = 120; eq.bands[0].gain = track.eqLow; eq.bands[0].bypass = false
            eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 1000; eq.bands[1].bandwidth = 1.0; eq.bands[1].gain = track.eqMid; eq.bands[1].bypass = false
            eq.bands[2].filterType = .highShelf; eq.bands[2].frequency = 8000; eq.bands[2].gain = track.eqHigh; eq.bands[2].bypass = false
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = track.reverb * 100
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.33; delay.feedback = 30; delay.wetDryMix = track.delay * 100
            [player, mixer, eq, reverb, delay].forEach { engine.attach($0) }
            // Connect with the first clip's format so scheduled buffers match.
            let trackFormat = track.clips.first
                .flatMap { try? AVAudioFile(forReading: $0.asset.url).processingFormat }
            // player → mixer → eq → reverb → delay → main (effects after the mixer → stereo).
            engine.connect(player, to: mixer, format: trackFormat)
            engine.connect(mixer, to: eq, format: renderFormat)
            engine.connect(eq, to: reverb, format: renderFormat)
            engine.connect(reverb, to: delay, format: renderFormat)
            engine.connect(delay, to: mainMixer, format: renderFormat)

            let audible = soloing ? track.isSoloed : !track.isMuted
            mixer.outputVolume = audible ? track.volume : 0
            mixer.pan = track.pan

            for clip in track.clips {
                guard let file = try? AVAudioFile(forReading: clip.asset.url) else { continue }
                let fileRate = file.processingFormat.sampleRate
                let startFrame = AVAudioFramePosition(clip.offset * fileRate)
                let wanted = AVAudioFramePosition(clip.duration * fileRate)
                let frames = AVAudioFrameCount(max(0, min(wanted, file.length - startFrame)))
                guard frames > 0 else { continue }
                let when = AVAudioTime(sampleTime: AVAudioFramePosition(clip.startTime * sampleRate), atRate: sampleRate)
                if let buffer = ClipBuffer.faded(file: file, startFrame: startFrame, frames: frames,
                                                 fadeInFrames: Int(clip.fadeIn * fileRate),
                                                 fadeOutFrames: Int(clip.fadeOut * fileRate),
                                                 gain: clip.gain) {
                    player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
                }
            }
            players.append(player)
        }

        try engine.enableManualRenderingMode(.offline, format: renderFormat,
                                             maximumFrameCount: 4096)
        try engine.start()
        players.forEach { $0.play() }

        let outputFile = try AVAudioFile(forWriting: url, settings: renderFormat.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                            frameCapacity: engine.manualRenderingMaximumFrameCount) else {
            throw ExportError.renderFailed
        }

        while engine.manualRenderingSampleTime < totalFrames {
            let remaining = totalFrames - engine.manualRenderingSampleTime
            let toRender = min(AVAudioFrameCount(remaining), buffer.frameCapacity)
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

        players.forEach { $0.stop() }
        engine.stop()
    }
}
