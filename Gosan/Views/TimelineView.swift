import SwiftUI

/// Pinned track headers on the left; a horizontally-scrolling lane area with a
/// time ruler and a moving playhead on the right.
struct TimelineView: View {
    @EnvironmentObject var project: ProjectStore

    private let headerWidth: CGFloat = 188
    private let rulerHeight: CGFloat = 26
    private let trackHeight: CGFloat = 96

    var body: some View {
        let pps = project.pixelsPerSecond
        let contentWidth = max(1, CGFloat(project.totalDuration) * pps)
        // Explicit heights so the nested scroll layout stays unambiguous.
        let lanesHeight = rulerHeight + 1 + CGFloat(project.tracks.count) * (trackHeight + 1)

        ScrollView(.vertical, showsIndicators: true) {
            HStack(spacing: 0) {
                // Header column (scrolls vertically with the lanes; pinned horizontally)
                VStack(spacing: 0) {
                    Color.clear.frame(height: rulerHeight)
                    Divider()
                    ForEach(project.tracks) { track in
                        TrackHeaderView(track: track)
                            .frame(height: trackHeight)
                        Divider()
                    }
                    Menu {
                        Button { project.addEmptyTrack() } label: { Label("Audio Track", systemImage: "waveform") }
                        Button { project.addInstrumentTrack() } label: { Label("Instrument Track", systemImage: "pianokeys") }
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
                        BeatGridView(pps: pps, tempo: project.tempo, beatsPerBar: project.beatsPerBar)
                            .frame(width: contentWidth, height: lanesHeight)
                            .allowsHitTesting(false)

                        VStack(spacing: 0) {
                            TimeRulerView(pps: pps, tempo: project.tempo, beatsPerBar: project.beatsPerBar)
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
                            ForEach(project.tracks) { track in
                                ClipLaneView(track: track, pps: pps)
                                    .frame(width: contentWidth, height: trackHeight)
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
    let beatsPerBar: Int

    var body: some View {
        Canvas { context, size in
            let bpb = max(1, beatsPerBar)
            let beat = 60.0 / max(1, tempo)
            let barPx = beat * Double(bpb) * pps
            guard barPx > 1 else { return }
            let beatPx = beat * pps
            let labelBars = barPx >= 26

            var bar = 0
            var x = 0.0
            while x <= Double(size.width) {
                var line = Path()
                line.move(to: CGPoint(x: x, y: 4)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                if labelBars {
                    let label = Text("\(bar + 1)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
                if beatPx >= 8 {
                    for b in 1..<bpb {
                        let bx = x + Double(b) * beatPx
                        guard bx <= Double(size.width) else { break }
                        var tick = Path()
                        tick.move(to: CGPoint(x: bx, y: 14)); tick.addLine(to: CGPoint(x: bx, y: size.height))
                        context.stroke(tick, with: .color(.secondary.opacity(0.3)), lineWidth: 0.75)
                    }
                }
                bar += 1
                x = Double(bar) * barPx
            }
        }
        .background(.bar)
    }
}

/// Faint bar/beat gridlines behind the lanes.
struct BeatGridView: View {
    let pps: Double
    let tempo: Double
    let beatsPerBar: Int

    var body: some View {
        Canvas { context, size in
            let bpb = max(1, beatsPerBar)
            let beat = 60.0 / max(1, tempo)
            let beatPx = beat * pps
            guard beatPx > 4 else { return }
            var i = 0
            var x = 0.0
            while x <= Double(size.width) {
                let isBar = i % bpb == 0
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.white.opacity(isBar ? 0.09 : 0.035)),
                               lineWidth: isBar ? 1 : 0.5)
                i += 1
                x = Double(i) * beatPx
            }
        }
    }
}
