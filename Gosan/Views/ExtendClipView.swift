import SwiftUI

/// Sheet for "Extend with Suno" — generates a continuation that starts where the clip
/// ends and lands right after it on the same track.
struct ExtendClipView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss

    let clipID: UUID

    @State private var direction = ""
    @State private var styleTags = ""

    /// Resolve the clip at render time (same pattern as PianoRollView → track).
    private var clip: Clip? {
        project.tracks.flatMap(\.clips).first { $0.id == clipID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Extend with Suno", systemImage: "arrow.right.to.line")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Text("Generates a continuation that starts where this clip ends and lands right after it on the same track.")
                .font(.caption).foregroundStyle(.secondary)

            if let clip {
                content(for: clip)
            } else {
                Spacer()
                Text("Clip no longer exists.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let c = clip, let tags = c.asset.sunoStyleTags {
                styleTags = tags
            }
        }
    }

    @ViewBuilder
    private func content(for clip: Clip) -> some View {
        // Clip info
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(timecode(clip.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

        // Direction
        VStack(alignment: .leading, spacing: 4) {
            Label("Direction", systemImage: "arrow.turn.right.down").font(.caption.weight(.medium))
            Text("Where should it go next?")
                .font(.caption2).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if direction.isEmpty {
                    Text("e.g. build energy, add a drop")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $direction)
                    .font(.body)
                    .frame(height: 60)
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
        }

        // Style tags
        VStack(alignment: .leading, spacing: 4) {
            Label("Style Tags", systemImage: "tag").font(.caption.weight(.medium))
            TextField("Match the original vibe automatically", text: $styleTags)
                .textFieldStyle(.roundedBorder)
        }

        // Actions
        HStack(spacing: 10) {
            Button {
                project.extendClip(clip, prompt: direction, styleTags: styleTags)
                dismiss()
            } label: {
                Label("Extend", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(project.isGenerating)

            if project.isGenerating { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
        }
    }
}
