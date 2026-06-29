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
                        Button { project.splitClipAtPlayhead(clip, on: track) } label: {
                            Label("Split at Playhead", systemImage: "scissors")
                        }
                        .disabled(!project.canSplit(clip))
                        Button { project.duplicateClip(clip, on: track) } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }
                        Button { project.toggleClipMute(clip, on: track) } label: {
                            Label(clip.muted ? "Unmute Clip" : "Mute Clip",
                                  systemImage: clip.muted ? "speaker" : "speaker.slash")
                        }
                        Button { project.copyClip(clip) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button { project.cutClip(clip, on: track) } label: {
                            Label("Cut", systemImage: "scissors.badge.ellipsis")
                        }
                        Button { project.pasteClip(onto: track) } label: {
                            Label("Paste at Playhead", systemImage: "doc.on.clipboard")
                        }
                        .disabled(project.clipboard == nil)
                        Menu {
                            ForEach([6.0, 3.0, 0.0, -3.0, -6.0, -12.0], id: \.self) { db in
                                Button(db == 0 ? "0 dB (reset)" : String(format: "%+.0f dB", db)) {
                                    project.setClipGain(clip, on: track, db: db)
                                }
                            }
                        } label: {
                            Label("Gain", systemImage: "speaker.wave.2")
                        }
                        Button { project.normalizeClip(clip, on: track) } label: {
                            Label("Normalize", systemImage: "arrow.up.to.line")
                        }
                        Menu {
                            Button("Linear") { project.setFadeCurve(clip, on: track, equalPower: false) }
                            Button("Equal-power") { project.setFadeCurve(clip, on: track, equalPower: true) }
                        } label: {
                            Label("Fade Curve", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        Button { project.crossfadeWithNext(clip, on: track) } label: {
                            Label("Crossfade with Next", systemImage: "arrow.left.arrow.right")
                        }
                        Button { project.trimSilence(clip, on: track) } label: {
                            Label("Trim Silence", systemImage: "scissors")
                        }
                        Button { project.quantizeClip(clip, on: track) } label: {
                            Label("Quantize to Grid", systemImage: "grid")
                        }
                        Button { project.reverseClip(clip, on: track) } label: {
                            Label("Reverse", systemImage: "arrow.uturn.backward")
                        }
                        Menu {
                            Button("0.5× (slower, 2× longer)") { project.timeStretchClip(clip, on: track, rate: 0.5) }
                            Button("0.75× speed") { project.timeStretchClip(clip, on: track, rate: 0.75) }
                            Button("1.5× speed") { project.timeStretchClip(clip, on: track, rate: 1.5) }
                            Button("2× (faster, ½ length)") { project.timeStretchClip(clip, on: track, rate: 2.0) }
                        } label: {
                            Label("Time-stretch", systemImage: "timeline.selection")
                        }
                        Divider()
                        Button { project.vocalRescue(clip) } label: {
                            Label("Vocal Rescue (enhance → master)", systemImage: "wand.and.stars")
                        }
                        Divider()
                        Button { project.splitStems(of: clip) } label: {
                            Label("Split into Stems", systemImage: "square.stack")
                        }
                        Button { project.analyze(clip) } label: {
                            Label("Analyze (key · BPM · chords)", systemImage: "magnifyingglass")
                        }
                        Button { project.enhanceVocal(clip) } label: {
                            Label("Enhance (de-reverb · denoise)", systemImage: "sparkles")
                        }
                        Button { project.master(clip) } label: {
                            Label("Master", systemImage: "dial.high")
                        }
                        Button { project.sendClipToMoises(clip) } label: {
                            Label("Send to Moises (manual)…", systemImage: "arrow.up.forward.app")
                        }
                        Divider()
                        Button(role: .destructive) { project.deleteClip(clip, on: track) } label: {
                            Label("Delete Clip", systemImage: "trash")
                        }
                        Button(role: .destructive) { project.deleteTrack(track) } label: {
                            Label("Delete Track", systemImage: "trash.slash")
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, location in
            project.importAudio(urls: urls, onto: track, at: Double(location.x) / pps)
            return true
        }
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
    @State private var fadeInDelta: CGFloat = 0
    @State private var fadeOutDelta: CGFloat = 0

    private let handleWidth: CGFloat = 9

    private var isSelected: Bool { project.selectedClipID == clip.id }
    private var baseWidth: CGFloat { max(2, CGFloat(clip.duration) * pps) }
    private var visualX: CGFloat { CGFloat(clip.startTime) * pps + dragX + trimLeadingX }
    private var visualWidth: CGFloat { max(handleWidth * 2, baseWidth - trimLeadingX + trimTrailingX) }
    private var fadeInWidth: CGFloat { max(0, CGFloat(clip.fadeIn) * pps + fadeInDelta) }
    private var fadeOutWidth: CGFloat { max(0, CGFloat(clip.fadeOut) * pps - fadeOutDelta) }

    private var startFraction: Double {
        clip.asset.duration > 0 ? clip.offset / clip.asset.duration : 0
    }
    private var endFraction: Double {
        clip.asset.duration > 0 ? (clip.offset + clip.duration) / clip.asset.duration : 1
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(color.opacity(isSelected ? 0.34 : 0.22))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(isSelected ? 1 : 0.7), lineWidth: isSelected ? 2 : 1)

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

            // Fade triangles
            Canvas { ctx, size in
                if fadeInWidth > 0.5 {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: min(fadeInWidth, size.width), y: 0))
                    p.addLine(to: CGPoint(x: 0, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(.black.opacity(0.3)))
                }
                if fadeOutWidth > 0.5 {
                    var p = Path()
                    p.move(to: CGPoint(x: size.width, y: 0))
                    p.addLine(to: CGPoint(x: max(0, size.width - fadeOutWidth), y: 0))
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(.black.opacity(0.3)))
                }
            }
            .allowsHitTesting(false)

            if isSelected {
                fadeHandle(x: fadeInWidth, gesture: fadeInDrag)
                fadeHandle(x: visualWidth - fadeOutWidth, gesture: fadeOutDrag)
            }
        }
        .opacity(clip.muted ? 0.4 : 1)
        .frame(width: visualWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(moveGesture)
        .overlay(alignment: .leading) { handle(gesture: leadingTrim) }
        .overlay(alignment: .trailing) { handle(gesture: trailingTrim) }
        .padding(.vertical, 6)
        .offset(x: visualX)
    }

    private func fadeHandle<G: Gesture>(x: CGFloat, gesture: G) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(color, lineWidth: 1))
            .frame(width: 9, height: 9)
            .offset(x: x - 4.5, y: 2)
            .gesture(gesture)
    }

    private var fadeInDrag: some Gesture {
        DragGesture()
            .onChanged { fadeInDelta = $0.translation.width }
            .onEnded { _ in project.setFadeIn(clip, on: track, byPixels: fadeInDelta); fadeInDelta = 0 }
    }

    private var fadeOutDrag: some Gesture {
        DragGesture()
            .onChanged { fadeOutDelta = $0.translation.width }
            .onEnded { _ in project.setFadeOut(clip, on: track, byPixels: fadeOutDelta); fadeOutDelta = 0 }
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { dragX = $0.translation.width }
            .onEnded { value in
                if abs(value.translation.width) < 3 {
                    project.selectClip(clip.id)   // a click, not a drag
                } else {
                    project.moveClip(clip, on: track, byPixels: dragX)
                }
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
