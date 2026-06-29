import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var taste: TasteEngine

    var body: some View {
        Form {
            Section("Moises (developer API)") {
                SecureField("API key", text: $settings.apiKey)
                Text("Moises' developer API (music.ai) — get a free key at developer.moises.ai. "
                    + "This is separate from your Moises app subscription. Stored in your macOS Keychain. "
                    + "No key? Right-click a clip → “Send to Moises” to use the app you already have.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Moises workflows") {
                Button("Load my workflows from Moises") { settings.loadWorkflows() }
                    .disabled(!settings.hasAPIKey)
                if let status = settings.workflowStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                if settings.availableWorkflows.isEmpty {
                    TextField("Stems workflow", text: $settings.stemsWorkflow)
                    TextField("Analyze workflow", text: $settings.analyzeWorkflow)
                    TextField("Enhance workflow", text: $settings.enhanceWorkflow)
                    TextField("Master workflow", text: $settings.masterWorkflow)
                    Text("Paste your key above and click “Load my workflows” to pick from dropdowns instead of typing slugs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    workflowPicker("Stems", $settings.stemsWorkflow)
                    workflowPicker("Analyze", $settings.analyzeWorkflow)
                    workflowPicker("Enhance", $settings.enhanceWorkflow)
                    workflowPicker("Master", $settings.masterWorkflow)
                }
            }
            Section("Suno (session-wrapper)") {
                TextField("Sidecar URL", text: $settings.sunoSidecarURLString)
                Text("Run a local Suno API wrapper (e.g. gcui-art/suno-api) on your own account and point this at it. If it's not running, use “Open in Suno (manual)” instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Taste") {
                LabeledContent("Learned from",
                               value: "\(taste.profile.keepCount) kept · \(taste.profile.rejectCount) discarded")
                Button("Reset taste profile", role: .destructive) { taste.reset() }
                    .disabled(taste.profile.keepCount == 0 && taste.profile.rejectCount == 0)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 380)
    }

    private func workflowPicker(_ label: String, _ binding: Binding<String>) -> some View {
        Picker(label, selection: binding) {
            ForEach(settings.availableWorkflows) { wf in Text(wf.name).tag(wf.slug) }
        }
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
