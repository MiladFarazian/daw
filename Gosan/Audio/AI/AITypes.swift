import Foundation

enum AIError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case malformed(String)
    case jobFailed(String)
    case sidecarUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No Music.ai API key set. Add one in Settings (⌘,)."
        case .http(let code, let body):
            return "Music.ai request failed (HTTP \(code)). \(body)"
        case .malformed(let what):
            return "Unexpected response from Music.ai: \(what)"
        case .jobFailed(let why):
            return "Job failed: \(why)"
        case .sidecarUnreachable(let url):
            return "Couldn't reach the Suno sidecar at \(url). Start a local Suno API "
                + "(e.g. gcui-art/suno-api) and set its URL in Settings, or use “Open in Suno (manual).”"
        }
    }
}

/// Job lifecycle states returned by `GET /job/:id`.
enum JobState: String {
    case queued = "QUEUED"
    case started = "STARTED"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
}

/// A running AI job, surfaced in the transport bar.
struct JobProgress: Identifiable {
    let id = UUID()
    var label: String
    var status: String = "Starting"
}

struct AnalysisField: Identifiable {
    let id = UUID()
    let key: String
    let value: String
}

/// A finished analysis, shown in a sheet. Built loosely from the job result so it
/// tolerates whatever fields the chosen analysis workflow emits.
struct AnalysisResult: Identifiable {
    let id = UUID()
    let title: String
    let fields: [AnalysisField]

    init(title: String, result: [String: String]) {
        self.title = title
        self.fields = result
            .sorted { $0.key < $1.key }
            .map { AnalysisField(key: $0.key, value: $0.value) }
    }
}
