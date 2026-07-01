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
/// Health of the local Suno sidecar: running + cookie valid, running but cookie rejected, or down.
enum SidecarStatus {
    case checking
    case ready
    case unauthorized
    case offline
}

enum EditorSheet: Identifiable {
    case generate
    case youtube
    case mixer
    case pianoRoll(UUID)
    case automation(UUID)
    case plugins(UUID)
    case loops
    case stepSequencer(UUID)
    case drummer(UUID)
    case bassPlayer(UUID)
    case chords(UUID)
    case instrument(UUID)
    case analysis(AnalysisResult)

    var id: String {
        switch self {
        case .generate: return "generate"
        case .youtube: return "youtube"
        case .mixer: return "mixer"
        case .pianoRoll(let id): return "piano-\(id.uuidString)"
        case .automation(let id): return "auto-\(id.uuidString)"
        case .plugins(let id): return "plugins-\(id.uuidString)"
        case .loops: return "loops"
        case .stepSequencer(let id): return "step-\(id.uuidString)"
        case .drummer(let id): return "drummer-\(id.uuidString)"
        case .bassPlayer(let id): return "bass-\(id.uuidString)"
        case .chords(let id): return "chords-\(id.uuidString)"
        case .instrument(let id): return "instrument-\(id.uuidString)"
        case .analysis(let result): return result.id.uuidString
        }
    }
}
