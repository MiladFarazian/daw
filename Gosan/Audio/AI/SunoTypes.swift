import Foundation

/// What the user wants Suno to make. The compiled string is what we actually send.
struct GeneratePrompt {
    var text: String
    var instrumental: Bool

    var compiled: String {
        var prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if instrumental && !prompt.lowercased().contains("instrumental") {
            prompt += prompt.isEmpty ? "instrumental" : ", instrumental"
        }
        return prompt
    }

    var shortLabel: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : String(trimmed.prefix(24))
    }
}

/// A finished Suno clip from the sidecar.
struct GeneratedCandidate {
    let id: String
    let title: String
    let audioURL: URL
}

/// A downloaded candidate, ready to preview and add to the timeline.
struct CandidateAsset: Identifiable {
    let id: String
    let title: String
    let asset: AudioAsset
}

/// Which modal sheet the editor is showing (one sheet modifier avoids SwiftUI's
/// multiple-sheet conflicts).
enum EditorSheet: Identifiable {
    case generate
    case youtube
    case analysis(AnalysisResult)

    var id: String {
        switch self {
        case .generate: return "generate"
        case .youtube: return "youtube"
        case .analysis(let result): return result.id.uuidString
        }
    }
}
