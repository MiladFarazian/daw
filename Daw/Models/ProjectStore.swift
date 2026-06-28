import SwiftUI
import AVFoundation
import AppKit

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
    @Published var activeSheet: EditorSheet?

    // Suno generation state.
    @Published var isGenerating = false
    @Published var candidates: [CandidateAsset] = []

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
            self.activeSheet = .analysis(AnalysisResult(title: baseName, result: result))
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
            let asset = try await assetFromRemote(url, name: "\(baseName)-\(stemName)", defaultExt: "wav")
            addNamedTrack(name: "\(baseName) · \(stemName)", asset: asset)
        }
    }

    /// Download a remote audio URL into the library and build an AudioAsset (with waveform).
    private func assetFromRemote(_ url: URL, name: String, defaultExt: String) async throws -> AudioAsset {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let ext = url.pathExtension.isEmpty ? defaultExt : url.pathExtension
        let local = try LibraryStorage.adopt(tempURL: tempURL, suggestedName: "\(name).\(ext)")
        guard let waveform = await Task.detached(priority: .userInitiated, operation: {
            WaveformLoader.load(url: local)
        }).value else {
            throw AIError.malformed("could not decode \(name)")
        }
        return AudioAsset(url: local,
                          duration: waveform.duration,
                          sampleRate: waveform.sampleRate,
                          peaks: waveform.peaks)
    }

    // MARK: - Suno generation

    func generate(_ prompt: GeneratePrompt) {
        let client = SunoSidecarClient(baseURL: settings.sunoSidecarURL)
        let progress = JobProgress(label: "Generate · \(prompt.shortLabel)")
        let jobID = progress.id
        activeJobs.append(progress)
        isGenerating = true
        candidates.removeAll()

        Task {
            do {
                let generated = try await client.generate(prompt) { status in
                    Task { @MainActor in self.setJobStatus(jobID, status) }
                }
                for candidate in generated {
                    let asset = try await assetFromRemote(candidate.audioURL, name: candidate.title, defaultExt: "mp3")
                    candidates.append(CandidateAsset(id: candidate.id, title: candidate.title, asset: asset))
                }
                removeJob(jobID)
                isGenerating = false
            } catch {
                removeJob(jobID)
                isGenerating = false
                lastError = error.localizedDescription
            }
        }
    }

    /// Add a generated candidate to the timeline as a new track.
    func addCandidate(_ candidate: CandidateAsset) {
        addNamedTrack(name: candidate.title, asset: candidate.asset)
    }

    /// Manual bridge: copy the compiled prompt and open Suno. Result is dragged back in.
    func openInSunoManually(_ prompt: GeneratePrompt) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt.compiled, forType: .string)
        if let url = URL(string: "https://suno.com/create") {
            NSWorkspace.shared.open(url)
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
