import SwiftUI

/// Generate a diatonic chord progression onto an instrument track.
struct ChordGeneratorView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    @State private var root = 0          // 0 = C
    @State private var scaleMinor = false
    @State private var progression = 0
    @State private var octave = 4

    private let roots = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private let progressions: [(name: String, degrees: [Int])] = [
        ("Pop  I–V–vi–IV", [0, 4, 5, 3]),
        ("Sad  vi–IV–I–V", [5, 3, 0, 4]),
        ("Doo-wop  I–vi–IV–V", [0, 5, 3, 4]),
        ("Jazz  ii–V–I", [1, 4, 0]),
        ("Andalusian  i–VII–VI–V", [0, 6, 5, 4]),
        ("Canon  I–V–vi–iii–IV–I–IV–V", [0, 4, 5, 2, 3, 0, 3, 4])
    ]

    private var track: Track? { project.tracks.first { $0.id == trackID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Generate Chords — \(track?.name ?? "")", systemImage: "pianokeys.inverse").font(.headline)

            HStack {
                Picker("Key", selection: $root) {
                    ForEach(0..<roots.count, id: \.self) { Text(roots[$0]).tag($0) }
                }.frame(width: 110)
                Picker("Scale", selection: $scaleMinor) {
                    Text("Major").tag(false); Text("Minor").tag(true)
                }.frame(width: 130)
                Stepper("Octave: \(octave)", value: $octave, in: 2...6).fixedSize()
            }

            Picker("Progression", selection: $progression) {
                ForEach(0..<progressions.count, id: \.self) { Text(progressions[$0].name).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Text("One chord per bar at the current tempo/time signature. Replaces the track's notes.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Generate") {
                    if let track {
                        project.generateChords(on: track, root: root,
                                               scale: scaleMinor ? .minor : .major,
                                               degrees: progressions[progression].degrees, octave: octave)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
