import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

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
    @Published var useTaste = true
    @Published var lastNudge: [String] = []
    private var lastPrompt: GeneratePrompt?

    @Published var isExporting = false

    let settings: AppSettings
    let taste: TasteEngine
    let recorder: Recorder
    private let engine = AudioEngine()
    private var ticker: Timer?
    private var recordPosition: TimeInterval = 0

    init(settings: AppSettings, taste: TasteEngine, recorder: Recorder) {
        self.settings = settings
        self.taste = taste
        self.recorder = recorder
        recorder.onStarted = { [weak self] in self?.handleRecordingStarted() }
        recorder.onFinish = { [weak self] url in self?.placeRecording(url, at: self?.recordPosition ?? 0) }
        recorder.onError = { [weak self] message in self?.lastError = message }
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

    // MARK: - Recording

    func toggleRecord() {
        recorder.isRecording ? stopRecording() : startRecording()
    }

    func toggleMonitoring() { recorder.toggleMonitoring() }

    private func startRecording() {
        if isPlaying { stop() }
        recordPosition = currentTime >= totalDuration ? 0 : currentTime
        currentTime = recordPosition
        recorder.startRecording() // calls back to handleRecordingStarted when capture begins
    }

    private func stopRecording() {
        recorder.stopRecording()  // fires onFinish → placeRecording
        stop()
    }

    /// Once capture is live, roll the existing tracks so you can perform along.
    private func handleRecordingStarted() {
        if !tracks.isEmpty { play() }
    }

    /// Drop the finished take on a new track at the position recording started.
    private func placeRecording(_ url: URL, at position: TimeInterval) {
        Task.detached(priority: .userInitiated) {
            guard let waveform = WaveformLoader.load(url: url) else { return }
            let asset = AudioAsset(url: url,
                                   duration: waveform.duration,
                                   sampleRate: waveform.sampleRate,
                                   peaks: waveform.peaks)
            await MainActor.run { self.addNamedTrack(name: "Recording", asset: asset, at: position) }
        }
    }

    private func addNamedTrack(name: String, asset: AudioAsset, at position: TimeInterval = 0) {
        var track = Track(name: name, colorIndex: tracks.count)
        track.clips = [Clip(asset: asset, startTime: position)]
        tracks.append(track)
        engine.prepare(tracks: tracks)
    }

    // MARK: - AI (Music.ai)

    /// Split a clip into stems; each returned stem becomes a new track.
    func splitStems(of clip: Clip) {
        let asset = clip.asset
        Task {
            do {
                let result = try await runWorkflow(label: "Stems · \(clip.name)", workflow: settings.stemsWorkflow, asset: asset)
                try await importStems(result, baseName: asset.name)
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Analyze a clip (key / BPM / chords …) and present the result.
    func analyze(_ clip: Clip) {
        let asset = clip.asset
        Task {
            do {
                let result = try await runWorkflow(label: "Analyze · \(clip.name)", workflow: settings.analyzeWorkflow, asset: asset)
                activeSheet = .analysis(AnalysisResult(title: asset.name, result: result))
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Clean up a take (de-reverb / denoise / clarity) onto a new track.
    func enhanceVocal(_ clip: Clip) {
        let asset = clip.asset
        Task {
            do {
                let result = try await runWorkflow(label: "Enhance · \(clip.name)", workflow: settings.enhanceWorkflow, asset: asset)
                let enhanced = try await assetFromResult(result, name: "\(asset.name)-enhanced")
                addNamedTrack(name: "\(asset.name) · enhanced", asset: enhanced)
            } catch { lastError = error.localizedDescription }
        }
    }

    /// AI master a clip onto a new track.
    func master(_ clip: Clip) {
        let asset = clip.asset
        Task {
            do {
                let result = try await runWorkflow(label: "Master · \(clip.name)", workflow: settings.masterWorkflow, asset: asset)
                let mastered = try await assetFromResult(result, name: "\(asset.name)-mastered")
                addNamedTrack(name: "\(asset.name) · mastered", asset: mastered)
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Hero recipe — Vocal Rescue: enhance the take, then master it, into one polished track.
    func vocalRescue(_ clip: Clip) {
        let asset = clip.asset
        Task {
            do {
                let enhanceResult = try await runWorkflow(label: "Rescue · enhance · \(clip.name)", workflow: settings.enhanceWorkflow, asset: asset)
                let enhanced = try await assetFromResult(enhanceResult, name: "\(asset.name)-enhanced")
                let masterResult = try await runWorkflow(label: "Rescue · master · \(clip.name)", workflow: settings.masterWorkflow, asset: enhanced)
                let rescued = try await assetFromResult(masterResult, name: "\(asset.name)-rescued")
                addNamedTrack(name: "\(asset.name) · rescued", asset: rescued)
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Run one Music.ai workflow on an asset, managing its progress entry; returns the result.
    private func runWorkflow(label: String, workflow: String, asset: AudioAsset) async throws -> [String: String] {
        guard let manager = jobManager else { throw AIError.noAPIKey }
        let progress = JobProgress(label: label)
        let jobID = progress.id
        activeJobs.append(progress)
        defer { removeJob(jobID) }
        return try await manager.run(workflow: workflow, fileURL: asset.url, name: label) { status in
            Task { @MainActor in self.setJobStatus(jobID, status) }
        }
    }

    /// Pick the first output audio URL from a job result and download it as an asset.
    private func assetFromResult(_ result: [String: String], name: String) async throws -> AudioAsset {
        guard let urlString = result.values.first(where: { $0.hasPrefix("http") }),
              let url = URL(string: urlString) else {
            throw AIError.malformed("no output audio in result")
        }
        return try await assetFromRemote(url, name: name, defaultExt: "wav")
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
        // Bias toward learned taste (the original prompt is what we reinforce on keep).
        let effective: GeneratePrompt
        if useTaste {
            let biased = taste.bias(prompt)
            effective = biased.prompt
            lastNudge = biased.added
        } else {
            effective = prompt
            lastNudge = []
        }
        lastPrompt = prompt

        let client = SunoSidecarClient(baseURL: settings.sunoSidecarURL)
        let progress = JobProgress(label: "Generate · \(prompt.shortLabel)")
        let jobID = progress.id
        activeJobs.append(progress)
        isGenerating = true
        candidates.removeAll()

        Task {
            do {
                let generated = try await client.generate(effective) { status in
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

    /// Keep a candidate: add it to the timeline and reinforce your taste.
    func addCandidate(_ candidate: CandidateAsset) {
        addNamedTrack(name: candidate.title, asset: candidate.asset)
        if let prompt = lastPrompt { taste.recordKeep(prompt) }
        candidates.removeAll { $0.id == candidate.id }
    }

    /// Reject a candidate: drop it and nudge your taste away from this prompt.
    func discardCandidate(_ candidate: CandidateAsset) {
        if let prompt = lastPrompt { taste.recordReject(prompt) }
        candidates.removeAll { $0.id == candidate.id }
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

    func deleteTrack(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
    }

    // MARK: - Clip editing

    private let minClipDuration: TimeInterval = 0.1

    /// Move a clip along the timeline by a pixel delta.
    func moveClip(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { $0.startTime = max(0, $0.startTime + delta) }
    }

    /// Drag the left edge: trims into / out of the asset head while holding the right edge fixed.
    func trimClipStart(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { c in
            let d = min(max(delta, -c.offset), c.duration - minClipDuration)
            c.offset += d
            c.startTime = max(0, c.startTime + d)
            c.duration -= d
        }
    }

    /// Drag the right edge: extends/trims the visible length within the asset.
    func trimClipEnd(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { c in
            let maxExtend = c.asset.duration - c.offset - c.duration
            c.duration += min(max(delta, -(c.duration - minClipDuration)), maxExtend)
        }
    }

    private func updateClip(_ clip: Clip, on track: Track, _ change: (inout Clip) -> Void) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        change(&tracks[ti].clips[ci])
    }

    // MARK: - Export

    func exportMixdown() {
        guard !tracks.isEmpty, !isExporting else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(name).wav"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = tracks
        let duration = totalDuration
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try AudioExporter.render(tracks: snapshot, duration: duration, to: url)
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Project save / load

    private static let projectType = UTType(filenameExtension: "gosan") ?? .json

    func newProject() {
        stop()
        engine.reset()
        tracks = []
        candidates = []
        name = "Untitled"
        currentTime = 0
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "\(name).gosan"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(snapshotDocument())
            try data.write(to: url)
            name = url.deletingPathExtension().lastPathComponent
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            Task { await applyDocument(document) }
        } catch {
            lastError = "Open failed: \(error.localizedDescription)"
        }
    }

    private func snapshotDocument() -> ProjectDocument {
        ProjectDocument(
            name: name, tempo: tempo, pixelsPerSecond: pixelsPerSecond,
            tracks: tracks.map { track in
                ProjectDocument.TrackData(
                    name: track.name, colorIndex: track.colorIndex,
                    volume: track.volume, pan: track.pan,
                    isMuted: track.isMuted, isSoloed: track.isSoloed,
                    clips: track.clips.map { clip in
                        ProjectDocument.ClipData(
                            assetFile: clip.asset.url.lastPathComponent,
                            assetName: clip.asset.name,
                            sampleRate: clip.asset.sampleRate,
                            assetDuration: clip.asset.duration,
                            startTime: clip.startTime, offset: clip.offset, duration: clip.duration)
                    })
            })
    }

    private func applyDocument(_ document: ProjectDocument) async {
        stop()
        engine.reset()
        let importsDir = try? LibraryStorage.importsDirectory()
        var assetCache: [String: AudioAsset] = [:]
        var rebuilt: [Track] = []

        for trackData in document.tracks {
            var track = Track(name: trackData.name, colorIndex: trackData.colorIndex)
            track.volume = trackData.volume
            track.pan = trackData.pan
            track.isMuted = trackData.isMuted
            track.isSoloed = trackData.isSoloed

            var clips: [Clip] = []
            for clipData in trackData.clips {
                let asset: AudioAsset
                if let cached = assetCache[clipData.assetFile] {
                    asset = cached
                } else if let dir = importsDir {
                    let url = dir.appendingPathComponent(clipData.assetFile)
                    let peaks = await Task.detached(priority: .userInitiated) {
                        WaveformLoader.load(url: url)?.peaks ?? []
                    }.value
                    asset = AudioAsset(url: url, duration: clipData.assetDuration,
                                       sampleRate: clipData.sampleRate, peaks: peaks)
                    assetCache[clipData.assetFile] = asset
                } else {
                    continue
                }
                var clip = Clip(asset: asset, startTime: clipData.startTime)
                clip.offset = clipData.offset
                clip.duration = clipData.duration
                clips.append(clip)
            }
            track.clips = clips
            rebuilt.append(track)
        }

        name = document.name
        tempo = document.tempo
        pixelsPerSecond = document.pixelsPerSecond
        currentTime = 0
        tracks = rebuilt
        engine.prepare(tracks: rebuilt)
    }
}
