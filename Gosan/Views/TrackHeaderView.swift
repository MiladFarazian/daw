import SwiftUI

struct TrackHeaderView: View {
    @EnvironmentObject var project: ProjectStore
    let track: Track

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.color(track.colorIndex))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(track.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

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
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }
}
