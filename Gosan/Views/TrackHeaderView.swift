import SwiftUI

struct TrackHeaderView: View {
    @EnvironmentObject var project: ProjectStore
    let track: Track

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.color(track.colorIndex))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                if isEditing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .onSubmit { project.renameTrack(track, to: draft); isEditing = false }
                } else {
                    Text(track.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { draft = track.name; isEditing = true }
                        .help("Double-click to rename")
                }

                HStack(spacing: 6) {
                    Toggle("M", isOn: Binding(
                        get: { track.isMuted },
                        set: { _ in project.toggleMute(track) }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .help("Mute")

                    Toggle("S", isOn: Binding(
                        get: { track.isSoloed },
                        set: { _ in project.toggleSolo(track) }
                    ))
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(.yellow)
                    .help("Solo")

                    Slider(value: Binding(
                        get: { Double(track.volume) },
                        set: { project.setVolume(track, Float($0)) }
                    ), in: 0...1)
                    .controlSize(.mini)
                    .help("Volume")
                }

                HStack(spacing: 6) {
                    Text("L").font(.system(size: 8)).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(track.pan) },
                        set: { project.setPan(track, Float($0)) }
                    ), in: -1...1)
                    .controlSize(.mini)
                    .help("Pan")
                    Text("R").font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)

            TrackMeter(level: project.trackLevels[track.id] ?? 0)
                .frame(width: 6)
                .padding(.vertical, 10)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .contextMenu {
            Button { draft = track.name; isEditing = true } label: { Label("Rename", systemImage: "pencil") }
            Button { project.duplicateTrack(track) } label: { Label("Duplicate Track", systemImage: "plus.square.on.square") }
            Button { project.moveTrack(track, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
            Button { project.moveTrack(track, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
            Menu {
                ForEach(0..<Palette.colors.count, id: \.self) { i in
                    Button {
                        project.setTrackColor(track, i)
                    } label: {
                        Label("Color \(i + 1)", systemImage: track.colorIndex == i ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: { Label("Color", systemImage: "paintpalette") }
            Menu {
                Button("Off") { project.setReverb(track, 0) }
                Button("Light") { project.setReverb(track, 0.25) }
                Button("Medium") { project.setReverb(track, 0.5) }
                Button("Heavy") { project.setReverb(track, 0.8) }
            } label: { Label("Reverb", systemImage: "waveform.path.ecg") }
            Menu {
                Button("Off") { project.setDelay(track, 0) }
                Button("Light") { project.setDelay(track, 0.2) }
                Button("Medium") { project.setDelay(track, 0.4) }
                Button("Heavy") { project.setDelay(track, 0.6) }
            } label: { Label("Delay", systemImage: "arrow.triangle.2.circlepath") }
            Menu {
                Button("Off") { project.setCompress(track, 0) }
                Button("Light") { project.setCompress(track, 0.3) }
                Button("Medium") { project.setCompress(track, 0.6) }
                Button("Heavy") { project.setCompress(track, 0.9) }
            } label: { Label("Compressor", systemImage: "rectangle.compress.vertical") }
            Menu {
                Button("Flat") { project.setEQ(track, low: 0, mid: 0, high: 0) }
                Button("Bright") { project.setEQ(track, low: 0, mid: 0, high: 5) }
                Button("Warm") { project.setEQ(track, low: 4, mid: 0, high: -3) }
                Button("Cut Lows") { project.setEQ(track, low: -8, mid: 0, high: 0) }
                Button("Telephone") { project.setEQ(track, low: -10, mid: 4, high: -8) }
            } label: { Label("EQ", systemImage: "slider.vertical.3") }
            Button { project.activeSheet = .automation(track.id) } label: {
                Label("Automation…", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            }
            if track.isInstrument {
                Divider()
                Button { project.activeSheet = .pianoRoll(track.id) } label: {
                    Label("Piano Roll…", systemImage: "pianokeys")
                }
            }
            Divider()
            Button { project.bounceTrack(track) } label: {
                Label("Bounce to New Track", systemImage: "square.and.arrow.down.on.square")
            }
            Divider()
            Button(role: .destructive) { project.deleteTrack(track) } label: {
                Label("Delete Track", systemImage: "trash")
            }
        }
    }
}

/// A thin vertical peak meter (green → yellow → red), filling from the bottom.
struct TrackMeter: View {
    let level: Float   // 0...1 peak

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.black.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(height: geo.size.height * CGFloat(min(1, max(0, level))))
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .help("Track level")
    }

    private var color: Color {
        if level > 0.9 { return .red }
        if level > 0.7 { return .yellow }
        return .green
    }
}
