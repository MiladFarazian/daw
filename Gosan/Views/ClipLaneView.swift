import SwiftUI
import AppKit

/// One track's lane, with its clips positioned by start time.
struct ClipLaneView: View {
    @EnvironmentObject var project: ProjectStore
    let track: Track
    let pps: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5))

            ForEach(track.clips) { clip in
                ClipView(clip: clip, track: track, pps: pps, color: Palette.color(track.colorIndex))
                    .contextMenu {
                        Button { project.splitStems(of: clip) } label: {
                            Label("Split into Stems", systemImage: "square.stack")
                        }
                        Button { project.analyze(clip) } label: {
                            Label("Analyze (key · BPM · chords)", systemImage: "magnifyingglass")
                        }
                        Divider()
                        Button(role: .destructive) { project.deleteTrack(track) } label: {
                            Label("Delete Track", systemImage: "trash")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A clip block: drag the body to move it, drag either edge to trim.
struct ClipView: View {
    @EnvironmentObject var project: ProjectStore
    let clip: Clip
    let track: Track
    let pps: Double
    let color: Color

    @State private var dragX: CGFloat = 0
    @State private var trimLeadingX: CGFloat = 0
    @State private var trimTrailingX: CGFloat = 0

    private let handleWidth: CGFloat = 9

    private var baseWidth: CGFloat { max(2, CGFloat(clip.duration) * pps) }
    private var visualX: CGFloat { CGFloat(clip.startTime) * pps + dragX + trimLeadingX }
    private var visualWidth: CGFloat { max(handleWidth * 2, baseWidth - trimLeadingX + trimTrailingX) }

    private var startFraction: Double {
        clip.asset.duration > 0 ? clip.offset / clip.asset.duration : 0
    }
    private var endFraction: Double {
        clip.asset.duration > 0 ? (clip.offset + clip.duration) / clip.asset.duration : 1
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.22))
            RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.7), lineWidth: 1)

            WaveformView(peaks: clip.asset.peaks, color: color,
                         startFraction: startFraction, endFraction: endFraction)
                .padding(.horizontal, 4)
                .padding(.top, 16)
                .padding(.bottom, 6)

            Text(clip.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.top, 3)
        }
        .frame(width: visualWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .overlay(alignment: .leading) { handle(gesture: leadingTrim) }
        .overlay(alignment: .trailing) { handle(gesture: trailingTrim) }
        .padding(.vertical, 6)
        .offset(x: visualX)
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { dragX = $0.translation.width }
            .onEnded { _ in
                project.moveClip(clip, on: track, byPixels: dragX)
                dragX = 0
            }
    }

    private func handle<G: Gesture>(gesture: G) -> some View {
        Rectangle()
            .fill(color.opacity(0.001)) // invisible but hit-testable
            .frame(width: handleWidth)
            .overlay(
                Capsule().fill(color.opacity(0.8)).frame(width: 2, height: 14)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(gesture)
    }

    private var leadingTrim: some Gesture {
        DragGesture()
            .onChanged { value in
                let maxIn = CGFloat(clip.duration - 0.1) * CGFloat(pps)
                let maxOut = CGFloat(clip.offset) * CGFloat(pps)
                trimLeadingX = min(max(value.translation.width, -maxOut), maxIn)
            }
            .onEnded { _ in
                project.trimClipStart(clip, on: track, byPixels: trimLeadingX)
                trimLeadingX = 0
            }
    }

    private var trailingTrim: some Gesture {
        DragGesture()
            .onChanged { value in
                let maxExtend = CGFloat(clip.asset.duration - clip.offset - clip.duration) * CGFloat(pps)
                let maxShrink = CGFloat(clip.duration - 0.1) * CGFloat(pps)
                trimTrailingX = min(max(value.translation.width, -maxShrink), maxExtend)
            }
            .onEnded { _ in
                project.trimClipEnd(clip, on: track, byPixels: trimTrailingX)
                trimTrailingX = 0
            }
    }
}

/// Draws a symmetric waveform from a normalized peak envelope (optionally a sub-range).
struct WaveformView: View {
    let peaks: [Float]
    let color: Color
    var startFraction: Double = 0
    var endFraction: Double = 1

    var body: some View {
        Canvas { context, size in
            guard peaks.count > 1 else { return }
            let start = max(0, min(peaks.count - 1, Int(Double(peaks.count) * startFraction)))
            let end = max(start + 1, min(peaks.count, Int(Double(peaks.count) * endFraction)))
            let slice = peaks[start..<end]
            guard !slice.isEmpty else { return }

            let midY = size.height / 2
            let step = size.width / CGFloat(slice.count)
            var path = Path()
            for (index, peak) in slice.enumerated() {
                let x = CGFloat(index) * step
                let amplitude = CGFloat(peak) * midY
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            }
            context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: max(0.6, step * 0.7))
        }
    }
}
