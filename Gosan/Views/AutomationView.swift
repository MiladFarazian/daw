import SwiftUI

/// Draw volume + pan automation envelopes for a track. Click empty space to add a
/// breakpoint; click a point to delete it. Linear between points; flat outside.
struct AutomationView: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID

    private let pps: CGFloat = 80
    private var track: Track? { project.tracks.first { $0.id == trackID } }
    private var duration: TimeInterval { max(8, (track?.endTime ?? 4) + 2) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Automation — \(track?.name ?? "")", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 16) {
                    if let track {
                        lane("Volume", lane: \.volumeAutomation, range: 0...1, defaultValue: track.volume,
                             points: track.volumeAutomation, track: track)
                        lane("Pan (L … R)", lane: \.panAutomation, range: -1...1, defaultValue: track.pan,
                             points: track.panAutomation, track: track)
                        lane("Reverb", lane: \.reverbAutomation, range: 0...1, defaultValue: track.reverb,
                             points: track.reverbAutomation, track: track)
                        lane("Delay", lane: \.delayAutomation, range: 0...1, defaultValue: track.delay,
                             points: track.delayAutomation, track: track)
                        lane("EQ Low (dB)", lane: \.eqLowAutomation, range: -12...12, defaultValue: track.eqLow,
                             points: track.eqLowAutomation, track: track)
                        lane("EQ Mid (dB)", lane: \.eqMidAutomation, range: -12...12, defaultValue: track.eqMid,
                             points: track.eqMidAutomation, track: track)
                        lane("EQ High (dB)", lane: \.eqHighAutomation, range: -12...12, defaultValue: track.eqHigh,
                             points: track.eqHighAutomation, track: track)
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private func lane(_ title: String, lane: WritableKeyPath<Track, [AutomationPoint]>,
                      range: ClosedRange<Float>, defaultValue: Float,
                      points: [AutomationPoint], track: Track) -> some View {
        let width = CGFloat(duration) * pps
        let height: CGFloat = 120
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { project.clearAutomation(track, lane) }
                    .controlSize(.small).disabled(points.isEmpty)
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.05))
                // baseline (current static value)
                let baseY = yFor(defaultValue, range: range, height: height)
                Path { p in p.move(to: CGPoint(x: 0, y: baseY)); p.addLine(to: CGPoint(x: width, y: baseY)) }
                    .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // envelope line
                if points.count >= 2 {
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let point = CGPoint(x: CGFloat(pt.time) * pps, y: yFor(pt.value, range: range, height: height))
                            i == 0 ? p.move(to: point) : p.addLine(to: point)
                        }
                    }
                    .stroke(Color.accentColor, lineWidth: 1.5)
                }

                // breakpoints (drag to move; right-click to delete)
                ForEach(points) { pt in
                    AutomationDot(point: pt, lane: lane, track: track, range: range, height: height, pps: pps)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let time = max(0, Double(value.location.x / pps))
                let v = valueFor(value.location.y, range: range, height: height)
                project.addAutomationPoint(track, lane, time: time, value: v)
            })
            Text("Click empty space to add a point · drag a point to move · right-click to delete")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func yFor(_ value: Float, range: ClosedRange<Float>, height: CGFloat) -> CGFloat {
        let t = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height - CGFloat(t) * height
    }
    private func valueFor(_ y: CGFloat, range: ClosedRange<Float>, height: CGFloat) -> Float {
        let t = Float(1 - max(0, min(height, y)) / height)
        return range.lowerBound + t * (range.upperBound - range.lowerBound)
    }
}

/// A draggable automation breakpoint (commits to the model on drag end).
private struct AutomationDot: View {
    @EnvironmentObject var project: ProjectStore
    let point: AutomationPoint
    let lane: WritableKeyPath<Track, [AutomationPoint]>
    let track: Track
    let range: ClosedRange<Float>
    let height: CGFloat
    let pps: CGFloat
    @State private var drag: CGSize = .zero

    private var baseX: CGFloat { CGFloat(point.time) * pps }
    private var baseY: CGFloat {
        let t = (point.value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height - CGFloat(t) * height
    }

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1))
            .frame(width: 11, height: 11)
            .position(x: baseX + drag.width, y: baseY + drag.height)
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        let newTime = max(0, Double((baseX + value.translation.width) / pps))
                        let yy = baseY + value.translation.height
                        let t = Float(1 - max(0, min(height, yy)) / height)
                        let newValue = range.lowerBound + t * (range.upperBound - range.lowerBound)
                        project.moveAutomationPoint(point, track, lane, time: newTime, value: newValue)
                        drag = .zero
                    }
            )
            .contextMenu {
                Button(role: .destructive) { project.removeAutomationPoint(point, track, lane) } label: {
                    Label("Delete Point", systemImage: "trash")
                }
            }
    }
}
