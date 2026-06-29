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
            let reverb = AVAudioUnitReverb()
            reverb.loadFactoryPreset(.mediumHall)
            reverb.wetDryMix = track.reverb * 100
            engine.attach(player)
            engine.attach(mixer)
            engine.attach(reverb)
            // Connect with the first clip's format so scheduled buffers match.
            let trackFormat = track.clips.first
                .flatMap { try? AVAudioFile(forReading: $0.asset.url).processingFormat }
            // player → mixer → reverb → main (reverb after the mixer → always stereo).
            engine.connect(player, to: mixer, format: trackFormat)
            engine.connect(mixer, to: reverb, format: renderFormat)
            engine.connect(reverb, to: mainMixer, format: renderFormat)

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
