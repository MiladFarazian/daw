import SwiftUI

/// A minimal piano-roll editor for an instrument track: click empty grid to add a
/// note, click a note to remove it. Pitch on the vertical axis, time on the horizontal.
struct PianoRollView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    private let lowPitch = 36          // C2
    private let highPitch = 84         // C6
    private let rowHeight: CGFloat = 16
    private let pps: CGFloat = 120     // pixels per second
    private let snap = 0.25            // seconds
    @State private var noteLength = 0.5

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var pitches: [Int] { Array((lowPitch...highPitch).reversed()) }   // high pitch on top
    private var contentWidth: CGFloat { CGFloat(max(8, (track?.endTime ?? 4) + 4)) * pps }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Piano Roll — \(track?.name ?? "")", systemImage: "pianokeys").font(.headline)
                Spacer()
                if let track {
                    Picker("Sound", selection: Binding(
                        get: { track.program },
                        set: { project.setProgram(track, $0) })) {
                        ForEach(Self.programs, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .frame(width: 150)
                }
                Picker("Length", selection: $noteLength) {
                    Text("1/8").tag(0.25); Text("1/4").tag(0.5)
                    Text("1/2").tag(1.0); Text("Whole").tag(2.0)
                }
                .frame(width: 130)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView([.vertical, .horizontal]) {
                grid
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    private var grid: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(pitches, id: \.self) { pitch in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(isBlackKey(pitch) ? Color.primary.opacity(0.06) : Color.clear)
                            .frame(width: contentWidth, height: rowHeight)
                        if pitch % 12 == 0 {
                            Text("C\(pitch / 12 - 1)")
                                .font(.system(size: 8)).foregroundStyle(.secondary).padding(.leading, 3)
                        }
                    }
                    .overlay(Rectangle().fill(Color.gray.opacity(0.12)).frame(height: 0.5), alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let track else { return }
                        let t = max(0, (Double(value.location.x / pps) / snap).rounded(.down) * snap)
                        project.addNote(MIDINote(pitch: pitch, start: t, duration: noteLength), to: track)
                    })
                }
            }

            if let track {
                ForEach(track.notes) { note in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.25)))
                        .frame(width: max(5, CGFloat(note.duration) * pps), height: rowHeight - 2)
                        .offset(x: CGFloat(note.start) * pps,
                                y: CGFloat(highPitch - note.pitch) * rowHeight + 1)
                        .onTapGesture { project.deleteNote(note, from: track) }
                        .help("Click to delete")
                }
            }
        }
    }

    private func isBlackKey(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }

    /// A handful of common General-MIDI programs.
    static let programs: [(Int, String)] = [
        (0, "Grand Piano"), (4, "E. Piano"), (24, "Nylon Guitar"), (27, "Clean Guitar"),
        (33, "Finger Bass"), (38, "Synth Bass"), (48, "Strings"), (52, "Choir"),
        (56, "Trumpet"), (73, "Flute"), (80, "Square Lead"), (81, "Saw Lead"), (88, "Warm Pad")
    ]
}
