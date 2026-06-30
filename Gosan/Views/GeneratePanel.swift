import SwiftUI

/// "Generate with Suno" — describe a vibe, get candidates, audition, keep the ones you like.
struct GeneratePanel: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @EnvironmentObject var taste: TasteEngine
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var instrumental = true

    private var prompt: GeneratePrompt { GeneratePrompt(text: text, instrumental: instrumental) }
    private var canGenerate: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !project.isGenerating
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
        case .unauthorized: return "Sidecar running, but your cookie isn’t authorized (401) — re-grab it & restart"
        case .offline: return "Sidecar not reachable — start it, or use “Open in Suno (manual)” below"
        case .checking: return "Checking sidecar…"
        }
    }

    var body: some View {
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
            }

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

            Divider()

            Text("Variants").font(.subheadline.weight(.semibold))
            if project.candidates.isEmpty {
                Text("Generated candidates appear here. Preview, then add the ones you like.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
        .frame(width: 520)
        .onAppear { project.checkSidecar() }
    }

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
