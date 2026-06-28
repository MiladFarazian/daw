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

    // AI job state, surfaced in the UI.
    @Published var activeJobs: [JobProgress] = []
    @Published var lastError: String?
    @Published var presentedAnalysis: AnalysisResult?

    let settings: AppSettings
    private let engine = AudioEngine()
    private var ticker: Timer?

    init(settings: AppSettings) {
        self.settings = settings
    }

    private var jobManager: JobManager? {
        settings.hasAPIKey ? JobManager(client: MusicAIClient(apiKey: settings.apiKey)) : nil
    }

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
        addNamedTrack(name: asset.name, asset: asset)
    }

    private func addNamedTrack(name: String, asset: AudioAsset) {
        var track = Track(name: name, colorIndex: tracks.count)
        track.clips = [Clip(asset: asset)]
        tracks.append(track)
        engine.prepare(tracks: tracks)
    }

    // MARK: - AI (Music.ai)

    /// Split a clip into stems; each returned stem becomes a new track.
    func splitStems(of clip: Clip) {
        runJob(label: "Stems · \(clip.name)", workflow: settings.stemsWorkflow, asset: clip.asset) { result, baseName in
            try await self.importStems(result, baseName: baseName)
        }
    }

    /// Analyze a clip (key / BPM / chords …) and present the result.
    func analyze(_ clip: Clip) {
        runJob(label: "Analyze · \(clip.name)", workflow: settings.analyzeWorkflow, asset: clip.asset) { result, baseName in
            self.presentedAnalysis = AnalysisResult(title: baseName, result: result)
        }
    }

    private func runJob(label: String,
                        workflow: String,
                        asset: AudioAsset,
                        onSuccess: @escaping ([String: String], String) async throws -> Void) {
        guard let manager = jobManager else {
            lastError = AIError.noAPIKey.errorDescription
            return
        }
        let progress = JobProgress(label: label)
        let jobID = progress.id
        activeJobs.append(progress)

        Task {
            do {
                let result = try await manager.run(workflow: workflow, fileURL: asset.url, name: label) { status in
                    Task { @MainActor in self.setJobStatus(jobID, status) }
                }
                try await onSuccess(result, asset.name)
                removeJob(jobID)
            } catch {
                removeJob(jobID)
                lastError = error.localizedDescription
            }
        }
    }

    private func importStems(_ result: [String: String], baseName: String) async throws {
        let stems = result.filter { $0.value.hasPrefix("http") }.sorted { $0.key < $1.key }
        guard !stems.isEmpty else { throw AIError.malformed("no stem URLs in result") }

        for (stemName, urlString) in stems {
            guard let url = URL(string: urlString) else { continue }
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let ext = url.pathExtension.isEmpty ? "wav" : url.pathExtension
            let local = try LibraryStorage.adopt(tempURL: tempURL, suggestedName: "\(baseName)-\(stemName).\(ext)")
            guard let waveform = await Task.detached(priority: .userInitiated, operation: {
                WaveformLoader.load(url: local)
            }).value else { continue }
            let asset = AudioAsset(url: local,
                                   duration: waveform.duration,
                                   sampleRate: waveform.sampleRate,
                                   peaks: waveform.peaks)
            addNamedTrack(name: "\(baseName) · \(stemName)", asset: asset)
        }
    }

    private func setJobStatus(_ id: UUID, _ status: String) {
        if let index = activeJobs.firstIndex(where: { $0.id == id }) {
            activeJobs[index].status = status
        }
    }

    private func removeJob(_ id: UUID) {
        activeJobs.removeAll { $0.id == id }
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
