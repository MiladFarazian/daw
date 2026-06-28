import SwiftUI

/// One track's lane, with its clips positioned by start time.
struct ClipLaneView: View {
    let track: Track
    let pps: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5))

            ForEach(track.clips) { clip in
                ClipView(clip: clip, color: Palette.color(track.colorIndex))
                    .frame(width: max(2, CGFloat(clip.duration) * pps))
                    .padding(.vertical, 6)
                    .offset(x: CGFloat(clip.startTime) * pps)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ClipView: View {
    let clip: Clip
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.22))
            RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.7), lineWidth: 1)

            WaveformView(peaks: clip.asset.peaks, color: color)
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
    }
}

/// Draws a symmetric waveform from a normalized peak envelope.
struct WaveformView: View {
    let peaks: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard peaks.count > 1 else { return }
            let midY = size.height / 2
            let step = size.width / CGFloat(peaks.count)
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let x = CGFloat(index) * step
                let amplitude = CGFloat(peak) * midY
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
            }
            context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: max(0.6, step * 0.7))
        }
    }
}
