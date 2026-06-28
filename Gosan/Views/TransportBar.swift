import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var recorder: Recorder

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

            Button { project.toggleRecord() } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(recorder.isRecording ? .red : .primary)
            }
            .help(recorder.isRecording ? "Stop recording" : "Record a take (plays existing tracks)")

            Button { project.toggleMonitoring() } label: {
                Image(systemName: "headphones")
                    .foregroundStyle(recorder.isMonitoring ? .green : .secondary)
            }
            .help("Monitor input (hear yourself — use headphones to avoid feedback)")

            if recorder.isRecording {
                InputLevelMeter(level: recorder.inputLevel)
                    .frame(width: 46, height: 6)
            }

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

            Button { project.snapEnabled.toggle() } label: {
                Image(systemName: "ruler")
                    .foregroundStyle(project.snapEnabled ? .green : .secondary)
            }
            .help("Snap clips to the beat grid")

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

/// A tiny horizontal input-level meter.
struct InputLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25))
                Capsule()
                    .fill(level > 0.9 ? Color.red : .green)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, level))))
            }
        }
    }
}
