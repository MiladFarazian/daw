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
    @Published var sidecarReachable: Bool?
    private var lastPrompt: GeneratePrompt?

    @Published var isExporting = false
    @Published var selectedClipID: UUID?
    @Published var snapEnabled = true
    @Published var snapDivision: Double = 0.25   // in beats (4 = bar, 1 = beat, 0.25 = 1/4 beat)
    @Published var clipboard: Clip?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [[Track]] = []
    private var redoStack: [[Track]] = []

    @Published var loopEnabled = false
    @Published var loopStart: TimeInterval = 0
    @Published var loopEnd: TimeInterval = 0
    var loopActive: Bool { loopEnabled && loopEnd > loopStart + 0.05 }
    @Published var metronomeEnabled = false
    @Published var countInEnabled = false
    @Published var markers: [Marker] = []
    private var tapTimes: [Date] = []

    /// Tap repeatedly to set the tempo from the average interval.
    func tapTempo() {
        let now = Date()
        if let last = tapTimes.last, now.timeIntervalSince(last) > 2.0 { tapTimes = [] }
        tapTimes.append(now)
        if tapTimes.count > 6 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }
        var intervals: [TimeInterval] = []
        for i in 1..<tapTimes.count { intervals.append(tapTimes[i].timeIntervalSince(tapTimes[i - 1])) }
        let avg = intervals.reduce(0, +) / Double(intervals.count)
        if avg > 0 { tempo = min(300, max(30, (60.0 / avg).rounded())) }
    }
    @Published var masterEqLow: Float = 0
    @Published var masterEqMid: Float = 0
    @Published var masterEqHigh: Float = 0
    @Published var beatsPerBar: Int = 4   // time signature numerator (over /4)

    func setMasterEQ(low: Float, mid: Float, high: Float) {
        masterEqLow = low; masterEqMid = mid; masterEqHigh = high
        engine.setMasterEQ(low: low, mid: mid, high: high)
    }

    let settings: AppSettings
    let taste: TasteEngine
    let recorder: Recorder
    private let engine = AudioEngine()
    private var ticker: Timer?
    private var recordPosition: TimeInterval = 0

    @Published var masterLevel: Float = 0

    init(settings: AppSettings, taste: TasteEngine, recorder: Recorder) {
        self.settings = settings
        self.taste = taste
        self.recorder = recorder
        recorder.onStarted = { [weak self] in self?.handleRecordingStarted() }
        recorder.onFinish = { [weak self] url in self?.placeRecording(url, at: self?.recordPosition ?? 0) }
        recorder.onError = { [weak self] message in self?.lastError = message }
        engine.onLevel = { [weak self] level in
            Task { @MainActor in self?.masterLevel = level }
        }
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

    /// Drop one or more files onto an existing track at a timeline position.
    func importAudio(urls: [URL], onto track: Track, at position: TimeInterval) {
        for url in urls { importOne(url, ontoTrackID: track.id, at: max(0, position)) }
    }

    private func importOne(_ url: URL, ontoTrackID: UUID? = nil, at position: TimeInterval = 0) {
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
                if let trackID = ontoTrackID {
                    self.addClip(asset: asset, toTrackID: trackID, at: position)
                } else {
                    self.addTrack(with: asset)
                }
                self.isImporting = false
            }
        }
    }

    private func addTrack(with asset: AudioAsset) {
        addNamedTrack(name: asset.name, asset: asset)
    }

    /// Download a YouTube (or other yt-dlp) URL's audio and add it as a new track.
    func importFromYouTube(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isImporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let dir = try LibraryStorage.importsDirectory()
                let file = try YouTubeImporter.download(url: trimmed, into: dir)
                guard let waveform = WaveformLoader.load(url: file) else {
                    throw YouTubeImporter.YTError.failed("Couldn't decode the audio (try a different video, or install ffmpeg).")
                }
                let asset = AudioAsset(url: file, duration: waveform.duration,
                                       sampleRate: waveform.sampleRate, peaks: waveform.peaks)
                await MainActor.run {
                    self.addNamedTrack(name: asset.name, asset: asset)
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.lastError = error.localizedDescription
                }
            }
        }
    }

    private func addClip(asset: AudioAsset, toTrackID: UUID, at position: TimeInterval) {
        guard let index = tracks.firstIndex(where: { $0.id == toTrackID }) else { return }
        recordUndo()
        tracks[index].clips.append(Clip(asset: asset, startTime: position))
        engine.prepare(tracks: tracks)
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
        if countInEnabled {
            engine.playCountIn(tempo: tempo, beatsPerBar: beatsPerBar) { [weak self] in
                self?.recorder.startRecording()
            }
        } else {
            recorder.startRecording() // calls back to handleRecordingStarted when capture begins
        }
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
        recordUndo()
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

    /// Probe whether the Suno sidecar is up, for the Generate panel's status dot.
    func checkSidecar() {
        let client = SunoSidecarClient(baseURL: settings.sunoSidecarURL)
        sidecarReachable = nil
        Task { sidecarReachable = await client.isReachable() }
    }

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

    /// Manual bridge: export a clip and open Moises so you can split/enhance it in the
    /// app you already use, then drag the results back onto the timeline.
    func sendClipToMoises(_ clip: Clip) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(clip.name).wav"
        panel.message = "Save this clip, then upload it to Moises to split stems / enhance — and drag the results back in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var track = Track(name: clip.name, colorIndex: 0)
        var solo = clip; solo.startTime = 0
        track.clips = [solo]
        let duration = clip.duration
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try AudioExporter.render(tracks: [track], duration: duration, to: url)
                await MainActor.run {
                    self.isExporting = false
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    if let moises = URL(string: "https://moises.ai") { NSWorkspace.shared.open(moises) }
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
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
        engine.play(tracks: tracks, from: base, metronome: metronomeEnabled, tempo: tempo, beatsPerBar: beatsPerBar)
        isPlaying = true

        let startedAt = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentTime = base + Date().timeIntervalSince(startedAt)
                if self.loopActive && self.currentTime >= self.loopEnd {
                    self.seek(to: self.loopStart) // restarts playback from the loop start
                } else if self.currentTime >= self.totalDuration {
                    self.stop()
                }
            }
        }
    }

    func stop() {
        engine.stop()
        isPlaying = false
        masterLevel = 0
        ticker?.invalidate()
        ticker = nil
    }

    func seek(to time: TimeInterval) {
        currentTime = min(max(0, time), totalDuration)
        if isPlaying { play() }
    }

    func setLoop(_ start: TimeInterval, _ end: TimeInterval) {
        loopStart = max(0, min(start, end))
        loopEnd = max(start, end)
        loopEnabled = true
    }

    func toggleLoop() { loopEnabled.toggle() }

    func toggleMetronome() {
        metronomeEnabled.toggle()
        if isPlaying { play() } // re-schedule clicks
    }

    // MARK: - Markers

    func addMarker() {
        markers.append(Marker(time: currentTime, name: "Marker \(markers.count + 1)"))
        markers.sort { $0.time < $1.time }
    }

    func deleteMarker(_ marker: Marker) { markers.removeAll { $0.id == marker.id } }

    func jumpToNextMarker() {
        if let m = markers.first(where: { $0.time > currentTime + 0.01 }) { seek(to: m.time) }
    }

    func jumpToPrevMarker() {
        if let m = markers.last(where: { $0.time < currentTime - 0.01 }) { seek(to: m.time) }
    }

    // MARK: - Mixing

    func setVolume(_ track: Track, _ value: Float) { mutate(track) { $0.volume = value } }
    func setPan(_ track: Track, _ value: Float) { mutate(track) { $0.pan = value } }
    func setReverb(_ track: Track, _ value: Float) { mutate(track) { $0.reverb = value } }
    func setDelay(_ track: Track, _ value: Float) { mutate(track) { $0.delay = value } }
    func setCompress(_ track: Track, _ value: Float) { mutate(track) { $0.compress = value } }
    func setEQ(_ track: Track, low: Float, mid: Float, high: Float) {
        mutate(track) { $0.eqLow = low; $0.eqMid = mid; $0.eqHigh = high }
    }
    func toggleMute(_ track: Track) { recordUndo(); mutate(track) { $0.isMuted.toggle() } }
    func toggleSolo(_ track: Track) { recordUndo(); mutate(track) { $0.isSoloed.toggle() } }

    private func mutate(_ track: Track, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        change(&tracks[index])
        engine.applyMix(tracks: tracks)
    }

    func deleteTrack(_ track: Track) {
        recordUndo()
        tracks.removeAll { $0.id == track.id }
    }

    func addEmptyTrack() {
        recordUndo()
        let track = Track(name: "Track \(tracks.count + 1)", colorIndex: tracks.count)
        tracks.append(track)
        engine.prepare(tracks: tracks)
    }

    func renameTrack(_ track: Track, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(track) { $0.name = trimmed }
    }

    func moveTrack(_ track: Track, by offset: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let j = i + offset
        guard j >= 0, j < tracks.count else { return }
        recordUndo()
        tracks.swapAt(i, j)
    }

    func setTrackColor(_ track: Track, _ index: Int) {
        mutate(track) { $0.colorIndex = index }
    }

    // MARK: - Clip editing

    private let minClipDuration: TimeInterval = 0.1

    func selectClip(_ id: UUID?) { selectedClipID = id }

    // MARK: - Undo / redo (snapshots of the track state)

    private func recordUndo() {
        undoStack.append(tracks)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(tracks)
        applyTrackState(previous)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(tracks)
        applyTrackState(next)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func applyTrackState(_ newTracks: [Track]) {
        stop()
        selectedClipID = nil
        tracks = newTracks
        engine.reset()
        engine.prepare(tracks: newTracks)
    }

    /// Snap a time to the nearest grid division when snapping is on.
    private func snapped(_ time: TimeInterval) -> TimeInterval {
        guard snapEnabled, tempo > 0, snapDivision > 0 else { return max(0, time) }
        let grid = (60.0 / tempo) * snapDivision
        return max(0, (time / grid).rounded() * grid)
    }

    /// Move a clip along the timeline by a pixel delta (snapped on release).
    func moveClip(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        recordUndo()
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { $0.startTime = self.snapped($0.startTime + delta) }
    }

    func deleteClip(_ clip: Clip, on track: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[ti].clips.removeAll { $0.id == clip.id }
        if tracks[ti].clips.isEmpty { tracks.remove(at: ti) }
        if selectedClipID == clip.id { selectedClipID = nil }
    }

    /// Whether the playhead falls strictly inside a clip (so a split is meaningful).
    func canSplit(_ clip: Clip) -> Bool {
        currentTime > clip.startTime + minClipDuration
            && currentTime < clip.startTime + clip.duration - minClipDuration
    }

    /// Cut a clip in two at the playhead; both halves reference the same asset.
    func splitClipAtPlayhead(_ clip: Clip, on track: Track) {
        guard canSplit(clip),
              let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        recordUndo()
        let into = currentTime - clip.startTime

        var left = clip
        left.duration = into

        var right = Clip(asset: clip.asset, startTime: currentTime)
        right.offset = clip.offset + into
        right.duration = clip.duration - into

        tracks[ti].clips[ci] = left
        tracks[ti].clips.insert(right, at: ci + 1)
    }

    func setFadeIn(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        recordUndo()
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { c in
            c.fadeIn = min(max(0, c.fadeIn + delta), c.duration - c.fadeOut)
        }
    }

    func setFadeOut(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        recordUndo()
        let delta = TimeInterval(dx) / pixelsPerSecond
        updateClip(clip, on: track) { c in
            c.fadeOut = min(max(0, c.fadeOut - delta), c.duration - c.fadeIn)
        }
    }

    func setClipGain(_ clip: Clip, on track: Track, db: Double) {
        recordUndo()
        let gain = Float(pow(10.0, db / 20.0))
        updateClip(clip, on: track) { $0.gain = gain }
    }

    func toggleClipMute(_ clip: Clip, on track: Track) {
        recordUndo()
        updateClip(clip, on: track) { $0.muted.toggle() }
    }

    func setFadeCurve(_ clip: Clip, on track: Track, equalPower: Bool) {
        recordUndo()
        updateClip(clip, on: track) { $0.fadeCurve = equalPower ? 1 : 0 }
    }

    /// Crossfade a clip with the next clip it overlaps on the same track (equal-power).
    func crossfadeWithNext(_ clip: Clip, on track: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let aEnd = clip.startTime + clip.duration
        let next = tracks[ti].clips.enumerated()
            .filter { $0.element.id != clip.id && $0.element.startTime > clip.startTime && $0.element.startTime < aEnd }
            .min { $0.element.startTime < $1.element.startTime }
        guard let next else { return }
        let overlap = aEnd - next.element.startTime
        guard overlap > 0.02 else { return }
        recordUndo()
        tracks[ti].clips[ci].fadeOut = overlap
        tracks[ti].clips[ci].fadeCurve = 1
        tracks[ti].clips[next.offset].fadeIn = overlap
        tracks[ti].clips[next.offset].fadeCurve = 1
    }

    /// Snap a clip's start to the nearest grid division (regardless of the snap toggle).
    func quantizeClip(_ clip: Clip, on track: Track) {
        guard tempo > 0, snapDivision > 0 else { return }
        let grid = (60.0 / tempo) * snapDivision
        recordUndo()
        updateClip(clip, on: track) { $0.startTime = max(0, ($0.startTime / grid).rounded() * grid) }
    }

    /// Trim near-silence from a clip's head and tail.
    func trimSilence(_ clip: Clip, on track: Track) {
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        Task.detached(priority: .userInitiated) {
            guard let bounds = ClipProcessing.silenceBounds(url: url, offset: offset, duration: duration),
                  bounds.leading + bounds.trailing > 0.02 else { return }
            await MainActor.run {
                self.recordUndo()
                self.updateClip(clip, on: track) { c in
                    c.offset += bounds.leading
                    c.duration = max(0.05, c.duration - bounds.leading - bounds.trailing)
                }
            }
        }
    }

    /// Set the clip's gain so its peak hits ~-1 dBFS (capped to avoid huge boosts).
    func normalizeClip(_ clip: Clip, on track: Track) {
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        Task.detached(priority: .userInitiated) {
            guard let peak = ClipProcessing.peak(url: url, offset: offset, duration: duration), peak > 0 else { return }
            let gain = min(8, 0.891 / peak)
            await MainActor.run {
                self.recordUndo()
                self.updateClip(clip, on: track) { $0.gain = gain }
            }
        }
    }

    /// Bake a time-stretch (rate < 1 = slower/longer; pitch preserved) into the clip.
    func timeStretchClip(_ clip: Clip, on track: Track, rate: Float) {
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        Task.detached(priority: .userInitiated) {
            guard let dir = try? LibraryStorage.importsDirectory(),
                  let stretched = ClipProcessing.timeStretch(url: url, offset: offset, duration: duration,
                                                             rate: rate, outputDir: dir),
                  let waveform = WaveformLoader.load(url: stretched) else { return }
            let asset = AudioAsset(url: stretched, duration: waveform.duration,
                                   sampleRate: waveform.sampleRate, peaks: waveform.peaks)
            await MainActor.run {
                self.recordUndo()
                self.updateClip(clip, on: track) {
                    $0.asset = asset
                    $0.offset = 0
                    $0.duration = asset.duration
                }
                self.engine.prepare(tracks: self.tracks)
            }
        }
    }

    /// Replace the clip's audio with a reversed copy of its current segment.
    func reverseClip(_ clip: Clip, on track: Track) {
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        Task.detached(priority: .userInitiated) {
            guard let dir = try? LibraryStorage.importsDirectory(),
                  let reversed = ClipProcessing.reverse(url: url, offset: offset, duration: duration, outputDir: dir),
                  let waveform = WaveformLoader.load(url: reversed) else { return }
            let asset = AudioAsset(url: reversed, duration: waveform.duration,
                                   sampleRate: waveform.sampleRate, peaks: waveform.peaks)
            await MainActor.run {
                self.recordUndo()
                self.updateClip(clip, on: track) {
                    $0.asset = asset
                    $0.offset = 0
                    $0.duration = asset.duration
                }
                self.engine.prepare(tracks: self.tracks)
            }
        }
    }

    /// Duplicate a clip immediately after itself on the same track.
    func duplicateClip(_ clip: Clip, on track: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        recordUndo()
        tracks[ti].clips.insert(pastedCopy(of: clip, at: clip.startTime + clip.duration), at: ci + 1)
    }

    // MARK: - Copy / paste

    func copyClip(_ clip: Clip) { clipboard = clip }

    func cutClip(_ clip: Clip, on track: Track) {
        clipboard = clip
        deleteClip(clip, on: track)
    }

    /// Paste the clipboard clip onto a track at the playhead.
    func pasteClip(onto track: Track) {
        guard let source = clipboard,
              let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[index].clips.append(pastedCopy(of: source, at: currentTime))
        engine.prepare(tracks: tracks)
    }

    private func pastedCopy(of clip: Clip, at start: TimeInterval) -> Clip {
        var copy = Clip(asset: clip.asset, startTime: max(0, start))
        copy.offset = clip.offset
        copy.duration = clip.duration
        copy.fadeIn = clip.fadeIn
        copy.fadeOut = clip.fadeOut
        copy.gain = clip.gain
        return copy
    }

    /// Drag the left edge: trims into / out of the asset head while holding the right edge fixed.
    func trimClipStart(_ clip: Clip, on track: Track, byPixels dx: CGFloat) {
        recordUndo()
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
        recordUndo()
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

    func exportMixdown(aac: Bool = false) { exportRange(from: 0, duration: totalDuration, name: name, aac: aac) }

    func exportLoop(aac: Bool = false) {
        guard loopActive else { return }
        exportRange(from: loopStart, duration: loopEnd - loopStart, name: "\(name)-loop", aac: aac)
    }

    private func exportRange(from: TimeInterval, duration: TimeInterval, name: String, aac: Bool) {
        guard !tracks.isEmpty, duration > 0, !isExporting else { return }
        let ext = aac ? "m4a" : "wav"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .audio]
        panel.nameFieldStringValue = "\(name).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = tracks
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try AudioExporter.render(tracks: snapshot, duration: duration, to: url, from: from, aac: aac)
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Export each track to its own WAV in a chosen folder.
    func exportStems() {
        guard !tracks.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder — each track is exported as its own WAV."
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let snapshot = tracks
        let duration = totalDuration
        let scoped = dir.startAccessingSecurityScopedResource()
        isExporting = true
        Task.detached(priority: .userInitiated) {
            defer { if scoped { dir.stopAccessingSecurityScopedResource() } }
            do {
                for (index, track) in snapshot.enumerated() where !track.clips.isEmpty {
                    let safe = track.name.replacingOccurrences(of: "/", with: "-")
                    let url = dir.appendingPathComponent("\(index + 1)-\(safe).wav")
                    try AudioExporter.render(tracks: [track], duration: duration, to: url)
                }
                await MainActor.run { self.isExporting = false }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Stem export failed: \(error.localizedDescription)"
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
        markers = []
        setMasterEQ(low: 0, mid: 0, high: 0)
        name = "Untitled"
        currentTime = 0
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = "\(name).gosan"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != "gosan" { url.appendPathExtension("gosan") }

        // Bundle every referenced asset into the package so it's portable.
        var assetURLs: [String: URL] = [:]
        for track in tracks {
            for clip in track.clips { assetURLs[clip.asset.url.lastPathComponent] = clip.asset.url }
        }
        do {
            try ProjectPackage.write(snapshotDocument(), assetURLs: assetURLs, to: url)
            name = url.deletingPathExtension().lastPathComponent
            settings.addRecent(url)
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProjectAt(url)
    }

    /// Open a specific .gosan package (used by the Open Recent menu).
    func openProjectAt(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            settings.recentProjects.removeAll { $0 == url.path }
            lastError = "That project no longer exists at \(url.path)."
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let (document, audioDir) = try ProjectPackage.read(url)
            settings.addRecent(url)
            Task {
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                await applyDocument(document, audioDir: audioDir)
            }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            lastError = "Open failed: \(error.localizedDescription)"
        }
    }

    private func snapshotDocument() -> ProjectDocument {
        ProjectDocument(
            name: name, tempo: tempo, pixelsPerSecond: pixelsPerSecond,
            tracks: tracks.map { track in
                ProjectDocument.TrackData(
                    name: track.name, colorIndex: track.colorIndex,
                    volume: track.volume, pan: track.pan, reverb: track.reverb,
                    delay: track.delay, compress: track.compress,
                    eqLow: track.eqLow, eqMid: track.eqMid, eqHigh: track.eqHigh,
                    isMuted: track.isMuted, isSoloed: track.isSoloed,
                    clips: track.clips.map { clip in
                        ProjectDocument.ClipData(
                            assetFile: clip.asset.url.lastPathComponent,
                            assetName: clip.asset.name,
                            sampleRate: clip.asset.sampleRate,
                            assetDuration: clip.asset.duration,
                            startTime: clip.startTime, offset: clip.offset, duration: clip.duration,
                            fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, fadeCurve: clip.fadeCurve,
                            gain: clip.gain, muted: clip.muted)
                    })
            },
            markers: markers,
            masterEqLow: masterEqLow, masterEqMid: masterEqMid, masterEqHigh: masterEqHigh,
            beatsPerBar: beatsPerBar)
    }

    private func applyDocument(_ document: ProjectDocument, audioDir: URL) async {
        stop()
        engine.reset()
        var assetCache: [String: AudioAsset] = [:]
        var rebuilt: [Track] = []

        for trackData in document.tracks {
            var track = Track(name: trackData.name, colorIndex: trackData.colorIndex)
            track.volume = trackData.volume
            track.pan = trackData.pan
            track.reverb = trackData.reverb
            track.delay = trackData.delay
            track.compress = trackData.compress
            track.eqLow = trackData.eqLow
            track.eqMid = trackData.eqMid
            track.eqHigh = trackData.eqHigh
            track.isMuted = trackData.isMuted
            track.isSoloed = trackData.isSoloed

            var clips: [Clip] = []
            for clipData in trackData.clips {
                let asset: AudioAsset
                if let cached = assetCache[clipData.assetFile] {
                    asset = cached
                } else {
                    // Copy the package's audio into the library so playback is sandbox-safe.
                    let packaged = audioDir.appendingPathComponent(clipData.assetFile)
                    let local = (try? LibraryStorage.copyIntoLibrary(packaged)) ?? packaged
                    let peaks = await Task.detached(priority: .userInitiated) {
                        WaveformLoader.load(url: local)?.peaks ?? []
                    }.value
                    asset = AudioAsset(url: local, duration: clipData.assetDuration,
                                       sampleRate: clipData.sampleRate, peaks: peaks)
                    assetCache[clipData.assetFile] = asset
                }
                var clip = Clip(asset: asset, startTime: clipData.startTime)
                clip.offset = clipData.offset
                clip.duration = clipData.duration
                clip.fadeIn = clipData.fadeIn
                clip.fadeOut = clipData.fadeOut
                clip.fadeCurve = clipData.fadeCurve
                clip.gain = clipData.gain
                clip.muted = clipData.muted
                clips.append(clip)
            }
            track.clips = clips
            rebuilt.append(track)
        }

        name = document.name
        tempo = document.tempo
        pixelsPerSecond = document.pixelsPerSecond
        markers = document.markers
        setMasterEQ(low: document.masterEqLow, mid: document.masterEqMid, high: document.masterEqHigh)
        beatsPerBar = max(1, document.beatsPerBar)
        currentTime = 0
        tracks = rebuilt
        engine.prepare(tracks: rebuilt)
    }
}
