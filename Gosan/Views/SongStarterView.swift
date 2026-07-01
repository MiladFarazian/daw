import SwiftUI

/// One click to a full starting arrangement: pick a key and a vibe, and Gosan lays down
/// matching chords, bass, melody, and drums — all in key, all following each other.
struct SongStarterView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var key = 0
    @State private var vibeID = 0

    private let roots = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    private var vibe: SongVibe { SongVibe.all.first { $0.id == vibeID } ?? SongVibe.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Song Starter", systemImage: "music.note.house.fill").font(.headline)
                Spacer()
                Text("chords · bass · melody · drums").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("Key").font(.system(size: 12, weight: .semibold))
                Picker("Key", selection: $key) {
                    ForEach(0..<roots.count, id: \.self) { Text(roots[$0]).tag($0) }
                }.labelsHidden().fixedSize()
            }

            Text("Vibe").font(.system(size: 12, weight: .semibold))
            VStack(spacing: 6) {
                ForEach(SongVibe.all) { v in
                    Button { vibeID = v.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: vibeID == v.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(vibeID == v.id ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).font(.system(size: 13, weight: .semibold))
                                Text(v.blurb).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int(v.tempo)) BPM · \(v.minor ? "min" : "maj")")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(vibeID == v.id ? Color.accentColor.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Adds four new tracks; your existing tracks are left untouched.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button {
                    project.startSong(key: key, vibe: vibe)
                    dismiss()
                } label: {
                    Label("Generate Song", systemImage: "sparkles")
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
