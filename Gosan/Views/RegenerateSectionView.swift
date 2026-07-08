import SwiftUI

/// Sheet for "Regenerate from here" — Suno regenerates a clip from a chosen split point
/// onward, in its style, and the app blends the new take back onto the timeline.
/// Everything before the split point is kept intact.
struct RegenerateSectionView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss

    let clipID: UUID

    @State private var direction = ""
    @State private var styleTags = ""
    @State private var split: Double = 0

    /// Resolve the clip at render time (same pattern as ExtendClipView → clip).
    private var clip: Clip? {
        project.tracks.flatMap(\.clips).first { $0.id == clipID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Regenerate from here", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Text("Suno regenerates this clip from the chosen point onward, in its style, and blends the new take onto the timeline. Everything before the point is kept.")
                .font(.caption).foregroundStyle(.secondary)

            if let clip {
                if clip.duration < 1.2 {
                    Spacer()
                    Text("This clip is too short to regenerate a section from.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Spacer()
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                    }
                } else {
                    content(for: clip)
                }
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
            guard let c = clip else { return }
            if let tags = c.asset.sunoStyleTags {
                styleTags = tags
            }
            let defaultSplit: Double
            if project.currentTime > c.startTime, project.currentTime < c.startTime + c.duration {
                defaultSplit = project.currentTime - c.startTime
            } else {
                defaultSplit = c.duration / 2
            }
            split = min(max(defaultSplit, 0.1), c.duration - 0.1)
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

        // Split point
        VStack(alignment: .leading, spacing: 4) {
            Label("Split Point", systemImage: "scissors").font(.caption.weight(.medium))
            Text("Regenerate from \(timecode(split))")
                .font(.caption2).foregroundStyle(.secondary)
            Slider(value: $split, in: 0.1...(max(0.1, clip.duration - 0.1)))
        }

        // Direction
        VStack(alignment: .leading, spacing: 4) {
            Label("Direction", systemImage: "arrow.turn.right.down").font(.caption.weight(.medium))
            Text("Where should it go from here?")
                .font(.caption2).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if direction.isEmpty {
                    Text("e.g. lift into a bigger chorus")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $direction)
                    .font(.body)
                    .frame(height: 54)
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
                project.regenerateSection(clip, at: split, prompt: direction, styleTags: styleTags)
                dismiss()
            } label: {
                Label("Regenerate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(project.isGenerating || project.busyClipIDs.contains(clipID))

            if project.isGenerating { ProgressView().controlSize(.small) }
            Spacer()
            Button("Cancel") { dismiss() }
        }

        if project.busyClipIDs.contains(clipID) {
            Text("A Suno job is already running on this clip.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
