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
    @Published var infoMessage: String?   // friendly, non-error notice (e.g. opened Suno manually)
    @Published var activeSheet: EditorSheet?
    @Published var showLoopBrowser = false
    @Published var groups: [TrackGroup] = []

    // Suno generation state.
    @Published var isGenerating = false
    @Published var candidates: [CandidateAsset] = []
    @Published var useTaste = true
    @Published var lastNudge: [String] = []
    @Published var sidecarStatus: SidecarStatus = .checking
    private var lastPrompt: GeneratePrompt?

    @Published var isExporting = false
    @Published var selectedClipID: UUID?
    @Published var snapEnabled = true
    @Published var snapDivision: Double = 0.25   // in beats (4 = bar, 1 = beat, 0.25 = 1/4 beat)
    @Published var clipboard: Clip?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var undoStack: [(tracks: [Track], groups: [TrackGroup])] = []
    private var redoStack: [(tracks: [Track], groups: [TrackGroup])] = []

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
    @Published var masterVolume: Float = 1.0
    @Published var beatsPerBar: Int = 4   // time signature numerator (over /4)

    func setMasterEQ(low: Float, mid: Float, high: Float) {
        masterEqLow = low; masterEqMid = mid; masterEqHigh = high
        engine.setMasterEQ(low: low, mid: mid, high: high)
    }

    func setMasterVolume(_ volume: Float) {
        masterVolume = max(0, min(1, volume))
        engine.setMasterVolume(masterVolume)
    }

    let settings: AppSettings
    let taste: TasteEngine
    let recorder: Recorder
    let loops: LoopLibrary
    private let engine = AudioEngine()
    private var ticker: Timer?
    private var recordPosition: TimeInterval = 0

    @Published var masterLevel: Float = 0
    @Published var trackLevels: [UUID: Float] = [:]

    // MIDI input / recording
    private let midiInput = MIDIInput()
    @Published var midiConnected = false
    @Published var musicalTypingEnabled = false
    @Published var musicalTypingOctave = 4
    @Published var armedTrackID: UUID?            // instrument track receiving live MIDI
    @Published private(set) var isRecordingMIDI = false
    private var midiNoteStarts: [Int: TimeInterval] = [:]

    init(settings: AppSettings, taste: TasteEngine, recorder: Recorder, loops: LoopLibrary) {
        self.settings = settings
        self.loops = loops
        self.taste = taste
        self.recorder = recorder
        recorder.onStarted = { [weak self] in self?.handleRecordingStarted() }
        recorder.onFinish = { [weak self] url in self?.placeRecording(url, at: self?.recordPosition ?? 0) }
        recorder.onError = { [weak self] message in self?.lastError = message }
        engine.onLevel = { [weak self] level in
            Task { @MainActor in self?.masterLevel = level }
        }
        engine.onTrackLevel = { [weak self] id, level in
            Task { @MainActor in self?.trackLevels[id] = level }
        }
        midiInput.onNote = { [weak self] isOn, pitch, velocity in
            Task { @MainActor in self?.handleIncomingMIDI(isOn: isOn, pitch: pitch, velocity: velocity) }
        }
        midiInput.onSourcesChanged = { [weak self] connected in
            Task { @MainActor in self?.midiConnected = connected }
        }
        midiConnected = midiInput.hasSources
    }

    // MARK: - MIDI input / recording

    /// Arm an instrument track to receive live MIDI (toggle).
    func armTrack(_ track: Track) {
        guard track.isInstrument else { return }
        armedTrackID = (armedTrackID == track.id) ? nil : track.id
    }

    /// Toggle Musical Typing; auto-arm the first instrument track so keys make sound.
    func toggleMusicalTyping() {
        musicalTypingEnabled.toggle()
        if musicalTypingEnabled, armedTrackID == nil,
           let inst = tracks.first(where: { $0.isInstrument }) {
            armedTrackID = inst.id
        }
    }

    /// Handle a computer-keyboard key for Musical Typing. Returns true if it was a
    /// musical key (so the caller consumes the event).
    func playMusicalKey(keyCode: UInt16, on: Bool) -> Bool {
        if keyCode == MusicalTyping.octaveDownKey {
            if on { musicalTypingOctave = max(0, musicalTypingOctave - 1) }
            return true
        }
        if keyCode == MusicalTyping.octaveUpKey {
            if on { musicalTypingOctave = min(8, musicalTypingOctave + 1) }
            return true
        }
        guard let pitch = MusicalTyping.pitch(keyCode: keyCode, octave: musicalTypingOctave) else { return false }
        handleIncomingMIDI(isOn: on, pitch: pitch, velocity: 100)
        return true
    }

    private func handleIncomingMIDI(isOn: Bool, pitch: Int, velocity: Int) {
        guard let id = armedTrackID, let track = tracks.first(where: { $0.id == id }) else { return }
        // Live monitoring through the armed track's instrument.
        if isOn { engine.midiNoteOn(trackID: id, program: track.program, channel: track.midiChannel, pitch: pitch, velocity: velocity) }
        else { engine.midiNoteOff(trackID: id, channel: track.midiChannel, pitch: pitch) }

        // Capture into the track while recording.
        guard isRecordingMIDI else { return }
        if isOn {
            midiNoteStarts[pitch] = currentTime
        } else if let start = midiNoteStarts.removeValue(forKey: pitch) {
            commitRecordedNote(pitch: pitch, start: start, end: currentTime, velocity: max(1, velocity))
        }
    }

    private func commitRecordedNote(pitch: Int, start: TimeInterval, end: TimeInterval, velocity: Int) {
        guard let id = armedTrackID, let ti = tracks.firstIndex(where: { $0.id == id }) else { return }
        let duration = max(0.05, end - start)
        tracks[ti].notes.append(MIDINote(pitch: pitch, start: start, duration: duration, velocity: velocity))
    }

    private func startMIDIRecording() {
        guard armedTrackID != nil else { return }
        recordUndo()
        midiNoteStarts.removeAll()
        if currentTime >= totalDuration { currentTime = 0 }
        if countInEnabled {
            engine.playCountIn(tempo: tempo, beatsPerBar: beatsPerBar) { [weak self] in
                self?.beginMIDICapture()
            }
        } else {
            beginMIDICapture()
        }
    }

    private func beginMIDICapture() {
        isRecordingMIDI = true
        if !tracks.isEmpty { play() }   // roll the project so you can play along
    }

    /// Fill a drum track with a preset beat pattern (replaces its notes).
    func applyDrumPattern(on track: Track, _ preset: DrumPreset, bars: Int, stepDur: TimeInterval) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[ti].notes = DrumPatterns.notes(preset, bars: bars, stepDur: stepDur)
    }

    /// Snap an instrument track's note starts to a grid (seconds).
    func quantizeNotes(on track: Track, to grid: TimeInterval) {
        guard grid > 0, let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        recordUndo()
        for i in tracks[ti].notes.indices {
            tracks[ti].notes[i].start = max(0, (tracks[ti].notes[i].start / grid).rounded() * grid)
        }
    }

    private func stopMIDIRecording() {
        // Finalize any notes still held down.
        let end = currentTime
        for (pitch, start) in midiNoteStarts {
            commitRecordedNote(pitch: pitch, start: start, end: end, velocity: 90)
        }
        midiNoteStarts.removeAll()
        isRecordingMIDI = false
        stop()
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
        engine.prepare(tracks: effectiveTracks())
    }

    // MARK: - Recording

    func toggleRecord() {
        if isRecordingMIDI { stopMIDIRecording(); return }
        if recorder.isRecording { stopRecording(); return }
        // An armed instrument track records MIDI; otherwise capture mic audio.
        if armedTrackID != nil { startMIDIRecording() } else { startRecording() }
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
        engine.prepare(tracks: effectiveTracks())
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
        sidecarStatus = .checking
        Task { sidecarStatus = await client.status() }
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
            // Check the sidecar first and report problems IN-APP (no surprise browser hop).
            let status = await client.status()
            sidecarStatus = status
            switch status {
            case .offline:
                removeJob(jobID); isGenerating = false
                infoMessage = "The local Suno API isn't running. Start it (Terminal: `make suno-sidecar` with your "
                    + "SUNO_COOKIE), then try Generate again. Or use “Open in Suno (manual).”"
                return
            case .unauthorized:
                removeJob(jobID); isGenerating = false
                infoMessage = "The Suno sidecar is running but your cookie isn't authorized (HTTP 401). Re-grab the "
                    + "cookie from suno.com (logged in) and restart the sidecar. Or use “Open in Suno (manual).”"
                return
            case .checking, .ready:
                break
            }
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
                // Stay in-app: surface the failure, leave the manual button as an explicit choice.
                removeJob(jobID)
                isGenerating = false
                sidecarStatus = await client.status()
                infoMessage = "Suno generation failed: \(error.localizedDescription). The sidecar may have hit Suno's "
                    + "bot check. You can retry, or use “Open in Suno (manual).”"
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
        engine.play(tracks: effectiveTracks(), from: base, metronome: metronomeEnabled, tempo: tempo, beatsPerBar: beatsPerBar)
        isPlaying = true

        let startedAt = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentTime = base + Date().timeIntervalSince(startedAt)
                self.engine.applyAutomation(tracks: self.effectiveTracks(), at: self.currentTime)
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
        trackLevels = [:]
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
        engine.applyMix(tracks: effectiveTracks())
    }

    func deleteTrack(_ track: Track) {
        recordUndo()
        tracks.removeAll { $0.id == track.id }
    }

    func addEmptyTrack() {
        recordUndo()
        let track = Track(name: "Track \(tracks.count + 1)", colorIndex: tracks.count)
        tracks.append(track)
        engine.prepare(tracks: effectiveTracks())
    }

    // MARK: - Track groups

    func group(for track: Track) -> TrackGroup? {
        guard let gid = track.groupID else { return nil }
        return groups.first { $0.id == gid }
    }

    /// The ordered timeline rows: each group header followed by its (expanded) members,
    /// with ungrouped tracks inline. Header column + lane area both iterate this.
    var timelineRows: [TimelineRow] {
        guard !groups.isEmpty else { return tracks.map { .track($0) } }
        var rows: [TimelineRow] = []
        var emitted = Set<UUID>()
        for track in tracks {
            if let gid = track.groupID, let g = groups.first(where: { $0.id == gid }) {
                if emitted.insert(gid).inserted {
                    rows.append(.group(g))
                    if !g.collapsed {
                        rows.append(contentsOf: tracks.filter { $0.groupID == gid }.map { .track($0) })
                    }
                }
            } else {
                rows.append(.track(track))
            }
        }
        return rows
    }

    /// Tracks with group volume/mute/solo baked into their own fields (for the audio engine).
    func effectiveTracks() -> [Track] {
        guard !groups.isEmpty else { return tracks }
        return tracks.map { track in
            guard let gid = track.groupID, let g = groups.first(where: { $0.id == gid }) else { return track }
            var t = track
            t.volume = track.volume * g.volume
            t.isMuted = track.isMuted || g.muted
            t.isSoloed = track.isSoloed || g.soloed
            return t
        }
    }

    private func refreshMix() { engine.applyMix(tracks: effectiveTracks()) }

    func createGroup(with trackIDs: [UUID], name: String? = nil) {
        guard !trackIDs.isEmpty else { return }
        recordUndo()
        let group = TrackGroup(name: name ?? "Group \(groups.count + 1)", colorIndex: groups.count)
        groups.append(group)
        for i in tracks.indices where trackIDs.contains(tracks[i].id) { tracks[i].groupID = group.id }
        refreshMix()
    }

    func ungroup(_ group: TrackGroup) {
        recordUndo()
        for i in tracks.indices where tracks[i].groupID == group.id { tracks[i].groupID = nil }
        groups.removeAll { $0.id == group.id }
        refreshMix()
    }

    func addToGroup(_ track: Track, group: TrackGroup) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].groupID = group.id
        refreshMix()
    }

    func removeFromGroup(_ track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].groupID = nil
        refreshMix()
    }

    private func mutateGroup(_ group: TrackGroup, _ change: (inout TrackGroup) -> Void) {
        guard let i = groups.firstIndex(where: { $0.id == group.id }) else { return }
        change(&groups[i])
    }

    func toggleGroupCollapse(_ group: TrackGroup) { mutateGroup(group) { $0.collapsed.toggle() } }
    func renameGroup(_ group: TrackGroup, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutateGroup(group) { $0.name = trimmed }
    }
    func setGroupVolume(_ group: TrackGroup, _ v: Float) { mutateGroup(group) { $0.volume = v }; refreshMix() }
    func toggleGroupMute(_ group: TrackGroup) { recordUndo(); mutateGroup(group) { $0.muted.toggle() }; refreshMix() }
    func toggleGroupSolo(_ group: TrackGroup) { recordUndo(); mutateGroup(group) { $0.soloed.toggle() }; refreshMix() }

    func addInstrumentTrack() {
        recordUndo()
        var track = Track(name: "Instrument \(tracks.count + 1)", colorIndex: tracks.count)
        track.isInstrument = true
        tracks.append(track)
        engine.prepare(tracks: effectiveTracks())
    }

    @discardableResult
    func addDrumTrack() -> UUID {
        recordUndo()
        var track = Track(name: "Drums \(tracks.count + 1)", colorIndex: tracks.count)
        track.isInstrument = true
        track.isDrumKit = true
        tracks.append(track)
        engine.prepare(tracks: effectiveTracks())
        return track.id
    }

    /// Toggle a drum-grid step (a short note at `start` with `pitch`); returns nothing.
    func toggleStepNote(on track: Track, pitch: Int, start: TimeInterval, duration: TimeInterval, velocity: Int) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        let tol = max(0.005, duration * 0.5)
        if let idx = tracks[ti].notes.firstIndex(where: { $0.pitch == pitch && abs($0.start - start) < tol }) {
            tracks[ti].notes.remove(at: idx)
        } else {
            tracks[ti].notes.append(MIDINote(pitch: pitch, start: start, duration: duration, velocity: velocity))
        }
    }

    // MARK: - MIDI notes (instrument tracks)

    func addNote(_ note: MIDINote, to track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].notes.append(note)
    }

    /// Duplicate a clip back-to-back `times` more times (loop/repeat to fill).
    func repeatClip(_ clip: Clip, on track: Track, times: Int) {
        guard times >= 1,
              let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clip.id }) else { return }
        recordUndo()
        var insertAt = ci + 1
        var start = clip.startTime + clip.duration
        for _ in 0..<times {
            tracks[ti].clips.insert(pastedCopy(of: clip, at: start), at: insertAt)
            insertAt += 1
            start += clip.duration
        }
    }

    /// Generate a chord progression onto an instrument track (replaces its notes).
    func generateChords(on track: Track, root: Int, scale: MusicScale, degrees: [Int], octave: Int) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let barDuration = Double(beatsPerBar) * (60.0 / max(30, tempo))
        recordUndo()
        tracks[ti].notes = chordProgression(root: root, scale: scale, degrees: degrees,
                                             barDuration: barDuration, octave: octave)
    }

    /// Replace a track's notes with an arpeggiated version of its chords.
    func arpeggiateTrack(on track: Track, rate: TimeInterval, pattern: ArpPattern) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        recordUndo()
        tracks[ti].notes = arpeggiate(tracks[ti].notes, rate: rate, pattern: pattern)
    }

    /// Quantize to `grid`, then delay the off-beats by `amount`·grid (groove/swing). Idempotent.
    func swingNotes(on track: Track, amount: Double, grid: TimeInterval) {
        guard grid > 0, let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        recordUndo()
        for i in tracks[ti].notes.indices {
            let step = (tracks[ti].notes[i].start / grid).rounded()
            var t = step * grid
            if Int(step) % 2 == 1 { t += amount * grid }
            tracks[ti].notes[i].start = max(0, t)
        }
    }

    /// Shift every note on an instrument track by a number of semitones.
    func transposeNotes(on track: Track, by semitones: Int) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        recordUndo()
        for i in tracks[ti].notes.indices {
            tracks[ti].notes[i].pitch = min(127, max(0, tracks[ti].notes[i].pitch + semitones))
        }
    }

    func deleteNote(_ note: MIDINote, from track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].notes.removeAll { $0.id == note.id }
    }

    func updateNote(_ note: MIDINote, on track: Track, _ change: (inout MIDINote) -> Void) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let ni = tracks[ti].notes.firstIndex(where: { $0.id == note.id }) else { return }
        recordUndo()
        change(&tracks[ti].notes[ni])
    }

    func setProgram(_ track: Track, _ program: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[i].program = max(0, min(127, program))
    }

    func auditionNote(_ track: Track, pitch: Int) {
        engine.auditionNote(trackID: track.id, program: track.program, channel: track.midiChannel, pitch: pitch)
    }

    // MARK: - Automation

    func addAutomationPoint(_ track: Track, _ lane: WritableKeyPath<Track, [AutomationPoint]>,
                            time: TimeInterval, value: Float) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i][keyPath: lane].append(AutomationPoint(time: max(0, time), value: value))
        tracks[i][keyPath: lane].sort { $0.time < $1.time }
    }

    /// Move a breakpoint to a new time + value (records one undo step; call on drag end).
    func moveAutomationPoint(_ point: AutomationPoint, _ track: Track,
                             _ lane: WritableKeyPath<Track, [AutomationPoint]>,
                             time: TimeInterval, value: Float) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }),
              let pi = tracks[ti][keyPath: lane].firstIndex(where: { $0.id == point.id }) else { return }
        recordUndo()
        tracks[ti][keyPath: lane][pi].time = max(0, time)
        tracks[ti][keyPath: lane][pi].value = value
        tracks[ti][keyPath: lane].sort { $0.time < $1.time }
    }

    func removeAutomationPoint(_ point: AutomationPoint, _ track: Track,
                               _ lane: WritableKeyPath<Track, [AutomationPoint]>) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i][keyPath: lane].removeAll { $0.id == point.id }
    }

    /// Duck `target`'s volume in time with `trigger` (sidechain pump) by generating
    /// volume automation from the trigger track's envelope.
    func sidechainDuck(target: Track, triggerID: UUID, depth: Float = 0.8, release: TimeInterval = 0.18) {
        guard triggerID != target.id, let trigger = tracks.first(where: { $0.id == triggerID }) else { return }
        let end = max(trigger.endTime, target.endTime)
        guard end > 0 else { lastError = "The trigger track has no audio."; return }
        var trg = trigger
        trg.isMuted = false; trg.isSoloed = false
        trg.volumeAutomation = []   // render the trigger dry
        let targetID = target.id
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sc-\(UUID().uuidString).wav")
                try AudioExporter.render(tracks: [trg], duration: end, to: tmp)
                let points = Sidechain.duckingPoints(triggerURL: tmp, depth: depth, release: release)
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    self.applySidechain(targetID: targetID, points: points, trigger: trigger.name)
                    self.isExporting = false
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Sidechain failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applySidechain(targetID: UUID, points: [(time: TimeInterval, value: Float)], trigger: String) {
        guard let ti = tracks.firstIndex(where: { $0.id == targetID }), !points.isEmpty else { return }
        recordUndo()
        tracks[ti].volumeAutomation = points.map { AutomationPoint(time: $0.time, value: $0.value) }
        infoMessage = "Ducked “\(tracks[ti].name)” by “\(trigger)” — tweak it in the Automation editor (Volume lane)."
    }

    func clearAutomation(_ track: Track, _ lane: WritableKeyPath<Track, [AutomationPoint]>) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i][keyPath: lane] = []
        // Restore the static mixer value once automation is gone.
        engine.applyMix(tracks: effectiveTracks())
    }

    // MARK: - Plugins (Audio Unit inserts)

    func addPlugin(_ ref: PluginRef, to track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].plugins.append(ref)
        engine.reload(tracks: tracks)   // rebuild the chain with the new insert
    }

    func removePlugin(at index: Int, from track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }),
              tracks[i].plugins.indices.contains(index) else { return }
        recordUndo()
        tracks[i].plugins.remove(at: index)
        engine.reload(tracks: tracks)
    }

    func pluginUnit(trackID: UUID, index: Int) -> AVAudioUnit? {
        engine.pluginUnit(trackID: trackID, index: index)
    }

    /// Copy of `tracks` with each plugin's stateData refreshed from its live AU instance
    /// (so export honors knob tweaks made in plugin windows).
    private func tracksWithLivePluginState() -> [Track] {
        effectiveTracks().map { track in
            guard !track.plugins.isEmpty else { return track }
            var t = track
            t.plugins = track.plugins.enumerated().map { idx, ref in
                var r = ref
                if let data = engine.pluginState(trackID: track.id, index: idx) { r.stateData = data }
                return r
            }
            return t
        }
    }

    /// Render a track's clips + effects (EQ/comp/reverb/delay/volume/pan) to one audio
    /// file and add it as a new "(bounce)" track — non-destructive.
    func bounceTrack(_ track: Track) {
        let end = track.clips.map { $0.startTime + $0.duration }.max() ?? 0
        guard end > 0 else { lastError = "That track has no audio to bounce."; return }
        var rendered = track
        rendered.isMuted = false
        rendered.isSoloed = false
        isImporting = true
        Task.detached(priority: .userInitiated) {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bounce-\(UUID().uuidString).wav")
                try AudioExporter.render(tracks: [rendered], duration: end, to: tmp)
                let local = try LibraryStorage.adopt(tempURL: tmp, suggestedName: "\(track.name)-bounce.wav")
                guard let waveform = WaveformLoader.load(url: local) else {
                    throw AudioExporter.ExportError.renderFailed
                }
                let asset = AudioAsset(url: local, duration: waveform.duration,
                                       sampleRate: waveform.sampleRate, peaks: waveform.peaks)
                await MainActor.run {
                    self.addNamedTrack(name: "\(track.name) (bounce)", asset: asset)
                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.lastError = "Bounce failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Start a new project pre-seeded with named empty tracks.
    func newFromTemplate(_ names: [String]) {
        newProject()
        guard !names.isEmpty else { return }
        for name in names {
            let track = Track(name: name, colorIndex: tracks.count)
            tracks.append(track)
        }
        engine.prepare(tracks: effectiveTracks())
    }

    /// Deep-copy a track (fresh ids, same effect settings + clips) below the original.
    func duplicateTrack(_ track: Track) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        var copy = Track(name: track.name + " copy", colorIndex: tracks.count)
        copy.volume = track.volume; copy.pan = track.pan
        copy.reverb = track.reverb; copy.delay = track.delay; copy.compress = track.compress
        copy.eqLow = track.eqLow; copy.eqMid = track.eqMid; copy.eqHigh = track.eqHigh
        copy.isMuted = track.isMuted; copy.isSoloed = track.isSoloed
        copy.clips = track.clips.map { pastedCopy(of: $0, at: $0.startTime) }
        tracks.insert(copy, at: i + 1)
        engine.prepare(tracks: effectiveTracks())
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
        undoStack.append((tracks, groups))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append((tracks, groups))
        applyTrackState(previous.tracks, previous.groups)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append((tracks, groups))
        applyTrackState(next.tracks, next.groups)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func applyTrackState(_ newTracks: [Track], _ newGroups: [TrackGroup]) {
        stop()
        selectedClipID = nil
        tracks = newTracks
        groups = newGroups
        engine.reset()
        engine.prepare(tracks: effectiveTracks())
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

    /// Find the selected clip and its track (for keyboard editing commands).
    private func selectedClipAndTrack() -> (Clip, Track)? {
        guard let id = selectedClipID else { return nil }
        for track in tracks where track.clips.contains(where: { $0.id == id }) {
            if let clip = track.clips.first(where: { $0.id == id }) { return (clip, track) }
        }
        return nil
    }

    func deleteSelectedClip() {
        if let (clip, track) = selectedClipAndTrack() { deleteClip(clip, on: track) }
    }
    func duplicateSelectedClip() {
        if let (clip, track) = selectedClipAndTrack() { duplicateClip(clip, on: track) }
    }
    func splitSelectedAtPlayhead() {
        if let (clip, track) = selectedClipAndTrack() { splitClipAtPlayhead(clip, on: track) }
    }

    // MARK: - Loop library

    /// Bounce a clip to the loop library so it can be reused across projects.
    func saveClipAsLoop(_ clip: Clip, on track: Track) {
        var t = Track(name: clip.name, colorIndex: 0)
        var solo = clip; solo.startTime = 0
        t.clips = [solo]
        let duration = clip.duration, name = clip.name, bpm = Int(tempo.rounded())
        Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString).wav")
            do {
                try AudioExporter.render(tracks: [t], duration: duration, to: tmp)
                await MainActor.run {
                    self.loops.addLoop(from: tmp, name: name, bpm: bpm)
                    self.infoMessage = "Saved “\(name)” to your Loop Library."
                }
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                await MainActor.run { self.lastError = "Couldn't save loop: \(error.localizedDescription)" }
            }
        }
    }

    /// Save a generated (Suno) candidate to the loop library.
    func saveCandidateAsLoop(_ candidate: CandidateAsset) {
        loops.addLoop(from: candidate.asset.url, name: candidate.title, bpm: Int(tempo.rounded()))
        infoMessage = "Saved “\(candidate.title)” to your Loop Library."
    }

    /// Drop a library loop onto the timeline as a new track at the playhead.
    func addLoopToProject(_ loop: LoopEntry) {
        guard let url = loops.url(for: loop) else { return }
        let at = currentTime
        isImporting = true
        Task.detached(priority: .userInitiated) {
            guard let waveform = WaveformLoader.load(url: url) else {
                await MainActor.run { self.isImporting = false }
                return
            }
            let asset = AudioAsset(url: url, duration: waveform.duration,
                                   sampleRate: waveform.sampleRate, peaks: waveform.peaks)
            await MainActor.run {
                self.addNamedTrack(name: loop.name, asset: asset, at: at)
                self.isImporting = false
            }
        }
    }

    func renameClip(_ clip: Clip, on track: Track, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recordUndo()
        updateClip(clip, on: track) { $0.customName = trimmed.isEmpty ? nil : trimmed }
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
                self.engine.prepare(tracks: self.effectiveTracks())
            }
        }
    }

    /// Bake a pitch-shifted copy of a clip (length preserved), ± semitones.
    func pitchShiftClip(_ clip: Clip, on track: Track, semitones: Float) {
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        let keepDuration = clip.duration
        isImporting = true
        Task.detached(priority: .userInitiated) {
            guard let dir = try? LibraryStorage.importsDirectory(),
                  let pitched = ClipProcessing.pitchShift(url: url, offset: offset, duration: duration,
                                                          semitones: semitones, outputDir: dir),
                  let waveform = WaveformLoader.load(url: pitched) else {
                await MainActor.run { self.isImporting = false; self.lastError = "Pitch shift failed." }
                return
            }
            let asset = AudioAsset(url: pitched, duration: waveform.duration,
                                   sampleRate: waveform.sampleRate, peaks: waveform.peaks)
            await MainActor.run {
                self.recordUndo()
                self.updateClip(clip, on: track) {
                    $0.asset = asset
                    $0.offset = 0
                    $0.duration = min(asset.duration, keepDuration)
                }
                self.engine.prepare(tracks: self.effectiveTracks())
                self.isImporting = false
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
                self.engine.prepare(tracks: self.effectiveTracks())
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
        engine.prepare(tracks: effectiveTracks())
    }

    private func pastedCopy(of clip: Clip, at start: TimeInterval) -> Clip {
        var copy = Clip(asset: clip.asset, startTime: max(0, start))
        copy.offset = clip.offset
        copy.duration = clip.duration
        copy.fadeIn = clip.fadeIn
        copy.fadeOut = clip.fadeOut
        copy.fadeCurve = clip.fadeCurve
        copy.gain = clip.gain
        copy.muted = clip.muted
        copy.customName = clip.customName
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

    func exportMixdown(aac: Bool = false, normalize: Bool = false) {
        exportRange(from: 0, duration: totalDuration, name: name, aac: aac, normalize: normalize)
    }

    func exportLoop(aac: Bool = false) {
        guard loopActive else { return }
        exportRange(from: loopStart, duration: loopEnd - loopStart, name: "\(name)-loop", aac: aac)
    }

    private func exportRange(from: TimeInterval, duration: TimeInterval, name: String,
                             aac: Bool, normalize: Bool = false) {
        guard !tracks.isEmpty, duration > 0, !isExporting else { return }
        let ext = aac ? "m4a" : "wav"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .audio]
        panel.nameFieldStringValue = "\(name).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let snapshot = tracksWithLivePluginState()
        let masterVol = masterVolume
        isExporting = true
        Task.detached(priority: .userInitiated) {
            do {
                try AudioExporter.render(tracks: snapshot, duration: duration, to: url, from: from,
                                         aac: aac, masterVolume: masterVol)
                if normalize && !aac { try AudioExporter.normalizeFile(at: url) }
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
        groups = []
        candidates = []
        markers = []
        setMasterEQ(low: 0, mid: 0, high: 0)
        name = "Untitled"
        currentTime = 0
        removeRecovery()
    }

    // MARK: - Session autosave / crash recovery

    private static var recoveryURL: URL? {
        try? LibraryStorage.supportDirectory().appendingPathComponent("recovery.json")
    }
    private var autosaveStarted = false
    private var autosaveTimer: Timer?

    /// Restore the last session (if any) and begin autosaving. Call once, on first appear.
    func restoreSessionIfAvailable() {
        guard !autosaveStarted else { return }
        autosaveStarted = true
        if tracks.isEmpty, let url = Self.recoveryURL,
           let data = try? Data(contentsOf: url),
           let document = try? JSONDecoder().decode(ProjectDocument.self, from: data),
           !document.tracks.isEmpty {
            Task { await applyDocument(document, audioDir: nil) }
        }
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autosave() }
        }
    }

    private func autosave() {
        guard let url = Self.recoveryURL else { return }
        if tracks.isEmpty { removeRecovery(); return }
        if let data = try? JSONEncoder().encode(snapshotDocument(absolutePaths: true)) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func removeRecovery() {
        if let url = Self.recoveryURL { try? FileManager.default.removeItem(at: url) }
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

    private func snapshotDocument(absolutePaths: Bool = false) -> ProjectDocument {
        ProjectDocument(
            name: name, tempo: tempo, pixelsPerSecond: pixelsPerSecond,
            tracks: tracks.map { track in
                ProjectDocument.TrackData(
                    name: track.name, colorIndex: track.colorIndex,
                    volume: track.volume, pan: track.pan, reverb: track.reverb,
                    delay: track.delay, compress: track.compress,
                    eqLow: track.eqLow, eqMid: track.eqMid, eqHigh: track.eqHigh,
                    isMuted: track.isMuted, isSoloed: track.isSoloed, groupID: track.groupID,
                    clips: track.clips.map { clip in
                        ProjectDocument.ClipData(
                            assetFile: absolutePaths ? clip.asset.url.path : clip.asset.url.lastPathComponent,
                            assetName: clip.asset.name,
                            sampleRate: clip.asset.sampleRate,
                            assetDuration: clip.asset.duration,
                            startTime: clip.startTime, offset: clip.offset, duration: clip.duration,
                            fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, fadeCurve: clip.fadeCurve,
                            gain: clip.gain, muted: clip.muted, customName: clip.customName)
                    },
                    isInstrument: track.isInstrument, isDrumKit: track.isDrumKit, program: track.program,
                    notes: track.notes.map {
                        ProjectDocument.NoteData(pitch: $0.pitch, start: $0.start,
                                                 duration: $0.duration, velocity: $0.velocity)
                    },
                    volumeAutomation: track.volumeAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    panAutomation: track.panAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    reverbAutomation: track.reverbAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    delayAutomation: track.delayAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    eqLowAutomation: track.eqLowAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    eqMidAutomation: track.eqMidAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    eqHighAutomation: track.eqHighAutomation.map { ProjectDocument.PointData(time: $0.time, value: $0.value) },
                    plugins: track.plugins.enumerated().map { idx, ref in
                        var r = ref
                        if let data = engine.pluginState(trackID: track.id, index: idx) { r.stateData = data }
                        return r
                    })
            },
            markers: markers,
            masterEqLow: masterEqLow, masterEqMid: masterEqMid, masterEqHigh: masterEqHigh,
            masterVolume: masterVolume,
            beatsPerBar: beatsPerBar,
            groups: groups.map {
                ProjectDocument.GroupData(id: $0.id, name: $0.name, colorIndex: $0.colorIndex,
                                          collapsed: $0.collapsed, volume: $0.volume,
                                          muted: $0.muted, soloed: $0.soloed)
            })
    }

    private func applyDocument(_ document: ProjectDocument, audioDir: URL?) async {
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
            track.groupID = trackData.groupID
            track.isInstrument = trackData.isInstrument
            track.isDrumKit = trackData.isDrumKit
            track.program = trackData.program
            track.notes = trackData.notes.map {
                MIDINote(pitch: $0.pitch, start: $0.start, duration: $0.duration, velocity: $0.velocity)
            }
            track.volumeAutomation = trackData.volumeAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.panAutomation = trackData.panAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.reverbAutomation = trackData.reverbAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.delayAutomation = trackData.delayAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.eqLowAutomation = trackData.eqLowAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.eqMidAutomation = trackData.eqMidAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.eqHighAutomation = trackData.eqHighAutomation.map { AutomationPoint(time: $0.time, value: $0.value) }
            track.plugins = trackData.plugins

            var clips: [Clip] = []
            for clipData in trackData.clips {
                let asset: AudioAsset
                if let cached = assetCache[clipData.assetFile] {
                    asset = cached
                } else {
                    // From a package: copy audio into the library. From recovery (audioDir nil):
                    // assetFile is an absolute path already on disk — reference it directly.
                    let local: URL
                    if let audioDir {
                        let packaged = audioDir.appendingPathComponent(clipData.assetFile)
                        local = (try? LibraryStorage.copyIntoLibrary(packaged)) ?? packaged
                    } else {
                        local = URL(fileURLWithPath: clipData.assetFile)
                    }
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
                clip.customName = clipData.customName
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
        setMasterVolume(document.masterVolume)
        beatsPerBar = max(1, document.beatsPerBar)
        groups = document.groups.map {
            var g = TrackGroup(id: $0.id, name: $0.name, colorIndex: $0.colorIndex)
            g.collapsed = $0.collapsed; g.volume = $0.volume; g.muted = $0.muted; g.soloed = $0.soloed
            return g
        }
        currentTime = 0
        tracks = rebuilt
        engine.prepare(tracks: effectiveTracks())
    }
}
