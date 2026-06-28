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

        HStack(spacing: 0) {
            // Pinned header column
            VStack(spacing: 0) {
                Color.clear.frame(height: rulerHeight)
                Divider()
                ForEach(project.tracks) { track in
                    TrackHeaderView(track: track)
                        .frame(height: trackHeight)
                    Divider()
                }
                Spacer(minLength: 0)
            }
            .frame(width: headerWidth)
            .background(.bar)

            Divider()

            // Scrollable lane area
            ScrollView(.horizontal, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        TimeRulerView(pps: pps)
                            .frame(width: contentWidth, height: rulerHeight)
                            .contentShape(Rectangle())
                            .gesture(
                                SpatialTapGesture().onEnded { value in
                                    project.seek(to: Double(value.location.x) / pps)
                                }
                            )
                        Divider()
                        ForEach(project.tracks) { track in
                            ClipLaneView(track: track, pps: pps)
                                .frame(width: contentWidth, height: trackHeight)
                            Divider()
                        }
                        Spacer(minLength: 0)
                    }

                    Rectangle()
                        .fill(Color.red)
                        .frame(width: 1.5)
                        .offset(x: CGFloat(project.currentTime) * pps)
                        .allowsHitTesting(false)
                }
                .frame(width: contentWidth, alignment: .topLeading)
            }
        }
    }
}

/// Second/labelled ticks across the timeline.
struct TimeRulerView: View {
    let pps: Double

    var body: some View {
        Canvas { context, size in
            let seconds = Int(ceil(Double(size.width) / pps))
            let labelEvery = pps < 50 ? 5 : (pps < 100 ? 2 : 1)
            for second in 0...max(1, seconds) {
                let x = CGFloat(Double(second) * pps)
                let labeled = second % labelEvery == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: labeled ? 6 : 14))
                tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick,
                               with: .color(.secondary.opacity(labeled ? 0.6 : 0.3)),
                               lineWidth: 1)
                if labeled {
                    let label = Text(timecode(Double(second)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    context.draw(label, at: CGPoint(x: x + 3, y: 8), anchor: .leading)
                }
            }
        }
        .background(.bar)
    }
}
