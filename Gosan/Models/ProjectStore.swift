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
    @Published var showMIDIImporter = false
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
    /// A full snapshot of the reversible project state (not just tracks — tempo, the tempo
    /// track, and markers must revert too, or undo leaves them stranded).
    private struct Snapshot {
        var tracks: [Track]
        var groups: [TrackGroup]
        var tempo: Double
        var tempoPoints: [TempoPoint]
        var markers: [Marker]
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private func currentSnapshot() -> Snapshot {
        Snapshot(tracks: tracks, groups: groups, tempo: tempo, tempoPoints: tempoPoints, markers: markers)
    }

    @Published var loopEnabled = false
    @Published var loopStart: TimeInterval = 0
    @Published var loopEnd: TimeInterval = 0
    var loopActive: Bool { loopEnabled && loopEnd > loopStart + 0.05 }
    @Published var metronomeEnabled = false
    @Published var countInEnabled = false
    @Published var punchEnabled = false          // record only the loop region
    private var punchStopAt: TimeInterval?
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

    // Tempo track: step tempo changes over the song (empty = constant `tempo`).
    @Published var tempoPoints: [TempoPoint] = []

    func addTempoChange(bpm: Double) {
        let clamped = min(300, max(30, bpm.rounded()))
        recordUndo()
        tempoPoints.removeAll { abs($0.time - currentTime) < 0.01 }
        tempoPoints.append(TempoPoint(time: currentTime, bpm: clamped))
        tempoPoints.sort { $0.time < $1.time }
    }
    func removeTempoChange(_ point: TempoPoint) {
        recordUndo()
        tempoPoints.removeAll { $0.id == point.id }
    }
    func clearTempoTrack() { recordUndo(); tempoPoints = [] }

    // Scale lock: notes added in the piano roll snap into this key.
    @Published var scaleLockEnabled = false
    @Published var scaleLockRoot = 0            // 0 = C
    @Published var scaleLockScale: MusicScale = .major

    /// Snap a pitch into the locked key (identity when scale lock is off).
    func snappedPitch(_ pitch: Int) -> Int {
        scaleLockEnabled ? snapToScale(pitch, root: scaleLockRoot, scale: scaleLockScale) : pitch
    }
    /// Is a pitch in the locked key? (Always true when off — used to dim the piano roll.)
    func pitchInScale(_ pitch: Int) -> Bool {
        !scaleLockEnabled || snapToScale(pitch, root: scaleLockRoot, scale: scaleLockScale) == pitch
    }

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
    // When cycle-recording (loop on, not punch), the loop region the passes get split into takes.
    private var cycleWindow: (start: TimeInterval, length: TimeInterval)?

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

    // MARK: - Drummer (auto-groove from taste knobs)

    @Published var drummerSettings = DrummerSettings()

    /// Generate a groove onto a drum track from the current Drummer settings. Covers the song
    /// (or 4 bars, whichever is longer). A fresh seed each call so "Regenerate" gives a new take.
    func applyDrummer(on track: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let stepDur = secPerBar / 16
        let existing = tracks.filter { $0.id != track.id }.map(\.endTime).max() ?? 0
        let bars = max(4, Int(ceil((existing > 0 ? existing : secPerBar * 4) / secPerBar)))
        let seed = UInt64.random(in: 0...UInt64.max)
        tracks[ti].notes = drummerPerformance(drummerSettings, bars: bars, stepDur: stepDur, seed: seed)
        engine.prepare(tracks: effectiveTracks())
    }

    /// Create a drum track and open the Drummer on it.
    func addDrummerTrack() -> UUID {
        var id = UUID()
        asOneUndoStep {
            id = addDrumTrack()
            if let track = tracks.first(where: { $0.id == id }) { applyDrummer(on: track) }
        }
        return id
    }

    // MARK: - Bass Player (auto-bassline following the chords)

    @Published var bassSettings = BassSettings()
    @Published var bassFollowID: UUID?      // the chord/instrument track the bass locks to

    /// Instrument tracks (with notes) the bass can follow, excluding drums and `exclude`.
    func chordSources(excluding exclude: UUID? = nil) -> [Track] {
        tracks.filter { $0.isInstrument && !$0.isDrumKit && !$0.notes.isEmpty && $0.id != exclude }
    }

    /// Generate a bassline onto `bassTrack` that follows `bassFollowID`'s chords.
    func applyBassPlayer(on bassTrack: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == bassTrack.id }) else { return }
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let source = tracks.first { $0.id == bassFollowID && $0.id != bassTrack.id }
            ?? chordSources(excluding: bassTrack.id).first
        guard let source else { return }   // the panel guides the user to add chords first
        bassFollowID = source.id
        let bars = max(1, Int(ceil(source.endTime / secPerBar - 1e-6)))
        let roots = chordRootsPerBar(source.notes, secPerBar: secPerBar, bars: bars)
        recordUndo()
        tracks[ti].notes = bassPerformance(roots: roots, settings: bassSettings, secPerBar: secPerBar)
        engine.prepare(tracks: effectiveTracks())
    }

    /// Create a bass instrument track locked to the best existing chord track, and groove it.
    func addBassPlayer() -> UUID {
        if bassFollowID == nil || !tracks.contains(where: { $0.id == bassFollowID }) {
            bassFollowID = chordSources().first?.id
        }
        var track = Track(name: "Bass", colorIndex: tracks.count)
        track.isInstrument = true
        track.program = 33          // GM electric bass (finger)
        let id = track.id
        asOneUndoStep {
            tracks.append(track)
            if let created = tracks.first(where: { $0.id == id }) { applyBassPlayer(on: created) }
            engine.prepare(tracks: effectiveTracks())
        }
        return id
    }

    // MARK: - Melody Maker (auto-topline over the chords)

    @Published var melodySettings = MelodySettings()
    @Published var melodyFollowID: UUID?

    /// Generate a topline onto `melodyTrack` that follows its chord track's harmony. A fresh seed
    /// each call, so "New Melody" gives a new line over the same chords.
    func applyMelody(on melodyTrack: Track) {
        guard let ti = tracks.firstIndex(where: { $0.id == melodyTrack.id }) else { return }
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let source = tracks.first { $0.id == melodyFollowID && $0.id != melodyTrack.id }
            ?? chordSources(excluding: melodyTrack.id).first
        guard let source else { return }   // the panel guides the user to add chords first
        melodyFollowID = source.id
        let bars = max(1, Int(ceil(source.endTime / secPerBar - 1e-6)))
        let chordTones = chordTonesPerBar(source.notes, secPerBar: secPerBar, bars: bars)
        let pool = Array(Set(chordTones.flatMap { $0 })).sorted()      // the scale in play
        let seed = UInt64.random(in: 0...UInt64.max)
        recordUndo()
        tracks[ti].notes = melodyLine(chords: chordTones, pool: pool, settings: melodySettings,
                                      secPerBar: secPerBar, seed: seed)
        engine.prepare(tracks: effectiveTracks())
    }

    /// Create a lead instrument track over the best existing chord track, and write a topline.
    func addMelodyMaker() -> UUID {
        if melodyFollowID == nil || !tracks.contains(where: { $0.id == melodyFollowID }) {
            melodyFollowID = chordSources().first?.id
        }
        var track = Track(name: "Melody", colorIndex: tracks.count)
        track.isInstrument = true
        track.program = 81          // GM lead 2 (sawtooth)
        let id = track.id
        asOneUndoStep {
            tracks.append(track)
            if let created = tracks.first(where: { $0.id == id }) { applyMelody(on: created) }
            engine.prepare(tracks: effectiveTracks())
        }
        return id
    }

    // MARK: - Song Starter (one-click full arrangement)

    /// Lay down a complete starting arrangement in one shot: chords in `key`, then a bass, a
    /// topline, and a drummer — all matched to the vibe and following the chords. Additive
    /// (leaves any existing tracks alone). This is the "beat in one click" of the whole suite.
    func startSong(key: Int, vibe: SongVibe) {
        let scale: MusicScale = vibe.minor ? .minor : .major
        asOneUndoStep {
            tempo = vibe.tempo

            // 1) Chords (the harmony everything else follows).
            var keys = Track(name: "Keys", colorIndex: tracks.count)
            keys.isInstrument = true
            keys.program = 0            // grand piano
            tracks.append(keys)
            let keysID = keys.id
            if let t = tracks.first(where: { $0.id == keysID }) {
                generateChords(on: t, root: key, scale: scale, degrees: vibe.degrees, octave: 4)
            }

            // 2) Bass, 3) Melody — both explicitly follow the new Keys track.
            bassFollowID = keysID
            bassSettings = BassSettings(pattern: vibe.bassPattern, octave: 2, drive: 0.7)
            _ = addBassPlayer()

            melodyFollowID = keysID
            melodySettings = MelodySettings(density: vibe.melodyDensity, motion: vibe.melodyMotion, register: 5)
            _ = addMelodyMaker()

            // 4) Drummer groove for the vibe.
            drummerSettings = DrummerSettings(style: vibe.drumStyle, complexity: vibe.complexity,
                                              intensity: 0.8, swing: vibe.swing, fillEvery: 4)
            _ = addDrummerTrack()

            engine.prepare(tracks: effectiveTracks())
        }
    }

    /// Build a full multi-section arrangement (Intro → Verse → Chorus → … → Outro): the vibe's
    /// chords tiled across each section, with bass / melody / drums varied per section for
    /// dynamic contrast, plus a marker at every section. Additive.
    func startFullSong(key: Int, vibe: SongVibe) {
      asOneUndoStep {
        let scale: MusicScale = vibe.minor ? .minor : .major
        let form = SongSection.defaultForm
        tempo = vibe.tempo
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let stepDur = secPerBar / 16
        func shift(_ notes: [MIDINote], by t: TimeInterval) -> [MIDINote] {
            notes.map { MIDINote(pitch: $0.pitch, start: $0.start + t, duration: $0.duration, velocity: $0.velocity) }
        }

        var keysN: [MIDINote] = [], bassN: [MIDINote] = [], melN: [MIDINote] = [], drumN: [MIDINote] = []
        var newMarkers: [Marker] = []
        var barCursor = 0
        let (starts, _) = SongSection.layout(form)
        for (i, section) in form.enumerated() {
            let t0 = Double(starts[i]) * secPerBar
            newMarkers.append(Marker(time: t0, name: section.name))
            let degs = (0..<section.bars).map { vibe.degrees[$0 % vibe.degrees.count] }
            let chords = chordProgression(root: key, scale: scale, degrees: degs, barDuration: secPerBar, octave: 4)
            keysN += shift(chords, by: t0)

            let chordTones = chordTonesPerBar(chords, secPerBar: secPerBar, bars: section.bars)
            let pool = Array(Set(chordTones.flatMap { $0 })).sorted()
            if section.bass {
                let roots = chordRootsPerBar(chords, secPerBar: secPerBar, bars: section.bars)
                let line = bassPerformance(roots: roots,
                                           settings: BassSettings(pattern: vibe.bassPattern, octave: 2, drive: section.intensity),
                                           secPerBar: secPerBar)
                bassN += shift(line, by: t0)
            }
            if section.melody {
                let line = melodyLine(chords: chordTones, pool: pool,
                                      settings: MelodySettings(density: section.melodyDensity, motion: vibe.melodyMotion, register: 5),
                                      secPerBar: secPerBar, seed: UInt64(barCursor + 1) &* 0x9E37)
                melN += shift(line, by: t0)
            }
            if section.drums {
                let groove = drummerPerformance(DrummerSettings(style: vibe.drumStyle, complexity: section.drumComplexity,
                                                                intensity: section.intensity, swing: vibe.swing, fillEvery: 4),
                                                bars: section.bars, stepDur: stepDur, seed: UInt64(barCursor + 7) &* 0x85EB)
                drumN += shift(groove, by: t0)
            }
            barCursor += section.bars
        }

        func instrument(_ name: String, _ program: Int, _ notes: [MIDINote], _ colorIndex: Int, drum: Bool = false) -> Track {
            var t = Track(name: name, colorIndex: colorIndex)
            t.isInstrument = true; t.isDrumKit = drum; t.program = program; t.notes = notes
            return t
        }
        let c0 = tracks.count
        tracks.append(instrument("Keys", 0, keysN, c0))
        if !bassN.isEmpty { tracks.append(instrument("Bass", 33, bassN, c0 + 1)) }
        if !melN.isEmpty { tracks.append(instrument("Melody", 81, melN, c0 + 2)) }
        tracks.append(instrument("Drums", 0, drumN, c0 + 3, drum: true))
        markers.append(contentsOf: newMarkers)
        engine.prepare(tracks: effectiveTracks())
      }
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
    func requestMIDIImport() { showMIDIImporter = true }

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
        // Punch: record only the loop region — start at loop-in, auto-stop at loop-out.
        if punchEnabled, loopActive {
            recordPosition = loopStart
            punchStopAt = loopEnd
            cycleWindow = nil
        } else {
            recordPosition = currentTime >= totalDuration ? 0 : currentTime
            punchStopAt = nil
            // Loop (cycle) record: each pass over the region stacks as a take.
            cycleWindow = (loopActive && loopEnabled && loopEnd > loopStart)
                ? (start: loopStart, length: loopEnd - loopStart) : nil
        }
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
        punchStopAt = nil
        recorder.stopRecording()  // fires onFinish → placeRecording
        stop()
    }

    /// Once capture is live, roll the existing tracks so you can perform along.
    private func handleRecordingStarted() {
        if !tracks.isEmpty { play() }
    }

    /// Drop the finished take on a new track at the position recording started.
    /// A cycle recording (loop on) is split into a take folder — one take per pass.
    private func placeRecording(_ url: URL, at position: TimeInterval) {
        let cycle = cycleWindow
        cycleWindow = nil
        Task.detached(priority: .userInitiated) {
            guard let waveform = WaveformLoader.load(url: url) else { return }
            let asset = AudioAsset(url: url,
                                   duration: waveform.duration,
                                   sampleRate: waveform.sampleRate,
                                   peaks: waveform.peaks)
            let takes = cycle.map { cycleTakeWindows(recorded: asset.duration, loopLength: $0.length) } ?? []
            await MainActor.run {
                if takes.count > 1, let cw = cycle {
                    self.addTakeFolderTrack(asset: asset, takes: takes, at: cw.start)
                } else {
                    self.addNamedTrack(name: "Recording", asset: asset, at: position)
                }
            }
        }
    }

    private func addNamedTrack(name: String, asset: AudioAsset, at position: TimeInterval = 0) {
        recordUndo()
        var track = Track(name: name, colorIndex: tracks.count)
        track.clips = [Clip(asset: asset, startTime: position)]
        tracks.append(track)
        engine.prepare(tracks: effectiveTracks())
    }

    /// A new track whose single clip is a take folder (the most recent pass is active).
    private func addTakeFolderTrack(asset: AudioAsset, takes: [Take], at position: TimeInterval) {
        recordUndo()
        var track = Track(name: "Recording", colorIndex: tracks.count)
        var clip = Clip(asset: asset, startTime: position)
        clip.takes = takes
        let active = takes.count - 1        // default to the last (most recent) take, like Logic
        clip.activeTake = active
        clip.offset = takes[active].offset
        clip.duration = takes[active].duration
        track.clips = [clip]
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
        engine.play(tracks: effectiveTracks(), from: base, metronome: metronomeEnabled, tempo: tempo,
                    tempoPoints: tempoPoints, beatsPerBar: beatsPerBar)
        isPlaying = true

        let startedAt = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.currentTime = base + Date().timeIntervalSince(startedAt)
                self.engine.applyAutomation(tracks: self.effectiveTracks(), at: self.currentTime)
                if self.recorder.isRecording, let stopAt = self.punchStopAt, self.currentTime >= stopAt {
                    self.stopRecording()                       // punch-out
                } else if self.loopActive && self.currentTime >= self.loopEnd && !self.recorder.isRecording {
                    self.seek(to: self.loopStart)              // loop restart (not while recording)
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

    /// Add a named arrangement section marker (Intro/Verse/Chorus…) at the playhead.
    func addSectionMarker(_ name: String) {
        markers.append(Marker(time: currentTime, name: name))
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

    /// Export an instrument track's notes as a Standard MIDI File.
    func exportTrackMIDI(_ track: Track) {
        guard track.isInstrument, !track.notes.isEmpty else { lastError = "This track has no notes to export."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .data]
        panel.nameFieldStringValue = "\(track.name).mid"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MIDIFile.write(notes: track.notes, tempo: tempo, channel: track.midiChannel).write(to: url)
        } catch {
            lastError = "MIDI export failed: \(error.localizedDescription)"
        }
    }

    /// Import a .mid file as a new instrument track (adopts its tempo if the project is empty).
    func importMIDIFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), let parsed = MIDIFile.read(data), !parsed.notes.isEmpty else {
            lastError = "Couldn't read that MIDI file."
            return
        }
        recordUndo()
        if tracks.isEmpty { tempo = min(300, max(30, parsed.tempo)) }
        var track = Track(name: url.deletingPathExtension().lastPathComponent, colorIndex: tracks.count)
        track.isInstrument = true
        track.notes = parsed.notes
        tracks.append(track)
        engine.prepare(tracks: effectiveTracks())
    }

    @discardableResult
    func addDrumTrack() -> UUID {
        recordUndo()
        let drumCount = tracks.filter { $0.isDrumKit }.count
        var track = Track(name: drumCount == 0 ? "Drums" : "Drums \(drumCount + 1)", colorIndex: tracks.count)
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

    /// Reharmonize an instrument track's chords with a color (7ths / 9ths / sus) — keeps the
    /// roots (so any following bass/melody still match) but makes plain triads sound new.
    func reharmonizeChords(on track: Track, color: ChordColor) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let bars = max(1, Int(ceil(tracks[ti].endTime / secPerBar - 1e-6)))
        let pool = Array(Set(tracks[ti].notes.map { ((($0.pitch % 12) + 12) % 12) })).sorted()
        recordUndo()
        tracks[ti].notes = reharmonize(tracks[ti].notes, color: color, pool: pool, secPerBar: secPerBar, bars: bars)
        engine.prepare(tracks: effectiveTracks())
    }

    /// Substitute a chord track's progression (relative / bright / jazzy), keeping bar 0 as the
    /// tonic anchor. Changes the roots, so re-generate any following bass/melody afterward.
    func substituteProgression(on track: Track, sub: ChordSub) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        let secPerBar = Double(beatsPerBar) * 60.0 / max(1, tempo)
        let bars = max(1, Int(ceil(tracks[ti].endTime / secPerBar - 1e-6)))
        let pool = Array(Set(tracks[ti].notes.map { ((($0.pitch % 12) + 12) % 12) })).sorted()
        let sourceID = tracks[ti].id
        asOneUndoStep {
            tracks[ti].notes = substituteChords(tracks[ti].notes, sub: sub, pool: pool, secPerBar: secPerBar, bars: bars)
            // Keep the rhythm section locked: re-run any bass/melody that follows this chord track.
            let followers = tracks.filter { $0.id != sourceID && $0.isInstrument && !$0.isDrumKit }
            for other in followers {
                if bassFollowID == sourceID, other.program >= 32, other.program <= 39 { applyBassPlayer(on: other) }
                if melodyFollowID == sourceID, other.program >= 80, other.program <= 87 { applyMelody(on: other) }
            }
            engine.prepare(tracks: effectiveTracks())
        }
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
        tracks[ti].notes = applySwing(tracks[ti].notes, amount: amount, grid: grid)
    }

    // MARK: - Groove lock (shared swing across the melodic parts)

    @Published var grooveAmount: Double = 0

    /// Lock bass, melody, and keys into one shuffle by swinging their 8th-notes together. Drums
    /// keep the Drummer's own feel (so 16th patterns aren't quantized away). Idempotent.
    func lockGroove(_ amount: Double) {
        grooveAmount = amount
        let grid = (60.0 / max(1, tempo)) / 2       // 8th-note swing
        recordUndo()
        for ti in tracks.indices where tracks[ti].isInstrument && !tracks[ti].isDrumKit && !tracks[ti].notes.isEmpty {
            tracks[ti].notes = applySwing(tracks[ti].notes, amount: amount, grid: grid)
        }
        engine.prepare(tracks: effectiveTracks())
    }

    /// Add subtle timing + velocity variation to a track's notes.
    func humanizeNotes(on track: Track, timing: TimeInterval, velocity: Int) {
        guard let ti = tracks.firstIndex(where: { $0.id == track.id }), !tracks[ti].notes.isEmpty else { return }
        recordUndo()
        tracks[ti].notes = humanize(tracks[ti].notes, timing: timing, velocity: velocity,
                                    seed: UInt64.random(in: 1...UInt64.max))
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

    /// Choose the AU instrument for a track (nil = built-in GM synth). Rebuilds the chain.
    func setInstrument(_ track: Track, _ ref: PluginRef?) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        recordUndo()
        tracks[i].instrumentPlugin = ref
        engine.reload(tracks: effectiveTracks())
    }

    func instrumentUnit(trackID: UUID) -> AVAudioUnit? {
        engine.instrumentUnit(trackID: trackID)
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

    private var suppressUndo = false

    private func recordUndo() {
        if suppressUndo { return }
        undoStack.append(currentSnapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    /// Run `body` as a single undo step — nested recordUndo() calls are folded in, and the
    /// snapshot is taken before any change, so one undo cleanly reverts the whole operation.
    private func asOneUndoStep(_ body: @MainActor () -> Void) {
        if suppressUndo { body(); return }      // already inside a group
        recordUndo()
        suppressUndo = true
        defer { suppressUndo = false }          // stays robust even if body traps
        body()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        applyState(previous)
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        applyState(next)
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    private func applyState(_ s: Snapshot) {
        stop()
        selectedClipID = nil
        tracks = s.tracks
        groups = s.groups
        tempo = s.tempo
        tempoPoints = s.tempoPoints
        markers = s.markers
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

    // MARK: - Takes / comping

    /// Make take `index` the active performance. Its offset/duration mirror into the clip,
    /// so playback and export follow the comp with no other changes.
    func selectTake(_ clip: Clip, on track: Track, index: Int) {
        recordUndo()
        updateClip(clip, on: track) { c in
            guard c.takes.indices.contains(index) else { return }
            c.activeTake = index
            c.offset = c.takes[index].offset
            c.duration = c.takes[index].duration
            c.fadeIn = 0; c.fadeOut = 0   // fades were relative to the old take's edges
        }
        engine.applyMix(tracks: effectiveTracks())
    }

    /// Collapse the take folder to just the active take (commit the comp).
    func flattenTakes(_ clip: Clip, on track: Track) {
        recordUndo()
        updateClip(clip, on: track) { $0.takes = []; $0.activeTake = 0 }
    }

    /// Remove one take from the folder, keeping a sensible active take.
    func deleteTake(_ clip: Clip, on track: Track, index: Int) {
        recordUndo()
        updateClip(clip, on: track) { c in
            guard c.takes.indices.contains(index), c.takes.count > 1 else { return }
            c.takes.remove(at: index)
            let newActive = min(c.activeTake > index ? c.activeTake - 1 : c.activeTake, c.takes.count - 1)
            c.activeTake = max(0, newActive)
            c.offset = c.takes[c.activeTake].offset
            c.duration = c.takes[c.activeTake].duration
            c.fadeIn = 0; c.fadeOut = 0
        }
        engine.applyMix(tracks: effectiveTracks())
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
    func addLoopToProject(_ loop: LoopEntry, fitTempo: Bool = false) {
        guard let url = loops.url(for: loop) else { return }
        let at = currentTime
        let rate = fitTempo ? loopFitRate(loopBPM: loop.bpm, projectBPM: tempo) : nil
        let duration = loop.duration
        isImporting = true
        Task.detached(priority: .userInitiated) {
            // Fit to project tempo by time-stretching (pitch-preserved) when the loop's BPM is known.
            var finalURL = url
            if let rate, let dir = try? LibraryStorage.importsDirectory(),
               let stretched = ClipProcessing.timeStretch(url: url, offset: 0, duration: duration,
                                                          rate: rate, outputDir: dir) {
                finalURL = stretched
            }
            guard let waveform = WaveformLoader.load(url: finalURL) else {
                await MainActor.run { self.isImporting = false }
                return
            }
            let asset = AudioAsset(url: finalURL, duration: waveform.duration,
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
    /// Pitch classes of the current key (from scale lock), or [] for chromatic (nearest-note).
    private func currentScalePCs() -> [Int] {
        guard scaleLockEnabled else { return [] }
        let steps = scaleLockScale == .major ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10]
        return steps.map { (($0 + scaleLockRoot) % 12 + 12) % 12 }
    }

    /// Tune a vocal (or any monophonic clip) toward the project key and drop the result on a new
    /// track, leaving the raw take untouched. `strength` 0…1 (1 = full snap).
    func tuneClip(_ clip: Clip, on track: Track, strength: Float) {
        let scalePCs = currentScalePCs()
        let url = clip.asset.url, offset = clip.offset, duration = clip.duration
        let startTime = clip.startTime, name = track.name
        isImporting = true
        Task.detached(priority: .userInitiated) {
            guard let dir = try? LibraryStorage.importsDirectory(),
                  let tuned = PitchTune.tune(url: url, offset: offset, duration: duration,
                                             scalePCs: scalePCs, strength: strength, outputDir: dir),
                  let waveform = WaveformLoader.load(url: tuned) else {
                await MainActor.run { self.isImporting = false; self.lastError = "Tuning failed." }
                return
            }
            let asset = AudioAsset(url: tuned, duration: waveform.duration,
                                   sampleRate: waveform.sampleRate, peaks: waveform.peaks)
            await MainActor.run {
                self.addNamedTrack(name: "\(name) (tuned)", asset: asset, at: startTime)
                self.isImporting = false
            }
        }
    }

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

    /// Render the mix and report its integrated loudness (LUFS) + peak — for hitting
    /// streaming targets (≈ −14 LUFS).
    func analyzeLoudness() {
        guard !tracks.isEmpty, !isExporting else { return }
        let snapshot = tracksWithLivePluginState()
        let duration = totalDuration, mv = masterVolume
        isExporting = true
        Task.detached(priority: .userInitiated) {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loud-\(UUID().uuidString).wav")
            do {
                try AudioExporter.render(tracks: snapshot, duration: duration, to: tmp, masterVolume: mv)
                let lufs = Loudness.integratedLUFS(url: tmp)
                let peak = Loudness.peakDBFS(url: tmp)
                try? FileManager.default.removeItem(at: tmp)
                await MainActor.run {
                    self.isExporting = false
                    let l = lufs.map { String(format: "%.1f LUFS", $0) } ?? "—"
                    let p = peak.map { String(format: "%.1f dBFS", $0) } ?? "—"
                    self.infoMessage = "Mix loudness: \(l) integrated · peak \(p).\n\n"
                        + "Streaming targets: ≈ −14 LUFS (Spotify/YouTube), −16 (Apple Music). "
                        + "Louder (closer to 0) hits harder; keep peak below 0."
                }
            } catch {
                await MainActor.run {
                    self.isExporting = false
                    self.lastError = "Loudness analysis failed: \(error.localizedDescription)"
                }
            }
        }
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

    /// Dev-only: write a mono sine tone (for the vocal-tuning smoke demo).
    private static func writeTestTone(to url: URL, freq: Double, seconds: Double, sampleRate: Double = 44_100) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * sampleRate)) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { ch[i] = Float(sin(2 * .pi * freq * Double(i) / sampleRate)) * 0.5 }
        }
        try? file.write(from: buffer)
    }

    func newProject() {
        stop()
        engine.reset()
        tracks = []
        groups = []
        tempoPoints = []
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

    /// Dev/screenshot hook: load a demo project and optionally open a sheet (env GOSAN_OPEN),
    /// so the agent can launch straight into any screen and capture it.
    func loadDemoForScreenshot() {
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "empty" { newProject(); return }
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "songstarter" { newProject(); activeSheet = .songStarter; return }
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "song" {
            newProject(); startSong(key: 0, vibe: SongVibe.all[0]); return
        }
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "fullsong" {
            newProject(); pixelsPerSecond = 30; startFullSong(key: 0, vibe: SongVibe.all[0]); return
        }
        // Undo-regression harness: a full song (Trap, 140 BPM, 6 markers, 4 tracks) then one undo
        // must revert cleanly to an empty 120-BPM project with no orphan markers/tempo.
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "undotest" {
            newProject(); tempo = 120; startFullSong(key: 0, vibe: SongVibe.all[2]); undo(); return
        }
        // Vocal-tuning runtime smoke: load a slightly-sharp tone and tune it → a "(tuned)" track appears.
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "tune" {
            newProject()
            if let dir = try? LibraryStorage.importsDirectory() {
                let url = dir.appendingPathComponent("demo-vocal.wav")
                Self.writeTestTone(to: url, freq: 448, seconds: 2)
                if let wf = WaveformLoader.load(url: url) {
                    addNamedTrack(name: "Vocal", asset: AudioAsset(url: url, duration: wf.duration,
                                                                   sampleRate: wf.sampleRate, peaks: wf.peaks))
                    if let t = tracks.first, let c = t.clips.first { tuneClip(c, on: t, strength: 1.0) }
                }
            }
            return
        }
        let peaks: [Float] = (0..<256).map { Float(abs(sin(Double($0) * 0.15)) * 0.85) }
        func asset(_ name: String) -> AudioAsset {
            AudioAsset(url: URL(fileURLWithPath: "/tmp/\(name).wav"), duration: 7, sampleRate: 44_100, peaks: peaks)
        }
        var vox = Track(name: "Lead Vocal", colorIndex: 0); vox.clips = [Clip(asset: asset("vox"), startTime: 0.5)]
        var keys = Track(name: "Keys", colorIndex: 4); keys.isInstrument = true
        keys.notes = chordProgression(root: 0, scale: .major, degrees: [0, 4, 5, 3], barDuration: 2, octave: 4)
        var drums = Track(name: "Drums", colorIndex: 6); drums.isInstrument = true; drums.isDrumKit = true
        drums.notes = DrumPatterns.notes(DrumPatterns.all[0], bars: 2, stepDur: 0.125)
        tracks = [vox, keys, drums]
        tempo = 120
        // Demo tempo track: half-time drop at the chorus so the grid visibly widens.
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "tempo" {
            tempoPoints = [TempoPoint(time: 4, bpm: 84), TempoPoint(time: 6, bpm: 150)]
        }
        // Demo take folder: a 3-pass cycle-recorded vocal comp.
        if ProcessInfo.processInfo.environment["GOSAN_OPEN"] == "takes" {
            var takeClip = Clip(asset: asset("vocal comp"), startTime: 0.5)
            takeClip.takes = cycleTakeWindows(recorded: 6.0, loopLength: 2.0)
            takeClip.activeTake = 1
            takeClip.offset = takeClip.takes[1].offset
            takeClip.duration = takeClip.takes[1].duration
            var takeTrack = Track(name: "Vocal Comp", colorIndex: 2)
            takeTrack.clips = [takeClip]
            tracks.insert(takeTrack, at: 1)
        }
        markers = [Marker(time: 2, name: "Verse"), Marker(time: 6, name: "Chorus")]
        engine.prepare(tracks: effectiveTracks())

        guard let open = ProcessInfo.processInfo.environment["GOSAN_OPEN"] else { return }
        let inst = tracks.first { $0.isInstrument && !$0.isDrumKit }
        let drum = tracks.first { $0.isDrumKit }
        switch open {
        case "pianoroll": if let i = inst { activeSheet = .pianoRoll(i.id) }
        case "stepseq": if let d = drum { activeSheet = .stepSequencer(d.id) }
        case "drummer":
            if let d = drum {
                drummerSettings = DrummerSettings(style: 1, complexity: 0.65, intensity: 0.8, swing: 0.2, fillEvery: 4)
                applyDrummer(on: d)
                activeSheet = .drummer(d.id)
            }
        case "bass":
            if let i = inst {
                bassFollowID = i.id
                bassSettings = BassSettings(pattern: 2, octave: 2, drive: 0.7)   // walking
                let id = addBassPlayer()
                activeSheet = .bassPlayer(id)
            }
        case "melody":
            if let i = inst {
                melodyFollowID = i.id
                melodySettings = MelodySettings(density: 0.6, motion: 0.4, register: 5)
                activeSheet = .melodyMaker(addMelodyMaker())
            }
        case "colors": if let i = inst { reharmonizeChords(on: i, color: .ninth); activeSheet = .pianoRoll(i.id) }
        case "substitute": if let i = inst { substituteProgression(on: i, sub: .relative); activeSheet = .pianoRoll(i.id) }
        case "chords": if let i = inst { activeSheet = .chords(i.id) }
        case "automation": if let i = inst { activeSheet = .automation(i.id) }
        case "mixer": activeSheet = .mixer
        case "loops": showLoopBrowser = true
        case "generate": activeSheet = .generate
        default: break
        }
    }

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
                            gain: clip.gain, muted: clip.muted, customName: clip.customName,
                            takes: clip.takes.map {
                                ProjectDocument.TakeData(offset: $0.offset, duration: $0.duration, name: $0.name)
                            },
                            activeTake: clip.activeTake)
                    },
                    isInstrument: track.isInstrument, isDrumKit: track.isDrumKit, program: track.program,
                    instrumentPlugin: track.instrumentPlugin,
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
            scaleLockEnabled: scaleLockEnabled, scaleLockRoot: scaleLockRoot,
            scaleLockScale: scaleLockScale.rawValue,
            tempoPoints: tempoPoints,
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
            track.instrumentPlugin = trackData.instrumentPlugin
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
                clip.takes = clipData.takes.map { Take(offset: $0.offset, duration: $0.duration, name: $0.name) }
                clip.activeTake = clipData.activeTake
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
        scaleLockEnabled = document.scaleLockEnabled
        scaleLockRoot = document.scaleLockRoot
        scaleLockScale = MusicScale(rawValue: document.scaleLockScale) ?? .major
        tempoPoints = document.tempoPoints
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
