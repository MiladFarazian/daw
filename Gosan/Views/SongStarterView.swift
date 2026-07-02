import SwiftUI

/// Song Starter 2.0 — two tabs: Produce (Suno AI) and Sketch (MIDI).
struct SongStarterView: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @EnvironmentObject var taste: TasteEngine
    @Environment(\.dismiss) private var dismiss

    // MARK: - Tab state
    @State private var selectedTab: Tab = .produce

    // MARK: - Shared Musical state
    @State private var key: Int = 0
    @State private var vibeID: Int = 0
    @State private var isMinor: Bool = false

    private let roots = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private var vibe: SongVibe { SongVibe.all.first { $0.id == vibeID } ?? SongVibe.all[0] }

    // MARK: - Tab 1 (Produce) state
    @State private var bpm: Double = 120
    @State private var instrumental: Bool = true
    @State private var fullSong: Bool = false
    @State private var splitStems: Bool = true
    @State private var activeChips: Set<String> = []
    @State private var promptText: String = ""
    @State private var customized: Bool = false

    // MARK: - Tab 2 (Sketch) state
    @State private var sketchFullSong: Bool = false

    private enum Tab: Hashable { case produce, sketch }

    // MARK: - Chip groups
    private let moodChips = ["dreamy", "dark", "uplifting", "melancholy", "aggressive", "chill"]
    private let textureChips = ["acoustic", "electronic", "analog synths", "live drums", "strings", "piano-led", "guitar-driven", "808s"]

    // MARK: - Sidecar appearance helpers
    private var sidecarColor: Color {
        switch project.sidecarStatus {
        case .ready:        return .green
        case .unauthorized: return .orange
        case .offline:      return .red
        case .checking:     return .secondary
        }
    }
    private var sidecarText: String {
        switch project.sidecarStatus {
        case .ready:        return "Suno sidecar connected"
        case .unauthorized: return "Sidecar running, but the Suno cookie is missing or expired — re-grab it and restart the sidecar"
        case .offline:      return "Sidecar not reachable — start it, or use \"Open in Suno (manual)\" below"
        case .checking:     return "Checking sidecar..."
        }
    }

    // MARK: - Prompt compilation
    private func compiledPrompt() -> String {
        var parts: [String] = []
        if !vibe.styleTags.isEmpty { parts.append(vibe.styleTags) }
        if !activeChips.isEmpty {
            let sorted = activeChips.sorted()
            parts.append(sorted.joined(separator: ", "))
        }
        let keyName = roots[key]
        let mode = isMinor ? "minor" : "major"
        parts.append("\(keyName) \(mode)")
        parts.append("\(Int(bpm)) bpm")
        if fullSong {
            parts.append("full song structure: intro, verses, choruses, outro")
        } else {
            parts.append("seamless loop, consistent groove, no intro or outro")
        }
        return parts.joined(separator: ", ")
    }

    private func recompileIfNeeded() {
        guard !customized else { return }
        promptText = compiledPrompt()
    }

    private var canGenerate: Bool {
        !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !project.isGenerating
    }

    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header + tab picker
            HStack {
                Label("Song Starter", systemImage: "music.note.house.fill").font(.headline)
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("Produce (Suno)").tag(Tab.produce)
                    Text("Sketch (MIDI)").tag(Tab.sketch)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if selectedTab == .produce {
                produceTab
            } else {
                sketchTab
            }
        }
        .frame(width: 560)
        .onAppear {
            // Default to produce unless sidecar is offline; initialize BPM from project
            if project.sidecarStatus == .offline {
                selectedTab = .sketch
            }
            bpm = project.tempo
            recompileIfNeeded()
            project.checkSidecar()
        }
        .onChange(of: selectedTab) { _, _ in
            // nothing — each tab manages its own state
        }
    }

    // MARK: - Tab 1: Produce (Suno)
    private var produceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                // 1. Sidecar status row + credits
                HStack(spacing: 6) {
                    Circle().fill(sidecarColor).frame(width: 7, height: 7)
                    Text(sidecarText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let credits = project.sunoCredits {
                        Text("\(credits.creditsLeft.formatted()) credits")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                // Offline / unauthorized guidance banner
                if project.sidecarStatus == .offline || project.sidecarStatus == .unauthorized {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("The sidecar is not connected. You can still compose a prompt here, then use \"Open in Suno (manual)\" to finish in your browser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.08)))
                }

                Divider()

                // 2. Vibe seed
                Text("Vibe").font(.system(size: 12, weight: .semibold))
                VStack(spacing: 5) {
                    ForEach(SongVibe.all) { v in
                        Button {
                            vibeID = v.id
                            isMinor = v.minor
                            bpm = v.tempo
                            customized = false
                            recompileIfNeeded()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: vibeID == v.id ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(vibeID == v.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(v.name).font(.system(size: 13, weight: .semibold))
                                    Text(v.blurb).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(Int(v.tempo)) BPM · \(v.minor ? "min" : "maj")")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(vibeID == v.id ? Color.accentColor.opacity(0.12) : Color.clear))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Divider()

                // 3. Shape it: Mood + Texture chips
                Text("Shape it").font(.system(size: 12, weight: .semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text("Mood").font(.caption).foregroundStyle(.secondary)
                    chipRow(chips: moodChips)
                    Text("Texture").font(.caption).foregroundStyle(.secondary)
                    chipRow(chips: textureChips)
                }

                Divider()

                // 4. Musical anchors
                Text("Musical anchors").font(.system(size: 12, weight: .semibold))

                // Key + major/minor
                HStack(spacing: 12) {
                    Text("Key").font(.system(size: 12, weight: .medium))
                    Picker("Key", selection: $key) {
                        ForEach(0..<roots.count, id: \.self) { Text(roots[$0]).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: key) { _, _ in recompileIfNeeded() }

                    Picker("Mode", selection: $isMinor) {
                        Text("Major").tag(false)
                        Text("Minor").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                    .onChange(of: isMinor) { _, _ in recompileIfNeeded() }
                }

                // BPM
                HStack(spacing: 12) {
                    Text("BPM").font(.system(size: 12, weight: .medium))
                    Stepper(value: $bpm, in: 40...220, step: 1) {
                        Text("\(Int(bpm))").font(.system(size: 13, design: .monospaced)).frame(width: 34, alignment: .trailing)
                    }
                    .onChange(of: bpm) { _, _ in recompileIfNeeded() }
                }

                // Toggles row
                HStack(spacing: 20) {
                    Toggle("Instrumental", isOn: $instrumental)
                        .onChange(of: instrumental) { _, _ in recompileIfNeeded() }
                    Toggle("Use my taste", isOn: $project.useTaste)
                        .help("Nudge the prompt toward what you have kept before.")
                }

                // Arrangement
                Picker("Arrangement", selection: $fullSong) {
                    Text("Loopable groove").tag(false)
                    Text("Full song").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: fullSong) { _, _ in recompileIfNeeded() }

                Divider()

                // 5. Compiled prompt (editable)
                HStack {
                    Text("Prompt").font(.system(size: 12, weight: .semibold))
                    if customized {
                        Spacer()
                        Button("Reset") {
                            customized = false
                            promptText = compiledPrompt()
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                }

                TextEditor(text: Binding(
                    get: { promptText },
                    set: { newVal in
                        promptText = newVal
                        customized = true
                    }
                ))
                .font(.body)
                .frame(height: 64)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))

                // 6. Actions
                HStack(spacing: 10) {
                    Button {
                        project.generate(GeneratePrompt(text: promptText, instrumental: instrumental))
                    } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canGenerate)

                    Button {
                        project.openInSunoManually(GeneratePrompt(text: promptText, instrumental: instrumental))
                    } label: {
                        Label("Open in Suno (manual)", systemImage: "arrow.up.forward.app")
                    }
                    .help("Copies the prompt and opens Suno. Download the result, then drag it onto the timeline.")

                    if project.isGenerating { ProgressView().controlSize(.small) }
                    Spacer()
                }

                if !project.lastNudge.isEmpty {
                    Label("Nudged toward: \(project.lastNudge.joined(separator: ", "))", systemImage: "wand.and.stars")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }

                // 7. Results
                if !project.candidates.isEmpty {
                    Divider()

                    HStack {
                        Text("Results").font(.subheadline.weight(.semibold))
                        Spacer()
                        Toggle("Split into stems (separate tracks)", isOn: $splitStems)
                            .font(.caption)
                    }

                    VStack(spacing: 8) {
                        ForEach(project.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }

                    Text("Lands as separate Vocals / Instrumental tracks you can mix independently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Taste section (mirrors GeneratePanel)
                tasteSection
            }
            .padding(20)
        }
        .frame(maxHeight: 580)
    }

    // MARK: - Chip row helper
    private func chipRow(chips: [String]) -> some View {
        FlexHStack(chips: chips, activeChips: $activeChips, onChange: {
            customized = false
            recompileIfNeeded()
        })
    }

    // MARK: - Candidate row
    private func candidateRow(_ candidate: CandidateAsset) -> some View {
        HStack(spacing: 12) {
            Button { preview.toggle(id: candidate.id, url: candidate.asset.url) } label: {
                Image(systemName: preview.playingID == candidate.id ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1)
                Text(timecode(candidate.asset.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { project.discardCandidate(candidate) } label: {
                Image(systemName: "hand.thumbsdown")
            }
            .help("Discard (teaches your taste what to avoid)")

            Button("Start song") {
                // Set project musical context to match choices
                project.tempo = bpm
                project.scaleLockEnabled = true
                project.scaleLockRoot = key
                project.scaleLockScale = isMinor ? .minor : .major

                if splitStems {
                    project.addCandidateAsStems(candidate)
                } else {
                    project.addCandidate(candidate)
                }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Set tempo + scale lock, then add to timeline")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Taste section
    @ViewBuilder
    private var tasteSection: some View {
        let top = taste.topDescriptors
        if !top.isEmpty || taste.preferredBPM != nil {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text("Your taste").font(.subheadline.weight(.semibold))
                Text("· \(taste.profile.keepCount) kept").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let bpmPref = taste.preferredBPM {
                        tasteChip("~\(bpmPref) bpm")
                    }
                    ForEach(top.prefix(8), id: \.descriptor) { item in
                        tasteChip(item.descriptor)
                    }
                }
            }
        }
    }

    private func tasteChip(_ label: String) -> some View {
        Text(label)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(.tint.opacity(0.15)))
            .foregroundStyle(.tint)
    }

    // MARK: - Tab 2: Sketch (MIDI)
    private var sketchTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Instant, offline — MIDI parts you can edit note by note.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Key").font(.system(size: 12, weight: .semibold))
                Picker("Key", selection: $key) {
                    ForEach(0..<roots.count, id: \.self) { Text(roots[$0]).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            Text("Vibe").font(.system(size: 12, weight: .semibold))
            VStack(spacing: 5) {
                ForEach(SongVibe.all) { v in
                    Button { vibeID = v.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: vibeID == v.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(vibeID == v.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).font(.system(size: 13, weight: .semibold))
                                Text(v.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(v.tempo)) BPM · \(v.minor ? "min" : "maj")")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(vibeID == v.id ? Color.accentColor.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("Arrangement", selection: $sketchFullSong) {
                Text("Loop (4 bars)").tag(false)
                Text("Full song (Intro · Verse · Chorus · Outro)").tag(true)
            }
            .pickerStyle(.radioGroup)

            Text("Adds four new tracks; your existing tracks are left untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    if sketchFullSong { project.startFullSong(key: key, vibe: vibe) }
                    else { project.startSong(key: key, vibe: vibe) }
                    dismiss()
                } label: {
                    Label("Generate Song", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
    }
}

// MARK: - FlexHStack: wrapping chip layout

/// A horizontally-wrapping row of toggle chips.
private struct FlexHStack: View {
    let chips: [String]
    @Binding var activeChips: Set<String>
    var onChange: () -> Void

    var body: some View {
        // Simple fixed-wrap approach: two rows of chips using ScrollView(.horizontal)
        // We use a flow layout via a custom layout that wraps if needed.
        // For simplicity and macOS compatibility, use a LazyVGrid with adaptive columns.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 6)], spacing: 6) {
            ForEach(chips, id: \.self) { chip in
                chipButton(chip)
            }
        }
    }

    private func chipButton(_ chip: String) -> some View {
        let active = activeChips.contains(chip)
        return Button {
            if active { activeChips.remove(chip) } else { activeChips.insert(chip) }
            onChange()
        } label: {
            Text(chip)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(active ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .foregroundStyle(active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
