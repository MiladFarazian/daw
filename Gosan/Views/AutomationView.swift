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

                // breakpoints
                ForEach(points) { pt in
                    Circle().fill(Color.accentColor)
                        .frame(width: 9, height: 9)
                        .position(x: CGFloat(pt.time) * pps, y: yFor(pt.value, range: range, height: height))
                        .onTapGesture { project.removeAutomationPoint(pt, track, lane) }
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let time = max(0, Double(value.location.x / pps))
                let v = valueFor(value.location.y, range: range, height: height)
                project.addAutomationPoint(track, lane, time: time, value: v)
            })
            Text("Click to add a point · click a point to delete")
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
