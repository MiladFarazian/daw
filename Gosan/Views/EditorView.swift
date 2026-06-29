import SwiftUI
import UniformTypeIdentifiers

/// Top-level editor: transport bar over the timeline (or an empty state).
struct EditorView: View {
    @EnvironmentObject var project: ProjectStore
    @EnvironmentObject var preview: PreviewPlayer

    var body: some View {
        VStack(spacing: 0) {
            TransportBar()
            Divider()
            Group {
                if project.tracks.isEmpty {
                    EmptyStateView()
                } else {
                    TimelineView()
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

struct EmptyStateView: View {
    @EnvironmentObject var project: ProjectStore

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an audio file to start")
                .font(.title3)
            Button {
                project.requestImport()
            } label: {
                Label("Import Audio…", systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            if project.isImporting {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
