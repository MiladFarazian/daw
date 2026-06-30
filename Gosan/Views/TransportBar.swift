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

    private let lcd = Color(red: 0.65, green: 0.95, blue: 0.85)

    var body: some View {
        // Horizontal scroll so controls never squish/wrap/truncate at small widths.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                group {  // Transport
                    iconButton("backward.end.fill", help: "Return to start") { project.seek(to: 0) }
                    Button { project.togglePlay() } label: {
                        Image(systemName: project.isPlaying ? "stop.fill" : "play.fill").frame(width: 16)
                    }
                    .keyboardShortcut(.space, modifiers: []).help(project.isPlaying ? "Stop" : "Play")
                    Button { project.toggleRecord() } label: {
                        Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .foregroundStyle(recorder.isRecording ? .red : .primary)
                    }
                    .help(recorder.isRecording ? "Stop recording" : "Record a take")
                    iconButton("headphones", active: recorder.isMonitoring, help: "Monitor input") {
                        project.toggleMonitoring()
                    }
                    iconButton("timer", active: project.countInEnabled, help: "1-bar count-in") {
                        project.countInEnabled.toggle()
                    }
                    if recorder.isRecording {
                        InputLevelMeter(level: recorder.inputLevel).frame(width: 42, height: 6)
                    }
                }

                // LCD time + tempo — fixedSize + lineLimit so it can never wrap/shrink.
                HStack(spacing: 8) {
                    Text(timecode(project.currentTime))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(lcd).lineLimit(1)
                    Text("\(Int(project.tempo)) BPM")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(lcd.opacity(0.8)).lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))

                divider
                group {  // Tempo
                    iconButton("metronome", active: project.metronomeEnabled, help: "Metronome") {
                        project.toggleMetronome()
                    }
                    TextField("", value: Binding(
                        get: { project.tempo },
                        set: { project.tempo = min(300, max(30, $0.rounded())) }
                    ), format: .number)
                    .textFieldStyle(.plain).multilineTextAlignment(.trailing).frame(width: 30)
                    Stepper("", value: Binding(
                        get: { project.tempo },
                        set: { project.tempo = min(300, max(30, $0)) }
                    ), in: 30...300, step: 1).labelsHidden()
                    Button("Tap") { project.tapTempo() }.help("Tap tempo")
                    Menu("\(project.beatsPerBar)/4") {
                        ForEach([2, 3, 4, 5, 6, 7], id: \.self) { n in Button("\(n)/4") { project.beatsPerBar = n } }
                    }
                    .fixedSize().help("Time signature")
                }

                divider
                group {  // Markers
                    iconButton("chevron.backward.2", help: "Previous marker") { project.jumpToPrevMarker() }
                    iconButton("flag", help: "Add marker at playhead") { project.addMarker() }
                    iconButton("chevron.forward.2", help: "Next marker") { project.jumpToNextMarker() }
                }

                divider
                group {  // Master
                    Image(systemName: "speaker.wave.2").font(.caption2).foregroundStyle(.secondary)
                    InputLevelMeter(level: project.masterLevel).frame(width: 48, height: 6)
                    Menu("EQ") {
                        Button("Flat") { project.setMasterEQ(low: 0, mid: 0, high: 0) }
                        Button("Bright") { project.setMasterEQ(low: 0, mid: 0, high: 4) }
                        Button("Warm") { project.setMasterEQ(low: 3, mid: 0, high: -3) }
                        Button("Loudness") { project.setMasterEQ(low: 4, mid: -1, high: 3) }
                    }
                    .fixedSize().help("Master EQ")
                }

                divider
                group {  // View
                    iconButton("repeat", active: project.loopActive, help: "Loop region") { project.toggleLoop() }
                    iconButton("ruler", active: project.snapEnabled, help: "Snap to grid") { project.snapEnabled.toggle() }
                    Menu(snapLabel) {
                        Button("Bar") { project.snapDivision = Double(project.beatsPerBar) }
                        Button("Beat") { project.snapDivision = 1 }
                        Button("1/2 beat") { project.snapDivision = 0.5 }
                        Button("1/4 beat") { project.snapDivision = 0.25 }
                        Button("1/8 beat") { project.snapDivision = 0.125 }
                    }
                    .fixedSize().help("Snap resolution")
                    iconButton("minus.magnifyingglass", help: "Zoom out") {
                        project.pixelsPerSecond = max(24, project.pixelsPerSecond - 20)
                    }
                    iconButton("plus.magnifyingglass", help: "Zoom in") {
                        project.pixelsPerSecond = min(200, project.pixelsPerSecond + 20)
                    }
                }

                divider
                group {  // Create / IO
                    iconButton("sparkles", help: "Generate (Suno)") { project.activeSheet = .generate }
                    Menu {
                        Button("Audio Track") { project.addEmptyTrack() }
                        Button("Instrument Track") { project.addInstrumentTrack() }
                    } label: { Image(systemName: "plus.rectangle.on.rectangle") }
                        .fixedSize().help("Add a track")
                    Menu {
                        Button("Audio file…") { project.requestImport() }
                        Button("From YouTube…") { project.activeSheet = .youtube }
                    } label: { Image(systemName: "square.and.arrow.down") }
                        .fixedSize().help("Import")
                    iconButton("slider.vertical.3", help: "Mixer") { project.activeSheet = .mixer }
                    Menu {
                        Button("Mix → WAV…") { project.exportMixdown() }
                        Button("Mix → WAV (normalized)…") { project.exportMixdown(normalize: true) }
                        Button("Mix → AAC (.m4a)…") { project.exportMixdown(aac: true) }
                        Divider()
                        Button("Loop region → WAV…") { project.exportLoop() }.disabled(!project.loopActive)
                        Button("Each track (stems)…") { project.exportStems() }
                    } label: {
                        if project.isExporting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "square.and.arrow.up") }
                    }
                    .fixedSize().disabled(project.tracks.isEmpty || project.isExporting).help("Export")
                }

                if !project.activeJobs.isEmpty {
                    divider
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(jobsSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func iconButton(_ symbol: String, active: Bool = false, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(active ? Color.green : Color.primary)
        }
        .help(help)
    }

    private var divider: some View { Divider().frame(height: 18) }

    @ViewBuilder
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
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
