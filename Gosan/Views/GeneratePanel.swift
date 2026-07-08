import SwiftUI

/// "Generate with Suno" — describe a vibe, get candidates, audition, keep the ones you like.
struct GeneratePanel: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @EnvironmentObject var taste: TasteEngine
    @Environment(\.dismiss) private var dismiss

    // --- Describe mode ---
    @State private var text = ""

    // --- Shared ---
    @State private var instrumental = true

    // --- Custom mode ---
    @State private var mode: GenMode = .describe
    @State private var customTitle = ""
    @State private var customStyleTags = ""
    @State private var customNegativeTags = ""
    @State private var customLyrics = ""
    @State private var customModel: String? = nil   // nil = chirp-v3-5 default
    @State private var isWritingLyrics = false
    @State private var lyricsError: String? = nil

    enum GenMode: String, CaseIterable, Identifiable {
        case describe = "Describe"
        case custom   = "Custom"
        var id: String { rawValue }
    }

    private var prompt: GeneratePrompt { GeneratePrompt(text: text, instrumental: instrumental) }
    private var canGenerate: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !project.isGenerating
    }
    private var canGenerateCustom: Bool {
        let tagsEmpty   = customStyleTags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lyricsEmpty = customLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !(tagsEmpty && lyricsEmpty) && !project.isGenerating && !isWritingLyrics
    }

    private var sidecarColor: Color {
        switch project.sidecarStatus {
        case .ready: return .green
        case .unauthorized: return .orange
        case .offline: return .red
        case .checking: return .secondary
        }
    }
    private var sidecarText: String {
        switch project.sidecarStatus {
        case .ready: return "Suno sidecar connected"
        case .unauthorized: return "Sidecar running, but the Suno cookie is missing or expired — re-grab it & restart the sidecar"
        case .offline: return "Sidecar not reachable \u{2014} start it, or use \u{201C}Open in Suno (manual)\u{201D} below"
        case .checking: return "Checking sidecar…"
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Generate with Suno", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Circle().fill(sidecarColor).frame(width: 7, height: 7)
                Text(sidecarText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let credits = project.sunoCredits {
                    Text("\(credits.creditsLeft) credits")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // Mode picker
            Picker("Mode", selection: $mode) {
                ForEach(GenMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            if mode == .describe {
                describeSection
            } else {
                customSection
            }

            Divider()

            HStack {
                Text("Variants").font(.subheadline.weight(.semibold))
                Spacer()
                if project.candidates.count >= 2 {
                    Button {
                        project.activeSheet = .tournament
                    } label: {
                        Label("Taste Tournament", systemImage: "trophy")
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
            if project.candidates.isEmpty {
                Text("Generated candidates appear here. Preview, then add the ones you like.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if project.candidatesRanked {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Ranked by your taste — best match first.")
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(project.candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            tasteSection
        }
        .padding(20)
        }
        .frame(width: 520)
        .frame(maxHeight: 580)
        .onAppear { project.checkSidecar() }
    }

    // MARK: – Describe mode

    @ViewBuilder
    private var describeSection: some View {
        Text("Describe the vibe — instruments, mood, genre, tempo. Your taste, their horsepower.")
            .font(.caption).foregroundStyle(.secondary)

        TextEditor(text: $text)
            .font(.body)
            .frame(height: 78)
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))

        HStack(spacing: 16) {
            Toggle("Instrumental", isOn: $instrumental)
            Toggle("Use my taste", isOn: $project.useTaste)
                .help("Nudge the prompt toward what you've kept before.")
            Spacer()
        }

        HStack(spacing: 10) {
            Button { project.generate(prompt) } label: {
                Label("Generate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate)

            Button { project.openInSunoManually(prompt) } label: {
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
    }

    // MARK: – Custom mode

    @ViewBuilder
    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Title (optional)
            VStack(alignment: .leading, spacing: 4) {
                Label("Title", systemImage: "text.quote").font(.caption.weight(.medium))
                TextField("Optional title", text: $customTitle)
                    .textFieldStyle(.roundedBorder)
            }

            // Style tags (required unless lyrics provided)
            VStack(alignment: .leading, spacing: 4) {
                Label("Style Tags", systemImage: "tag").font(.caption.weight(.medium))
                TextField("e.g. dark synthwave, analog, 110 bpm", text: $customStyleTags)
                    .textFieldStyle(.roundedBorder)
            }

            // Negative tags (optional)
            VStack(alignment: .leading, spacing: 4) {
                Label("Negative Tags", systemImage: "nosign").font(.caption.weight(.medium))
                    .help("What to avoid")
                TextField("What to avoid (optional)", text: $customNegativeTags)
                    .textFieldStyle(.roundedBorder)
            }

            // Instrumental toggle (shared)
            Toggle("Instrumental", isOn: $instrumental)

            // Lyrics
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Label("Lyrics", systemImage: "music.note.list").font(.caption.weight(.medium))
                    Spacer()
                    if isWritingLyrics {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button {
                            let stylePrompt = [customTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                                               customStyleTags.trimmingCharacters(in: .whitespacesAndNewlines)]
                                .filter { !$0.isEmpty }.joined(separator: ", ")
                            isWritingLyrics = true
                            lyricsError = nil
                            Task {
                                do {
                                    let client = SunoSidecarClient(baseURL: project.settings.sunoSidecarURL)
                                    let result = try await client.generateLyrics(prompt: stylePrompt)
                                    await MainActor.run {
                                        customLyrics = result.text
                                        if customTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            customTitle = result.title
                                        }
                                        isWritingLyrics = false
                                    }
                                } catch {
                                    await MainActor.run {
                                        lyricsError = error.localizedDescription
                                        isWritingLyrics = false
                                    }
                                }
                            }
                        } label: {
                            Label("Write lyrics", systemImage: "pencil.and.sparkles")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            instrumental
                            || customStyleTags.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isWritingLyrics
                        )
                    }
                }
                ZStack(alignment: .topLeading) {
                    if customLyrics.isEmpty && !instrumental {
                        Text("Verse/chorus lyrics — leave empty to let Suno write them")
                            .font(.body)
                            .foregroundStyle(.secondary.opacity(0.6))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $customLyrics)
                        .font(.body)
                        .frame(height: 90)
                        .opacity(instrumental ? 0.4 : 1)
                        .disabled(instrumental)
                }
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                if instrumental {
                    Text("Lyrics are ignored in instrumental mode.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let err = lyricsError {
                    Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }

            // Model picker
            VStack(alignment: .leading, spacing: 4) {
                Label("Model", systemImage: "cpu").font(.caption.weight(.medium))
                Picker("Model", selection: $customModel) {
                    Text("Default (v3.5)").tag(String?.none)
                    Text("Chirp v4").tag(String?.some("chirp-v4"))
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 180)
            }

            // Generate button
            HStack(spacing: 10) {
                Button {
                    let req = CustomGenerateRequest(
                        styleTags: customStyleTags,
                        title: customTitle,
                        lyrics: instrumental ? "" : customLyrics,
                        negativeTags: customNegativeTags,
                        instrumental: instrumental,
                        model: customModel
                    )
                    project.generateCustom(req)
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canGenerateCustom)

                if project.isGenerating { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }

    // MARK: – Candidate row

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
            Button { project.saveCandidateAsLoop(candidate) } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .help("Save to Loop Library")
            if candidate.sunoClipID != nil {
                Button("Add as stems") { project.addCandidateAsStems(candidate) }
                    .help("Suno splits this take into Vocals + Instrumental tracks")
            }
            Button("Add to timeline") { project.addCandidate(candidate) }
                .help("Keep (teaches your taste what you like)")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private var tasteSection: some View {
        let top = taste.topDescriptors
        if top.isEmpty && taste.preferredBPM == nil {
            EmptyView()
        } else {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                Text("Your taste")
                    .font(.subheadline.weight(.semibold))
                Text("· \(taste.profile.keepCount) kept")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let bpm = taste.preferredBPM {
                        tasteChip("~\(bpm) bpm")
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
}
