import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var recorder: Recorder

    private var snapLabel: String {
        switch project.snapDivision {
        case 4: return "Bar"
        case 1: return "Beat"
        case 0.5: return "1/2"
        case 0.25: return "1/4"
        case 0.125: return "1/8"
        default: return "Snap"
        }
    }

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

            Button { project.countInEnabled.toggle() } label: {
                Image(systemName: "timer")
                    .foregroundStyle(project.countInEnabled ? .green : .secondary)
            }
            .help("1-bar count-in before recording")

            if recorder.isRecording {
                InputLevelMeter(level: recorder.inputLevel)
                    .frame(width: 46, height: 6)
            }

            Text(timecode(project.currentTime))
                .font(.system(.body, design: .monospaced))
                .frame(width: 86, alignment: .leading)

            Divider().frame(height: 18)

            HStack(spacing: 4) {
                Button { project.toggleMetronome() } label: {
                    Image(systemName: "metronome")
                        .foregroundStyle(project.metronomeEnabled ? .green : .secondary)
                }
                .help("Metronome click")

                TextField("", value: Binding(
                    get: { project.tempo },
                    set: { project.tempo = min(300, max(30, $0.rounded())) }
                ), format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 30)
                Text("BPM").foregroundStyle(.secondary)
                Stepper("", value: Binding(
                    get: { project.tempo },
                    set: { project.tempo = min(300, max(30, $0)) }
                ), in: 30...300, step: 1)
                .labelsHidden()
                Button("Tap") { project.tapTempo() }
                    .help("Tap repeatedly to set the tempo")
            }
            .help("Tempo (drives the beat grid + metronome)")

            Menu("\(project.beatsPerBar)/4") {
                ForEach([2, 3, 4, 5, 6, 7], id: \.self) { n in
                    Button("\(n)/4") { project.beatsPerBar = n }
                }
            }
            .frame(width: 46)
            .help("Time signature")

            Divider().frame(height: 18)
            HStack(spacing: 2) {
                Button { project.jumpToPrevMarker() } label: { Image(systemName: "chevron.backward.2") }
                    .help("Previous marker")
                Button { project.addMarker() } label: { Image(systemName: "flag") }
                    .help("Add marker at playhead")
                Button { project.jumpToNextMarker() } label: { Image(systemName: "chevron.forward.2") }
                    .help("Next marker")
            }

            Divider().frame(height: 18)
            HStack(spacing: 4) {
                Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                InputLevelMeter(level: project.masterLevel).frame(width: 54, height: 6)
            }
            .help("Master output level")

            Menu("EQ") {
                Button("Flat") { project.setMasterEQ(low: 0, mid: 0, high: 0) }
                Button("Bright") { project.setMasterEQ(low: 0, mid: 0, high: 4) }
                Button("Warm") { project.setMasterEQ(low: 3, mid: 0, high: -3) }
                Button("Loudness") { project.setMasterEQ(low: 4, mid: -1, high: 3) }
            }
            .frame(width: 48)
            .help("Master EQ")

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

            Button { project.toggleLoop() } label: {
                Image(systemName: "repeat")
                    .foregroundStyle(project.loopActive ? .green : .secondary)
            }
            .help("Loop playback over a region (drag on the ruler to set it)")

            Button { project.snapEnabled.toggle() } label: {
                Image(systemName: "ruler")
                    .foregroundStyle(project.snapEnabled ? .green : .secondary)
            }
            .help("Snap clips to the beat grid")

            Menu(snapLabel) {
                Button("Bar") { project.snapDivision = Double(project.beatsPerBar) }
                Button("Beat") { project.snapDivision = 1 }
                Button("1/2 beat") { project.snapDivision = 0.5 }
                Button("1/4 beat") { project.snapDivision = 0.25 }
                Button("1/8 beat") { project.snapDivision = 0.125 }
            }
            .frame(width: 64)
            .help("Snap resolution")

            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $project.pixelsPerSecond, in: 24...200).frame(width: 130)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }

            Button { project.activeSheet = .generate } label: {
                Label("Generate", systemImage: "sparkles")
            }

            Button { project.addEmptyTrack() } label: {
                Label("Track", systemImage: "rectangle.stack.badge.plus")
            }
            .help("Add an empty track")

            Menu {
                Button("Audio file…") { project.requestImport() }
                Button("From YouTube…") { project.activeSheet = .youtube }
            } label: {
                Label("Import", systemImage: "plus")
            }
            .frame(width: 76)

            Menu {
                Button("Mix → WAV…") { project.exportMixdown() }
                Button("Mix → AAC (.m4a)…") { project.exportMixdown(aac: true) }
                Divider()
                Button("Loop region → WAV…") { project.exportLoop() }
                    .disabled(!project.loopActive)
                Button("Each track (stems)…") { project.exportStems() }
            } label: {
                if project.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
            }
            .frame(width: 76)
            .disabled(project.tracks.isEmpty || project.isExporting)
            .help("Bounce the mix (or the loop region) to WAV")
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
