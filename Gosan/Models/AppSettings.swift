import SwiftUI

/// User settings: the Music.ai API key (Keychain) and workflow slugs (UserDefaults).
@MainActor
final class AppSettings: ObservableObject {
    @Published var apiKey: String {
        didSet { Keychain.set("musicai-api-key", apiKey) }
    }
    @Published var stemsWorkflow: String {
        didSet { UserDefaults.standard.set(stemsWorkflow, forKey: "stemsWorkflow") }
    }
    @Published var analyzeWorkflow: String {
        didSet { UserDefaults.standard.set(analyzeWorkflow, forKey: "analyzeWorkflow") }
    }
    @Published var enhanceWorkflow: String {
        didSet { UserDefaults.standard.set(enhanceWorkflow, forKey: "enhanceWorkflow") }
    }
    @Published var masterWorkflow: String {
        didSet { UserDefaults.standard.set(masterWorkflow, forKey: "masterWorkflow") }
    }
    @Published var sunoSidecarURLString: String {
        didSet { UserDefaults.standard.set(sunoSidecarURLString, forKey: "sunoSidecarURL") }
    }

    @Published var availableWorkflows: [WorkflowInfo] = []
    @Published var workflowStatus: String?

    @Published var recentProjects: [String] {
        didSet { UserDefaults.standard.set(recentProjects, forKey: "recentProjects") }
    }

    /// Record a project path at the top of the recents list (deduped, capped).
    func addRecent(_ url: URL) {
        let path = url.path
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        if recentProjects.count > 8 { recentProjects = Array(recentProjects.prefix(8)) }
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Fetch the account's workflows so Settings can offer dropdowns (and verify the key).
    func loadWorkflows() {
        guard hasAPIKey else { workflowStatus = "Add your Moises key first."; return }
        workflowStatus = "Loading…"
        let client = MusicAIClient(apiKey: apiKey)
        Task {
            do {
                let workflows = try await client.listWorkflows()
                availableWorkflows = workflows
                workflowStatus = workflows.isEmpty
                    ? "Connected, but no workflows — create some at developer.moises.ai."
                    : "✓ \(workflows.count) workflows loaded."
            } catch {
                workflowStatus = error.localizedDescription
            }
        }
    }

    var sunoSidecarURL: URL {
        URL(string: sunoSidecarURLString) ?? URL(string: "http://127.0.0.1:3000")!
    }

    init() {
        apiKey = Keychain.get("musicai-api-key") ?? ""
        // Known-good defaults; the user copies exact slugs from their Music.ai dashboard.
        stemsWorkflow = UserDefaults.standard.string(forKey: "stemsWorkflow")
            ?? "music-ai/stems-vocals-accompaniment"
        analyzeWorkflow = UserDefaults.standard.string(forKey: "analyzeWorkflow")
            ?? "music-ai/music-analysis"
        enhanceWorkflow = UserDefaults.standard.string(forKey: "enhanceWorkflow")
            ?? "music-ai/vocal-enhancement"
        masterWorkflow = UserDefaults.standard.string(forKey: "masterWorkflow")
            ?? "music-ai/mastering"
        sunoSidecarURLString = UserDefaults.standard.string(forKey: "sunoSidecarURL")
            ?? "http://127.0.0.1:3000"
        recentProjects = UserDefaults.standard.stringArray(forKey: "recentProjects") ?? []
    }
}
