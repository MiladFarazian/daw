import AVFoundation

/// Lightweight one-shot player for auditioning generated candidates,
/// independent of the timeline's AVAudioEngine.
@MainActor
final class PreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: String?
    private var player: AVAudioPlayer?

    /// Toggle playback for a candidate; tapping the one that's playing stops it.
    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        player?.stop()
        guard let newPlayer = try? AVAudioPlayer(contentsOf: url) else { return }
        newPlayer.delegate = self
        newPlayer.play()
        player = newPlayer
        playingID = id
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}
