import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Top-level editor: transport bar over the timeline (or an empty state).
struct EditorView: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer
    @AppStorage("loopBrowserWidth") private var loopBrowserWidth = 290.0

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    TimelineView()
                    if project.tracks.isEmpty {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if project.showLoopBrowser {
                    PanelResizeHandle(width: $loopBrowserWidth, minWidth: 220, maxWidth: 560)
                    LoopBrowserPanel().frame(width: loopBrowserWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fileImporter(isPresented: $project.showImporter,
                      allowedContentTypes: [.audio],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { project.importAudio(urls: urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            project.importAudio(urls: urls)
            return true
        }
        .sheet(item: $project.activeSheet) { sheet in
            switch sheet {
            case .generate:
                GeneratePanel()
                    .environmentObject(project)
                    .environmentObject(preview)
                    .environmentObject(project.taste)
            case .youtube:
                YouTubeSheet().environmentObject(project)
            case .mixer:
                MixerView().environmentObject(project)
            case .pianoRoll(let id):
                PianoRollView(trackID: id).environmentObject(project)
            case .automation(let id):
                AutomationView(trackID: id).environmentObject(project)
            case .plugins(let id):
                PluginsView(trackID: id).environmentObject(project)
            case .loops:
                LoopLibraryView()
                    .environmentObject(project)
                    .environmentObject(project.loops)
                    .environmentObject(preview)
            case .stepSequencer(let id):
                StepSequencerView(trackID: id).environmentObject(project)
            case .analysis(let result):
                AnalysisSheet(analysis: result)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { project.lastError != nil },
                                    set: { if !$0 { project.lastError = nil } })) {
            Button("OK", role: .cancel) { project.lastError = nil }
        } message: {
            Text(project.lastError ?? "")
        }
        .alert("Opened Suno in your browser",
               isPresented: Binding(get: { project.infoMessage != nil },
                                    set: { if !$0 { project.infoMessage = nil } })) {
            Button("Got it", role: .cancel) { project.infoMessage = nil }
        } message: {
            Text(project.infoMessage ?? "")
        }
        .onAppear { project.restoreSessionIfAvailable() }
    }
}

/// Paste a YouTube URL → pull the audio into a new track (via yt-dlp).
struct YouTubeSheet: View {
    @EnvironmentObject var project: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Import from YouTube", systemImage: "arrow.down.circle").font(.headline)
            Text("Pulls the audio into a new track. For personal / reference use — respect copyright.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("https://www.youtube.com/watch?v=…", text: $url)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Download") {
                    project.importFromYouTube(url)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
            }

            Text("Requires yt-dlp:  brew install yt-dlp")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 470)
    }
}

/// A draggable divider that resizes a right-docked panel (drag left = wider).
struct PanelResizeHandle: View {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double
    @State private var base: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: 8)
            .overlay(Divider())
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = base ?? width
                        if base == nil { base = width }
                        width = min(maxWidth, max(minWidth, start - Double(value.translation.width)))
                    }
                    .onEnded { _ in base = nil }
            )
    }
}

/// A floating "start your song" card shown over the (empty) timeline.
struct EmptyStateView: View {
    @EnvironmentObject var project: ProjectStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text("Start your song").font(.title3.weight(.semibold))
            Text("Drag an audio file anywhere, or:")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { project.requestImport() } label: {
                    Label("Import Audio", systemImage: "square.and.arrow.down")
                }
                Button { project.addEmptyTrack() } label: {
                    Label("Audio Track", systemImage: "waveform")
                }
                Button { project.addInstrumentTrack() } label: {
                    Label("Instrument", systemImage: "pianokeys")
                }
            }
            .controlSize(.large)
            if project.isImporting { ProgressView().controlSize(.small) }
        }
        .padding(28)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
    }
}
