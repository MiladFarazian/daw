import SwiftUI

/// The Bass Player: locks an auto-bassline to the chords already in your project.
/// Pick a track to follow and a feel — the bass line regenerates to match.
struct BassPlayerView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    private let patterns = ["Roots", "Octaves", "Walking", "Arpeggio", "Pump"]

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var sources: [Track] { project.chordSources(excluding: trackID) }
    private func regen() { if let t = track { project.applyBassPlayer(on: t) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Bass Player — \(track?.name ?? "")", systemImage: "guitars.fill").font(.headline)
                Spacer()
                Text("follows your chords").font(.caption).foregroundStyle(.secondary)
            }

            if sources.isEmpty {
                Label("Add an instrument track with chords first — the bass locks to it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Picker("Follow", selection: Binding(
                    get: { project.bassFollowID ?? sources.first?.id },
                    set: { project.bassFollowID = $0 })) {
                    ForEach(sources) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                .onChange(of: project.bassFollowID) { _ in regen() }

                Picker("Pattern", selection: $project.bassSettings.pattern) {
                    ForEach(0..<patterns.count, id: \.self) { Text(patterns[$0]).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: project.bassSettings.pattern) { _ in regen() }

                HStack(spacing: 20) {
                    Stepper("Octave: \(project.bassSettings.octave)", value: $project.bassSettings.octave, in: 1...4)
                        .fixedSize()
                        .onChange(of: project.bassSettings.octave) { _ in regen() }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Drive").font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(Int(project.bassSettings.drive * 100))%").font(.caption).foregroundStyle(.secondary)
                        }
                        Slider(value: $project.bassSettings.drive, in: 0...1) { editing in if !editing { regen() } }
                        HStack { Text("soft"); Spacer(); Text("hard") }
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }

                BassPreview(notes: track?.notes ?? [], secPerBar: secPerBar)
                    .frame(height: 60)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
            }

            HStack(spacing: 10) {
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
}

/// A low-register strip of the generated bass notes over the first four bars.
struct BassPreview: View {
    let notes: [MIDINote]
    let secPerBar: Double

    var body: some View {
        Canvas { ctx, size in
            let span = max(secPerBar * 4, 0.001)
            let lo = 24.0, hi = 55.0
            for n in notes where n.start < span {
                let x = CGFloat(n.start / span) * size.width
                let w = max(2, CGFloat(min(n.duration, span) / span) * size.width - 1)
                let norm = (Double(n.pitch) - lo) / (hi - lo)
                let y = (1 - CGFloat(max(0, min(1, norm)))) * (size.height - 8) + 2
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: 5), cornerRadius: 2),
                         with: .color(.purple.opacity(0.85)))
            }
        }
        .padding(6)
    }
}
