import SwiftUI

/// Pinned track headers on the left; a horizontally-scrolling lane area with a
/// time ruler and a moving playhead on the right.
struct TimelineView: View {
    @EnvironmentObject var project: ProjectStore

    private let headerWidth: CGFloat = 188
    private let rulerHeight: CGFloat = 26
    private let trackHeight: CGFloat = 96
    private let groupRowHeight: CGFloat = 30

    private func rowHeight(_ row: TimelineRow) -> CGFloat {
        if case .group = row { return groupRowHeight } else { return trackHeight }
    }

    var body: some View {
        let pps = project.pixelsPerSecond
        let contentWidth = max(1, CGFloat(project.totalDuration) * pps)
        let rows = project.timelineRows
        // Explicit heights so the nested scroll layout stays unambiguous.
        let lanesHeight = rulerHeight + 1 + rows.reduce(0) { $0 + rowHeight($1) + 1 }

        ScrollView(.vertical, showsIndicators: true) {
            HStack(spacing: 0) {
                // Header column (scrolls vertically with the lanes; pinned horizontally)
                VStack(spacing: 0) {
                    Color.clear.frame(height: rulerHeight)
                    Divider()
                    ForEach(rows) { row in
                        headerRow(row)
                        Divider()
                    }
                    Menu {
                        Button { project.addEmptyTrack() } label: { Label("Audio Track", systemImage: "waveform") }
                        Button { project.addInstrumentTrack() } label: { Label("Instrument Track", systemImage: "pianokeys") }
                        Button {
                            project.activeSheet = .drummer(project.addDrummerTrack())
                        } label: { Label("Drummer", systemImage: "music.quarternote.3") }
                        Button {
                            project.activeSheet = .bassPlayer(project.addBassPlayer())
                        } label: { Label("Bass Player", systemImage: "guitars.fill") }
                        Button {
                            project.activeSheet = .melodyMaker(project.addMelodyMaker())
                        } label: { Label("Melody Maker", systemImage: "music.note") }
                        Button {
                            project.activeSheet = .stepSequencer(project.addDrumTrack())
                        } label: { Label("Drum Machine", systemImage: "square.grid.3x3.fill") }
                    } label: {
                        Label("Add Track", systemImage: "plus")
                            .font(.system(size: 11))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                }
                .frame(width: headerWidth)
                .background(.bar)

                Divider()

                // Lane area (scrolls horizontally)
                ScrollView(.horizontal, showsIndicators: true) {
                    ZStack(alignment: .topLeading) {
                        BeatGridView(pps: pps, tempo: project.tempo, tempoPoints: project.tempoPoints, beatsPerBar: project.beatsPerBar)
                            .frame(width: contentWidth, height: lanesHeight)
                            .allowsHitTesting(false)

                        VStack(spacing: 0) {
                            TimeRulerView(pps: pps, tempo: project.tempo, tempoPoints: project.tempoPoints, beatsPerBar: project.beatsPerBar)
                                .frame(width: contentWidth, height: rulerHeight)
                                .contentShape(Rectangle())
                                .gesture(
                                    SpatialTapGesture().onEnded { value in
                                        project.seek(to: Double(value.location.x) / pps)
                                    }
                                )
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 6).onChanged { value in
                                        project.setLoop(Double(min(value.startLocation.x, value.location.x)) / pps,
                                                        Double(max(value.startLocation.x, value.location.x)) / pps)
                                    }
                                )
                            Divider()
                            ForEach(rows) { row in
                                laneRow(row, contentWidth: contentWidth, pps: pps)
                                Divider()
                            }
                        }

                        if project.loopActive {
                            Rectangle()
                                .fill(Color.yellow.opacity(project.loopEnabled ? 0.14 : 0.06))
                                .frame(width: CGFloat(project.loopEnd - project.loopStart) * pps, height: lanesHeight)
                                .offset(x: CGFloat(project.loopStart) * pps)
                                .allowsHitTesting(false)
                        }

                        ForEach(project.markers) { marker in
                            MarkerFlag(marker: marker)
                                .frame(height: lanesHeight)
                                .offset(x: CGFloat(marker.time) * pps)
                        }

                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 1.5, height: lanesHeight)
                            .offset(x: CGFloat(project.currentTime) * pps)
                            .allowsHitTesting(false)
                    }
                    .frame(width: contentWidth, height: lanesHeight, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func headerRow(_ row: TimelineRow) -> some View {
        switch row {
        case .group(let group):
            GroupHeaderView(group: group).frame(height: groupRowHeight)
        case .track(let track):
            TrackHeaderView(track: track).frame(height: trackHeight)
        }
    }

    @ViewBuilder
    private func laneRow(_ row: TimelineRow, contentWidth: CGFloat, pps: Double) -> some View {
        switch row {
        case .group(let group):
            Rectangle()
                .fill(Palette.color(group.colorIndex).opacity(0.12))
                .frame(width: contentWidth, height: groupRowHeight)
        case .track(let track):
            ClipLaneView(track: track, pps: pps)
                .frame(width: contentWidth, height: trackHeight)
        }
    }
}

/// A group header row in the track column: collapse, color, name, volume, M/S.
struct GroupHeaderView: View {
    @EnvironmentObject var project: ProjectStore
    let group: TrackGroup
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 7) {
            Button { project.toggleGroupCollapse(group) } label: {
                Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.borderless)

            RoundedRectangle(cornerRadius: 2).fill(Palette.color(group.colorIndex)).frame(width: 5, height: 18)

            if isEditing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .onSubmit { project.renameGroup(group, to: draft); isEditing = false }
            } else {
                Text(group.name)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .onTapGesture(count: 2) { draft = group.name; isEditing = true }
            }

            Slider(value: Binding(get: { Double(group.volume) },
                                  set: { project.setGroupVolume(group, Float($0)) }), in: 0...1)
                .controlSize(.mini).frame(width: 50).help("Group volume")

            Toggle("M", isOn: Binding(get: { group.muted }, set: { _ in project.toggleGroupMute(group) }))
                .toggleStyle(.button).controlSize(.mini).help("Mute group")
            Toggle("S", isOn: Binding(get: { group.soloed }, set: { _ in project.toggleGroupSolo(group) }))
                .toggleStyle(.button).controlSize(.mini).tint(.yellow).help("Solo group")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.color(group.colorIndex).opacity(0.20))
        .contextMenu {
            Button { draft = group.name; isEditing = true } label: { Label("Rename Group", systemImage: "pencil") }
            Button(role: .destructive) { project.ungroup(group) } label: {
                Label("Ungroup", systemImage: "rectangle.split.3x1")
            }
        }
    }
}

/// A timeline marker: a labeled flag over a thin vertical line.
struct MarkerFlag: View {
    @EnvironmentObject var project: ProjectStore
    let marker: Marker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(marker.name)
                .font(.system(size: 8, weight: .medium))
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.purple.opacity(0.85))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .onTapGesture { project.seek(to: marker.time) }
                .contextMenu {
                    Button(role: .destructive) { project.deleteMarker(marker) } label: {
                        Label("Delete Marker", systemImage: "trash")
                    }
                }
            Rectangle().fill(Color.purple.opacity(0.4)).frame(width: 1)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Bars|beats ruler (4/4): numbered bar lines with beat ticks.
struct TimeRulerView: View {
    let pps: Double
    let tempo: Double
    let tempoPoints: [TempoPoint]
    let beatsPerBar: Int

    var body: some View {
        Canvas { context, size in
            let bpb = max(1, beatsPerBar)
            let times = beatTimes(base: tempo, points: tempoPoints, until: Double(size.width) / max(1, pps))
            guard times.count > 1 else { return }
            let beatPx = (times[1] - times[0]) * pps
            let labelBars = beatPx * Double(bpb) >= 26

            for (i, t) in times.enumerated() {
                let x = t * pps
                if i % bpb == 0 {                      // bar line
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: 4)); line.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    if labelBars {
                        let label = Text("\(i / bpb + 1)").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                        context.draw(label, at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                    }
                } else if beatPx >= 8 {                // beat tick
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 14)); tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
                }
            }
        }
        .background(.bar)
    }
}

/// Faint bar/beat gridlines behind the lanes.
struct BeatGridView: View {
    let pps: Double
    let tempo: Double
    let tempoPoints: [TempoPoint]
    let beatsPerBar: Int

    var body: some View {
        Canvas { context, size in
            let bpb = max(1, beatsPerBar)
            let times = beatTimes(base: tempo, points: tempoPoints, until: Double(size.width) / max(1, pps))
            guard times.count > 1, (times[1] - times[0]) * pps > 4 else { return }
            for (i, t) in times.enumerated() {
                let x = t * pps
                let isBar = i % bpb == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(isBar ? 0.09 : 0.035)),
                               lineWidth: isBar ? 1 : 0.5)
            }
        }
    }
}
