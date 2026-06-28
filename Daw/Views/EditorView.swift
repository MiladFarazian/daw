import SwiftUI
import UniformTypeIdentifiers

/// Top-level editor: transport bar over the timeline (or an empty state).
struct EditorView: View {
    @EnvironmentObject var project: ProjectStore

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
        .sheet(item: $project.presentedAnalysis) { analysis in
            AnalysisSheet(analysis: analysis)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { project.lastError != nil },
                                    set: { if !$0 { project.lastError = nil } })) {
            Button("OK", role: .cancel) { project.lastError = nil }
        } message: {
            Text(project.lastError ?? "")
        }
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
