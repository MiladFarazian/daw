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
    @State private var noteBeats = 1.0 // note length in beats (1 = quarter)
    @State private var newVelocity = 100.0

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var pitches: [Int] { Array((lowPitch...highPitch).reversed()) }   // high pitch on top
    private var secPerBeat: Double { 60.0 / max(30, project.tempo) }
    private var snapSec: Double { secPerBeat / 4 }          // snap to sixteenths
    private var contentWidth: CGFloat { CGFloat(max(8, (track?.endTime ?? 4) + 4)) * pps }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Piano Roll", systemImage: "pianokeys").font(.headline)
                if let track {
                    Text(track.name).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let track {
                    Picker("", selection: Binding(
                        get: { track.program },
                        set: { project.setProgram(track, $0) })) {
                        ForEach(Self.programs, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().frame(width: 144).help("Instrument sound")
                }
                Picker("", selection: $noteBeats) {
                    Text("1/8").tag(0.5); Text("1/4").tag(1.0)
                    Text("1/2").tag(2.0); Text("Whole").tag(4.0)
                }
                .labelsHidden().frame(width: 84).help("New note length")
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $newVelocity, in: 1...127).frame(width: 70)
                }
                .help("New note velocity: \(Int(newVelocity))")

                Menu {
                    Toggle("Scale Lock", isOn: Binding(get: { project.scaleLockEnabled },
                                                       set: { project.scaleLockEnabled = $0 }))
                    Divider()
                    Picker("Key", selection: Binding(get: { project.scaleLockRoot },
                                                     set: { project.scaleLockRoot = $0 })) {
                        ForEach(0..<12, id: \.self) { Text(Self.rootNames[$0]).tag($0) }
                    }
                    Picker("Scale", selection: Binding(get: { project.scaleLockScale == .minor },
                                                       set: { project.scaleLockScale = $0 ? .minor : .major })) {
                        Text("Major").tag(false); Text("Minor").tag(true)
                    }
                } label: {
                    Image(systemName: project.scaleLockEnabled ? "lock.fill" : "lock.open")
                        .foregroundStyle(project.scaleLockEnabled ? Color.green : Color.secondary)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help(project.scaleLockEnabled
                      ? "Scale Lock: \(Self.rootNames[project.scaleLockRoot]) \(project.scaleLockScale == .major ? "major" : "minor")"
                      : "Scale Lock (off) — snap added notes into a key")

                if let track {
                    Menu {
                        Button { project.activeSheet = .chords(trackID) } label: {
                            Label("Generate Chords…", systemImage: "pianokeys.inverse")
                        }
                        Menu("Arpeggiate") {
                            Button("Up · 1/16") { project.arpeggiateTrack(on: track, rate: secPerBeat / 4, pattern: .up) }
                            Button("Up · 1/8") { project.arpeggiateTrack(on: track, rate: secPerBeat / 2, pattern: .up) }
                            Button("Down · 1/16") { project.arpeggiateTrack(on: track, rate: secPerBeat / 4, pattern: .down) }
                            Button("Up-Down · 1/16") { project.arpeggiateTrack(on: track, rate: secPerBeat / 4, pattern: .upDown) }
                        }
                        Divider()
                        Section("Edit notes") {
                            Button("Quantize to 1/16") { project.quantizeNotes(on: track, to: snapSec) }
                            Menu("Transpose") {
                                Button("Octave Up (+12)") { project.transposeNotes(on: track, by: 12) }
                                Button("Octave Down (−12)") { project.transposeNotes(on: track, by: -12) }
                                Button("Semitone Up (+1)") { project.transposeNotes(on: track, by: 1) }
                                Button("Semitone Down (−1)") { project.transposeNotes(on: track, by: -1) }
                            }
                            Menu("Swing") {
                                Button("Off (straight)") { project.swingNotes(on: track, amount: 0, grid: secPerBeat / 4) }
                                Button("Light") { project.swingNotes(on: track, amount: 0.15, grid: secPerBeat / 4) }
                                Button("Medium") { project.swingNotes(on: track, amount: 0.3, grid: secPerBeat / 4) }
                                Button("Heavy") { project.swingNotes(on: track, amount: 0.4, grid: secPerBeat / 4) }
                            }
                        }
                    } label: {
                        Label("Tools", systemImage: "wand.and.stars")
                    }
                    .fixedSize()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView([.vertical, .horizontal]) {
                grid
            }
        }
        .frame(minWidth: 740, minHeight: 480)
    }

    private var grid: some View {
        let gridHeight = CGFloat(pitches.count) * rowHeight
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(pitches, id: \.self) { pitch in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(rowFill(pitch))
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
                        let t = max(0, (Double(value.location.x / pps) / snapSec).rounded(.down) * snapSec)
                        let snappedPitch = project.snappedPitch(pitch)
                        project.addNote(MIDINote(pitch: snappedPitch, start: t,
                                                 duration: noteBeats * secPerBeat,
                                                 velocity: Int(newVelocity)), to: track)
                        project.auditionNote(track, pitch: snappedPitch)
                    })
                }
            }

            // Beat / bar gridlines.
            Canvas { ctx, size in
                let beatPx = CGFloat(secPerBeat) * pps
                guard beatPx > 1 else { return }
                var beat = 0
                var x: CGFloat = 0
                while x <= size.width {
                    let isBar = beat % max(1, project.beatsPerBar) == 0
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(line, with: .color(.gray.opacity(isBar ? 0.32 : 0.12)), lineWidth: isBar ? 1 : 0.5)
                    beat += 1; x += beatPx
                }
            }
            .frame(width: contentWidth, height: gridHeight)
            .allowsHitTesting(false)

            if let track {
                ForEach(track.notes) { note in
                    NoteView(note: note, track: track, pps: pps, rowHeight: rowHeight,
                             lowPitch: lowPitch, highPitch: highPitch, snapSec: snapSec)
                }
            }
        }
    }

    private func isBlackKey(_ pitch: Int) -> Bool { [1, 3, 6, 8, 10].contains(pitch % 12) }

    /// Row shade: out-of-key rows are dimmed when Scale Lock is on; else black keys are tinted.
    private func rowFill(_ pitch: Int) -> Color {
        if project.scaleLockEnabled && !project.pitchInScale(pitch) { return Color.primary.opacity(0.14) }
        return isBlackKey(pitch) ? Color.primary.opacity(0.06) : Color.clear
    }

    /// One note: drag the body to move (time + pitch), drag the right edge to resize,
    /// tap to audition, right-click to delete. Commits to the model on drag end.
    private struct NoteView: View {
        @EnvironmentObject var project: ProjectStore
        let note: MIDINote
        let track: Track
        let pps: CGFloat
        let rowHeight: CGFloat
        let lowPitch: Int
        let highPitch: Int
        let snapSec: Double
        @State private var moveDrag: CGSize = .zero
        @State private var resizeDX: CGFloat = 0

        private var baseX: CGFloat { CGFloat(note.start) * pps }
        private var baseY: CGFloat { CGFloat(highPitch - note.pitch) * rowHeight + 1 }
        private var baseW: CGFloat { max(6, CGFloat(note.duration) * pps) }

        var body: some View {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor.opacity(0.40 + 0.55 * Double(note.velocity) / 127))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.25)))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.white.opacity(0.001)).frame(width: 8).gesture(resizeGesture)
                }
                .frame(width: max(6, baseW + resizeDX), height: rowHeight - 2)
                .offset(x: baseX + moveDrag.width, y: baseY + moveDrag.height)
                .gesture(moveGesture)
                .onTapGesture { project.auditionNote(track, pitch: note.pitch) }
                .contextMenu {
                    Menu("Velocity") {
                        Button("Soft (50)") { setVelocity(50) }
                        Button("Medium (90)") { setVelocity(90) }
                        Button("Loud (110)") { setVelocity(110) }
                        Button("Accent (127)") { setVelocity(127) }
                    }
                    Button(role: .destructive) { project.deleteNote(note, from: track) } label: {
                        Label("Delete Note", systemImage: "trash")
                    }
                }
        }

        private var moveGesture: some Gesture {
            DragGesture(minimumDistance: 3)
                .onChanged { moveDrag = $0.translation }
                .onEnded { v in
                    let nt = max(0, (Double((baseX + v.translation.width) / pps) / snapSec).rounded() * snapSec)
                    let np = min(highPitch, max(lowPitch, note.pitch - Int((v.translation.height / rowHeight).rounded())))
                    project.updateNote(note, on: track) { $0.start = nt; $0.pitch = np }
                    moveDrag = .zero
                }
        }

        private func setVelocity(_ v: Int) {
            project.updateNote(note, on: track) { $0.velocity = v }
        }

        private var resizeGesture: some Gesture {
            DragGesture(minimumDistance: 2)
                .onChanged { resizeDX = $0.translation.width }
                .onEnded { v in
                    let nd = max(snapSec, (Double((baseW + v.translation.width) / pps) / snapSec).rounded() * snapSec)
                    project.updateNote(note, on: track) { $0.duration = nd }
                    resizeDX = 0
                }
        }
    }

    static let rootNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    static func programName(_ program: Int) -> String {
        programs.first { $0.0 == program }?.1 ?? "Program \(program)"
    }

    /// A handful of common General-MIDI programs.
    static let programs: [(Int, String)] = [
        (0, "Grand Piano"), (4, "E. Piano"), (24, "Nylon Guitar"), (27, "Clean Guitar"),
        (33, "Finger Bass"), (38, "Synth Bass"), (48, "Strings"), (52, "Choir"),
        (56, "Trumpet"), (73, "Flute"), (80, "Square Lead"), (81, "Saw Lead"), (88, "Warm Pad")
    ]
}
