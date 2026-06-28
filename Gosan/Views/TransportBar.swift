import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var project: ProjectStore

    private var jobsSummary: String {
        if let only = project.activeJobs.first, project.activeJobs.count == 1 {
            return "\(only.label) — \(only.status)…"
        }
        return "\(project.activeJobs.count) AI jobs running…"
    }

    var body: some View {
        HStack(spacing: 14) {
            Button { project.seek(to: 0) } label: {
                Image(systemName: "backward.end.fill")
            }
            .help("Return to start")

            Button { project.togglePlay() } label: {
                Image(systemName: project.isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help(project.isPlaying ? "Stop" : "Play")

            Text(timecode(project.currentTime))
                .font(.system(.body, design: .monospaced))
                .frame(width: 86, alignment: .leading)

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                Image(systemName: "metronome")
                Text("\(Int(project.tempo)) BPM")
            }
            .foregroundStyle(.secondary)

            if !project.activeJobs.isEmpty {
                Divider().frame(height: 18)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(jobsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $project.pixelsPerSecond, in: 24...200).frame(width: 130)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }

            Button { project.activeSheet = .generate } label: {
                Label("Generate", systemImage: "sparkles")
            }

            Button { project.requestImport() } label: {
                Label("Import", systemImage: "plus")
            }

            Button { project.exportMixdown() } label: {
                if project.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .disabled(project.tracks.isEmpty || project.isExporting)
            .help("Bounce the mix to a WAV file")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
