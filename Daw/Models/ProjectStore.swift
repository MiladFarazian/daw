import SwiftUI
import AVFoundation

/// The in-memory project: tracks, transport state, and the audio engine.
/// (Phase 1 keeps this in memory; SwiftData + a `.daw` document package come later.)
@MainActor
final class ProjectStore: ObservableObject {
    @Published var name = "Untitled"
    @Published var tempo: Double = 120
    @Published var tracks: [Track] = []
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var showImporter = false
    @Published var isImporting = false
    @Published var pixelsPerSecond: Double = 80

    private let engine = AudioEngine()
    private var ticker: Timer?

    /// Timeline length, with a minimum so an empty project still shows a ruler.
    var totalDuration: TimeInterval { max(30, tracks.map(\.endTime).max() ?? 0) }

    // MARK: - Import

    func requestImport() { showImporter = true }

    func importAudio(urls: [URL]) {
        for url in urls { importOne(url) }
    }

    private func importOne(_ url: URL) {
        isImporting = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [self] in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let local = try? LibraryStorage.copyIntoLibrary(url),
                  let waveform = WaveformLoader.load(url: local) else {
                await MainActor.run { self.isImporting = false }
                return
            }
            let asset = AudioAsset(url: local,
                                   duration: waveform.duration,
                                   sampleRate: waveform.sampleRate,
                                   peaks: waveform.peaks)
            await MainActor.run {
                self.addTrack(with: asset)
                self.isImporting = false
            }
        }
    }

    private func addTrack(with asset: AudioAsset) {
        var track = Track(name: asset.name, colorIndex: tracks.count)
        track.clips = [Clip(asset: asset)]
        tracks.append(track)
        engine.prepare(tracks: tracks)
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? stop() : play() }

    func play() {
        guard !tracks.isEmpty else { return }
        if currentTime >= totalDuration { currentTime = 0 }
        let base = currentTime
        engine.play(tracks: tracks, from: base)
        isPlaying = true

        let startedAt = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentTime = base + Date().timeIntervalSince(startedAt)
                if self.currentTime >= self.totalDuration { self.stop() }
            }
        }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(0, time), totalDuration)
        if isPlaying { play() }
    }

    // MARK: - Mixing

    func setVolume(_ track: Track, _ value: Float) { mutate(track) { $0.volume = value } }
    func toggleMute(_ track: Track) { mutate(track) { $0.isMuted.toggle() } }
    func toggleSolo(_ track: Track) { mutate(track) { $0.isSoloed.toggle() } }

    private func mutate(_ track: Track, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        change(&tracks[index])
        engine.applyMix(tracks: tracks)
    }
}
