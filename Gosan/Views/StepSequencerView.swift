import SwiftUI

/// A drum-machine grid: toggle steps to program a beat. Each cell writes a short MIDI
/// note to the track's GM drum kit (channel 9), so it plays + exports like any notes.
struct StepSequencerView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID
    @State private var bars = 1

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var secPerBeat: Double { 60.0 / max(30, project.tempo) }
    private var stepDur: Double { secPerBeat / 4 }      // sixteenth notes
    private var steps: Int { bars * 16 }

    private let drums: [(name: String, pitch: Int)] = [
        ("Kick", 36), ("Snare", 38), ("Clap", 39), ("Cl Hat", 42),
        ("Op Hat", 46), ("Rim", 37), ("Tom", 45), ("Cowbell", 56)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Step Sequencer — \(track?.name ?? "")", systemImage: "square.grid.3x3.fill").font(.headline)
                Spacer()
                Stepper("Bars: \(bars)", value: $bars, in: 1...4).fixedSize()
                if let track {
                    Menu("Patterns") {
                        ForEach(DrumPatterns.all, id: \.name) { preset in
                            Button(preset.name) { project.applyDrumPattern(on: track, preset, bars: bars, stepDur: stepDur) }
                        }
                    }
                    .fixedSize().help("Drop in a preset beat")
                }
                if let track, !track.notes.isEmpty {
                    Menu("Swing") {
                        Button("Off (straight)") { project.swingNotes(on: track, amount: 0, grid: stepDur) }
                        Button("Light") { project.swingNotes(on: track, amount: 0.15, grid: stepDur) }
                        Button("Medium") { project.swingNotes(on: track, amount: 0.3, grid: stepDur) }
                        Button("Heavy") { project.swingNotes(on: track, amount: 0.4, grid: stepDur) }
                    }
                    .fixedSize()
                }
                Button("Clear") { clearAll() }.disabled(track?.notes.isEmpty ?? true)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(drums, id: \.pitch) { drum in
                        HStack(spacing: 3) {
                            Text(drum.name)
                                .font(.system(size: 10, weight: .medium))
                                .frame(width: 58, alignment: .leading)
                            ForEach(0..<steps, id: \.self) { step in
                                cell(pitch: drum.pitch, step: step)
                            }
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            Text("Tap cells to build a beat. Press the toolbar ▶ to hear it loop (set a loop region on the ruler).")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private func isOn(_ pitch: Int, _ step: Int) -> Bool {
        guard let track else { return false }
        let t = Double(step) * stepDur
        return track.notes.contains { $0.pitch == pitch && abs($0.start - t) < stepDur * 0.5 }
    }

    private func cell(pitch: Int, step: Int) -> some View {
        let on = isOn(pitch, step)
        let beatShade = (step / 4) % 2 == 0
        return RoundedRectangle(cornerRadius: 3)
            .fill(on ? Color.accentColor : Color.primary.opacity(beatShade ? 0.10 : 0.05))
            .frame(width: 22, height: 22)
            .overlay {
                if step % 4 == 0 {
                    RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .onTapGesture {
                guard let track else { return }
                project.toggleStepNote(on: track, pitch: pitch, start: Double(step) * stepDur,
                                       duration: stepDur * 0.9, velocity: 110)
                if !on { project.auditionNote(track, pitch: pitch) }
            }
    }

    private func clearAll() {
        guard let track else { return }
        for note in track.notes { project.deleteNote(note, from: track) }
    }
}
