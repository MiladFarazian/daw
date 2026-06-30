import SwiftUI

/// A mixing console: one vertical channel strip per track + a master strip.
struct MixerView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Mixer", systemImage: "slider.vertical.3").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(project.tracks) { track in
                        ChannelStrip(track: track)
                    }
                    if !project.tracks.isEmpty { MasterStrip() }
                }
                .padding(12)
            }

            if project.tracks.isEmpty {
                Text("Add a track to see the mixer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 460)
    }
}

private struct ChannelStrip: View {
    @EnvironmentObject var project: ProjectStore
    let track: Track

    private var volumeDB: String {
        let v = track.volume
        if v <= 0.0001 { return "−∞" }
        return String(format: "%+.0f", 20 * log10(v))
    }

    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Palette.color(track.colorIndex)).frame(height: 3)

            Text(track.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 84)

            // Pan
            VStack(spacing: 1) {
                Slider(value: Binding(get: { Double(track.pan) },
                                      set: { project.setPan(track, Float($0)) }), in: -1...1)
                    .controlSize(.mini).frame(width: 76)
                Text("pan").font(.system(size: 8)).foregroundStyle(.secondary)
            }

            // Meter + fader
            HStack(spacing: 8) {
                TrackMeter(level: project.trackLevels[track.id] ?? 0).frame(width: 8)
                VerticalFader(value: Binding(get: { Double(track.volume) },
                                             set: { project.setVolume(track, Float($0)) }))
            }
            .frame(height: 200)

            Text("\(volumeDB) dB").font(.system(size: 9)).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Toggle("M", isOn: Binding(get: { track.isMuted },
                                          set: { _ in project.toggleMute(track) }))
                    .toggleStyle(.button).controlSize(.mini).help("Mute")
                Toggle("S", isOn: Binding(get: { track.isSoloed },
                                          set: { _ in project.toggleSolo(track) }))
                    .toggleStyle(.button).controlSize(.mini).tint(.yellow).help("Solo")
            }
        }
        .padding(8)
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

private struct MasterStrip: View {
    @EnvironmentObject var project: ProjectStore

    var body: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Color.secondary).frame(height: 3)
            Text("Master").font(.system(size: 11, weight: .semibold)).frame(width: 84)

            // Master EQ
            VStack(spacing: 2) {
                eqRow("Hi", value: project.masterEqHigh) { project.setMasterEQ(low: project.masterEqLow, mid: project.masterEqMid, high: $0) }
                eqRow("Md", value: project.masterEqMid) { project.setMasterEQ(low: project.masterEqLow, mid: $0, high: project.masterEqHigh) }
                eqRow("Lo", value: project.masterEqLow) { project.setMasterEQ(low: $0, mid: project.masterEqMid, high: project.masterEqHigh) }
            }
            .frame(width: 84)

            HStack(spacing: 8) {
                TrackMeter(level: project.masterLevel).frame(width: 8)
                VerticalFader(value: Binding(get: { Double(project.masterVolume) },
                                             set: { project.setMasterVolume(Float($0)) }))
            }
            .frame(height: 200)

            Text("output").font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(width: 100)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }

    private func eqRow(_ label: String, value: Float, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 14)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: -12...12)
                .controlSize(.mini)
        }
    }
}

/// A fill-style vertical fader (drag anywhere to set 0…1).
struct VerticalFader: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.18))
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(height: max(0, h * value))
                RoundedRectangle(cornerRadius: 2).fill(Color.white)
                    .frame(height: 3)
                    .offset(y: -(h - 3) * value)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = min(1, max(0, Double(1 - g.location.y / max(1, h))))
            })
        }
        .frame(width: 22)
    }
}
