import SwiftUI
import AppKit

/// Headless UI snapshots. Launch the app with env `GOSAN_SNAPSHOT=<dir>` and it renders
/// key screens to PNGs via ImageRenderer (no window / Space / screen-recording needed),
/// then exits. A dev tool so the UI can be inspected and iterated without a human.
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let dir = ProcessInfo.processInfo.environment["GOSAN_SNAPSHOT"], !dir.isEmpty else { return }
        MainActor.assumeIsolated {
            SnapshotRenderer.run(to: URL(fileURLWithPath: dir))
        }
        exit(0)
    }
}

@MainActor
enum SnapshotRenderer {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let settings = AppSettings()
        let taste = TasteEngine()
        let recorder = Recorder()
        let loops = LoopLibrary()
        let preview = PreviewPlayer()
        let project = ProjectStore(settings: settings, taste: taste, recorder: recorder, loops: loops)
        populate(project)

        func snap(_ name: String, _ w: CGFloat, _ h: CGFloat, _ view: AnyView) {
            let content = view
                .frame(width: w, height: h)
                .environmentObject(project)
                .environmentObject(settings)
                .environmentObject(preview)
                .environmentObject(taste)
                .environmentObject(recorder)
                .environmentObject(loops)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            FileHandle.standardError.write("rendered \(name).png\n".data(using: .utf8)!)
        }

        snap("editor", 1320, 780, AnyView(EditorView()))
        snap("mixer", 760, 540, AnyView(MixerView()))
        if let drum = project.tracks.first(where: { $0.isDrumKit }) {
            snap("stepseq", 800, 480, AnyView(StepSequencerView(trackID: drum.id)))
        }
        if let inst = project.tracks.first(where: { $0.isInstrument && !$0.isDrumKit }) {
            snap("pianoroll", 860, 540, AnyView(PianoRollView(trackID: inst.id)))
        }
    }

    /// A realistic demo project so snapshots aren't empty.
    static func populate(_ project: ProjectStore) {
        let peaks: [Float] = (0..<256).map { Float(abs(sin(Double($0) * 0.15)) * 0.85) }
        func asset(_ name: String) -> AudioAsset {
            AudioAsset(url: URL(fileURLWithPath: "/tmp/\(name).wav"), duration: 7, sampleRate: 44_100, peaks: peaks)
        }

        var vox = Track(name: "Lead Vocal", colorIndex: 0)
        vox.clips = [Clip(asset: asset("vox"), startTime: 0.5)]

        var gtr = Track(name: "Guitar", colorIndex: 2)
        gtr.volume = 0.7
        gtr.clips = [Clip(asset: asset("gtr"), startTime: 0)]

        var keys = Track(name: "Keys", colorIndex: 4)
        keys.isInstrument = true
        keys.notes = chordProgression(root: 0, scale: .major, degrees: [0, 4, 5, 3], barDuration: 2, octave: 4)

        var drums = Track(name: "Drums", colorIndex: 6)
        drums.isInstrument = true
        drums.isDrumKit = true
        drums.notes = DrumPatterns.notes(DrumPatterns.all[0], bars: 2, stepDur: 0.125)

        project.tracks = [vox, gtr, keys, drums]
        project.tempo = 120
        project.markers = [Marker(time: 2, name: "Verse"), Marker(time: 6, name: "Chorus")]
    }
}
