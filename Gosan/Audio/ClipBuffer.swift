import AVFoundation

/// Reads a segment of an audio file into a buffer and applies linear fade-in/out.
/// Shared by live playback and offline export so fades are identical in both.
enum ClipBuffer {
    static func faded(file: AVAudioFile,
                      startFrame: AVAudioFramePosition,
                      frames: AVAudioFrameCount,
                      fadeInFrames: Int,
                      fadeOutFrames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return nil }
        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frames)
        } catch { return nil }

        let n = Int(buffer.frameLength)
        guard n > 0, let data = buffer.floatChannelData else { return buffer }
        let channels = Int(file.processingFormat.channelCount)
        let fin = min(fadeInFrames, n)
        let fout = min(fadeOutFrames, n)
        for c in 0..<channels {
            let p = data[c]
            if fin > 0 { for i in 0..<fin { p[i] *= Float(i) / Float(fin) } }
            if fout > 0 { for i in 0..<fout { p[n - 1 - i] *= Float(i) / Float(fout) } }
        }
        return buffer
    }
}
