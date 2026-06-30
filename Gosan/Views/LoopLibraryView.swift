import SwiftUI
import UniformTypeIdentifiers

/// Browse the loop library: preview, add to the timeline, drag onto a track,
/// import audio, or delete. Fill it from clips ("Save as Loop"), recordings,
/// imports, or Suno generations.
struct LoopLibraryView: View {
    @EnvironmentObject var loops: LoopLibrary
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @Environment(\.dismiss) private var dismiss

    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("Loop Library", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button { importing = true } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if loops.loops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("No loops yet").font(.headline)
                    Text("Right-click a clip → Save as Loop, import audio, or save a Suno generation here.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List {
                    ForEach(loops.loops) { loop in
                        LoopRow(loop: loop)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loops.importFiles(urls) }
        }
    }
}

/// A dockable loop browser pinned beside the timeline — drag loops straight onto tracks.
struct LoopBrowserPanel: View {
    @EnvironmentObject var loops: LoopLibrary
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Label("Loops", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("Import audio into the library")
                Button { project.showLoopBrowser = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help("Close")
            }
            .padding(10)
            Divider()

            if loops.loops.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.slash")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Text("No loops yet").font(.subheadline)
                    Text("Right-click a clip → Save as Loop, import audio, or save a Suno generation. Then drag loops onto a track.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List {
                    ForEach(loops.loops) { LoopRow(loop: $0) }
                }
            }

            Divider()
            Text("Drag a loop onto a track, or press Add to drop it at the playhead.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loops.importFiles(urls) }
        }
    }
}

private struct LoopRow: View {
    @EnvironmentObject var loops: LoopLibrary
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    let loop: LoopEntry

    private var subtitle: String {
        var parts: [String] = []
        if let bpm = loop.bpm { parts.append("\(bpm) BPM") }
        parts.append(String(format: "%.1fs", loop.duration))
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let url = loops.url(for: loop) { preview.toggle(id: loop.id.uuidString, url: url) }
            } label: {
                Image(systemName: preview.playingID == loop.id.uuidString ? "stop.circle.fill" : "play.circle")
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                Text(loop.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            Button("Add") { project.addLoopToProject(loop) }
                .help("Add to the timeline at the playhead")
            Button(role: .destructive) { loops.remove(loop) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // Drag the underlying file onto a track lane (lanes accept URL drops).
        .draggable(loops.url(for: loop) ?? URL(fileURLWithPath: "/dev/null"))
    }
}
