import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Music.ai") {
                SecureField("API key", text: $settings.apiKey)
                Text("Create a key in the Music.ai developer dashboard. Stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Workflow slugs") {
                TextField("Stems workflow", text: $settings.stemsWorkflow)
                TextField("Analyze workflow", text: $settings.analyzeWorkflow)
                Text("Copy the exact slugs from your Music.ai Workflows page. The defaults are starting points and may need changing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Suno (session-wrapper)") {
                TextField("Sidecar URL", text: $settings.sunoSidecarURLString)
                Text("Run a local Suno API wrapper (e.g. gcui-art/suno-api) on your own account and point this at it. If it's not running, use “Open in Suno (manual)” instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 340)
    }
}

/// Shows whatever fields an analysis workflow returned.
struct AnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let analysis: AnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(analysis.title, systemImage: "waveform")
                .font(.headline)

            if analysis.fields.isEmpty {
                Text("The workflow returned no fields. Check the analyze slug in Settings.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(analysis.fields) { field in
                            HStack(alignment: .top, spacing: 12) {
                                Text(field.key)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 130, alignment: .leading)
                                Text(field.value)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
