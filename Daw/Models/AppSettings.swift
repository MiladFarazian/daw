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

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init() {
        apiKey = Keychain.get("musicai-api-key") ?? ""
        // Known-good defaults; the user copies exact slugs from their Music.ai dashboard.
        stemsWorkflow = UserDefaults.standard.string(forKey: "stemsWorkflow")
            ?? "music-ai/stems-vocals-accompaniment"
        analyzeWorkflow = UserDefaults.standard.string(forKey: "analyzeWorkflow")
            ?? "music-ai/music-analysis"
    }
}
