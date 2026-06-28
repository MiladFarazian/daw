import SwiftUI

/// Learns your taste from keeps/rejects and biases future Suno prompts toward it.
/// v1 is a deterministic descriptor-weight model — embeddings come later.
@MainActor
final class TasteEngine: ObservableObject {
    @Published private(set) var profile: TasteProfile

    init() {
        profile = TasteStore.load()
    }

    // MARK: Signals

    /// Reinforce the user-typed descriptors of a kept candidate's prompt.
    func recordKeep(_ prompt: GeneratePrompt) {
        for descriptor in TasteTokens.descriptors(from: prompt.text) {
            profile.descriptorWeights[descriptor, default: 0] += 1.0
        }
        if let bpm = TasteTokens.bpm(from: prompt.text) { profile.bpmSamples.append(bpm) }
        if prompt.instrumental { profile.instrumentalKeeps += 1 } else { profile.vocalKeeps += 1 }
        profile.keepCount += 1
        persist()
    }

    /// Mildly discourage descriptors of a rejected candidate (rejects are noisy).
    func recordReject(_ prompt: GeneratePrompt) {
        for descriptor in TasteTokens.descriptors(from: prompt.text) {
            profile.descriptorWeights[descriptor, default: 0] -= 0.3
        }
        profile.rejectCount += 1
        persist()
    }

    func reset() {
        profile = TasteProfile()
        persist()
    }

    // MARK: Reads

    /// Positively-weighted descriptors, strongest first.
    var topDescriptors: [(descriptor: String, weight: Double)] {
        profile.descriptorWeights
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { ($0.key, $0.value) }
    }

    var preferredBPM: Int? {
        guard profile.bpmSamples.count >= 3 else { return nil }
        return Int((profile.bpmSamples.reduce(0, +) / Double(profile.bpmSamples.count)).rounded())
    }

    // MARK: Apply

    /// Append the strongest learned descriptors (and a preferred tempo) that the
    /// prompt doesn't already mention. Returns the new prompt and what was added.
    func bias(_ prompt: GeneratePrompt) -> (prompt: GeneratePrompt, added: [String]) {
        let existing = prompt.text.lowercased()
        var added: [String] = []

        for (descriptor, _) in topDescriptors.prefix(3) where !existing.contains(descriptor) {
            added.append(descriptor)
        }
        if let bpm = preferredBPM, TasteTokens.bpm(from: prompt.text) == nil {
            added.append("~\(bpm) bpm")
        }
        guard !added.isEmpty else { return (prompt, []) }

        let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? added.joined(separator: ", ") : trimmed + ", " + added.joined(separator: ", ")
        return (GeneratePrompt(text: text, instrumental: prompt.instrumental), added)
    }

    private func persist() {
        TasteStore.save(profile)
    }
}
