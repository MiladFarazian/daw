import SwiftUI

/// "Generate with Suno" — describe a vibe, get candidates, audition, keep the ones you like.
struct GeneratePanel: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var instrumental = true

    private var prompt: GeneratePrompt { GeneratePrompt(text: text, instrumental: instrumental) }
    private var canGenerate: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !project.isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Generate with Suno", systemImage: "sparkles").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Text("Describe the vibe — instruments, mood, genre, tempo. Your taste, their horsepower.")
                .font(.caption).foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 78)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))

            Toggle("Instrumental", isOn: $instrumental)

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
        }
        .padding(20)
        .frame(width: 520)
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
            Button("Add to timeline") { project.addCandidate(candidate) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
