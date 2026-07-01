import SwiftUI

/// The Drummer: dial a groove with a few taste knobs instead of editing notes.
/// Every change re-generates the drum track, so you audition by ear, not theory.
struct DrummerView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var settings: Binding<DrummerSettings> { $project.drummerSettings }

    private func regen() { if let t = track { project.applyDrummer(on: t) } }

    private var fillLabel: String {
        settings.wrappedValue.fillEvery == 0 ? "Fills: off"
            : "Fill every \(settings.wrappedValue.fillEvery) bars"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Drummer — \(track?.name ?? "")", systemImage: "music.quarternote.3").font(.headline)
                Spacer()
                Text("no theory needed").font(.caption).foregroundStyle(.secondary)
            }

            Picker("Style", selection: settings.style) {
                ForEach(0..<DrumPatterns.all.count, id: \.self) { Text(DrumPatterns.all[$0].name).tag($0) }
            }
            .pickerStyle(.menu).fixedSize()
            .onChange(of: project.drummerSettings.style) { _ in regen() }

            knob("Complexity", low: "sparse", high: "busy", value: settings.complexity)
            knob("Intensity", low: "soft", high: "hard", value: settings.intensity)
            knob("Swing", low: "straight", high: "shuffle", value: settings.swing)

            Stepper(fillLabel, value: settings.fillEvery, in: 0...8)
                .fixedSize()
                .onChange(of: project.drummerSettings.fillEvery) { _ in regen() }

            GroovePreview(notes: track?.notes ?? [], secPerBar: secPerBar)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))

            HStack(spacing: 10) {
                Button { regen() } label: { Label("New Groove", systemImage: "dice") }
                Button { project.togglePlay() } label: {
                    Label(project.isPlaying ? "Stop" : "Play",
                          systemImage: project.isPlaying ? "stop.fill" : "play.fill")
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var secPerBar: Double { Double(project.beatsPerBar) * 60.0 / max(1, project.tempo) }

    /// A labeled 0–1 slider that re-generates the groove when you let go.
    private func knob(_ title: String, low: String, high: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(value.wrappedValue * 100))%").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1) { editing in if !editing { regen() } }
            HStack {
                Text(low); Spacer(); Text(high)
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}

/// A tiny at-a-glance view of the generated groove: rows for kick / snare / hats / other,
/// dots sized by velocity, over the first two bars.
struct GroovePreview: View {
    let notes: [MIDINote]
    let secPerBar: Double

    private func row(for pitch: Int) -> Int {
        switch pitch {
        case 36: return 3          // kick  (bottom)
        case 38, 39: return 2      // snare / clap
        case 42, 46: return 1      // hats
        default: return 0          // toms / perc (top)
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let span = max(secPerBar * 2, 0.001)     // show two bars
            let rows = 4
            let rowH = size.height / CGFloat(rows)
            // faint row guides
            for r in 0...rows {
                let y = CGFloat(r) * rowH
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
            }
            for n in notes where n.start < span {
                let x = CGFloat(n.start / span) * size.width
                let y = (CGFloat(row(for: n.pitch)) + 0.5) * rowH
                let s = 3 + CGFloat(n.velocity) / 127.0 * 5
                let color: Color = n.pitch == 36 ? .orange : (n.pitch == 38 || n.pitch == 39 ? .pink : .cyan)
                ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)),
                         with: .color(color.opacity(0.85)))
            }
        }
        .padding(6)
    }
}
