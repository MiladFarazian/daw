import SwiftUI

/// The Melody Maker: writes a singable topline over the chords already in your project.
/// Dial density and motion, hit New Melody until one sticks — no note-writing required.
struct MelodyMakerView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var sources: [Track] { project.chordSources(excluding: trackID) }
    private func regen() { if let t = track { project.applyMelody(on: t) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Melody Maker — \(track?.name ?? "")", systemImage: "music.note").font(.headline)
                Spacer()
                Text("follows your chords").font(.caption).foregroundStyle(.secondary)
            }

            if sources.isEmpty {
                Label("Add an instrument track with chords first — the melody sits over it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                Picker("Follow", selection: Binding(
                    get: { project.melodyFollowID ?? sources.first?.id },
                    set: { project.melodyFollowID = $0 })) {
                    ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                .onChange(of: project.melodyFollowID) { _ in regen() }

                knob("Density", low: "held", high: "busy", value: $project.melodySettings.density)
                knob("Motion", low: "smooth", high: "leapy", value: $project.melodySettings.motion)

                Stepper("Register: octave \(project.melodySettings.register)",
                        value: $project.melodySettings.register, in: 4...6)
                    .fixedSize()
                    .onChange(of: project.melodySettings.register) { _ in regen() }

                MelodyPreview(notes: track?.notes ?? [], secPerBar: secPerBar, register: project.melodySettings.register)
                    .frame(height: 64)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
            }

            HStack(spacing: 10) {
                Button { regen() } label: { Label("New Melody", systemImage: "dice") }
                    .disabled(sources.isEmpty)
                Button { project.togglePlay() } label: {
                    Label(project.isPlaying ? "Stop" : "Play",
                          systemImage: project.isPlaying ? "stop.fill" : "play.fill")
                }
                .disabled(sources.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var secPerBar: Double { Double(project.beatsPerBar) * 60.0 / max(1, project.tempo) }

    private func knob(_ title: String, low: String, high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1) { editing in if !editing { regen() } }
            HStack { Text(low); Spacer(); Text(high) }
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

/// A mini piano-roll strip of the generated topline over the first four bars.
struct MelodyPreview: View {
    let notes: [MIDINote]
    let secPerBar: Double
    let register: Int

    var body: some View {
        Canvas { ctx, size in
            let span = max(secPerBar * 4, 0.001)
            let center = (register + 1) * 12
            let lo = Double(center - 4), hi = Double(center + 15)
            for n in notes where n.start < span {
                let x = CGFloat(n.start / span) * size.width
                let w = max(3, CGFloat(min(n.duration, span) / span) * size.width - 1)
                let norm = (Double(n.pitch) - lo) / (hi - lo)
                let y = (1 - CGFloat(max(0, min(1, norm)))) * (size.height - 8) + 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 5), cornerRadius: 2),
                         with: .color(.green.opacity(0.85)))
            }
        }
        .padding(6)
    }
}
