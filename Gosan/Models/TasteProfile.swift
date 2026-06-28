import Foundation

/// What the Taste Engine has learned about you. Deliberately simple and inspectable.
struct TasteProfile: Codable {
    var descriptorWeights: [String: Double] = [:]
    var bpmSamples: [Double] = []
    var instrumentalKeeps: Int = 0
    var vocalKeeps: Int = 0
    var keepCount: Int = 0
    var rejectCount: Int = 0
}

/// Persists the profile as JSON in the app container.
enum TasteStore {
    private static func fileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Gosan", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("taste.json")
    }

    static func load() -> TasteProfile {
        guard let url = try? fileURL(),
              let data = try? Data(contentsOf: url),
              let profile = try? JSONDecoder().decode(TasteProfile.self, from: data) else {
            return TasteProfile()
        }
        return profile
    }

    static func save(_ profile: TasteProfile) {
        guard let url = try? fileURL(), let data = try? JSONEncoder().encode(profile) else { return }
        try? data.write(to: url)
    }
}

/// Turns a free-text prompt into reusable taste signals.
enum TasteTokens {
    private static let stopwords: Set<String> = [
        "a", "an", "the", "with", "and", "of", "in", "for", "to", "my", "some",
        "very", "really", "make", "made", "song", "track", "music", "sound",
        "sounds", "like", "feel", "feels", "instrumental", "vocal", "vocals", "that"
    ]

    /// Comma-separated phrases become descriptors; long phrases fall back to words.
    static func descriptors(from text: String) -> [String] {
        let parts = text.lowercased().split(whereSeparator: { $0 == "," || $0 == "\n" })
        var result: Set<String> = []
        for raw in parts {
            let phrase = raw.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty,
                  phrase.range(of: #"^\d{2,3}\s?bpm$"#, options: .regularExpression) == nil else { continue }
            let words = phrase.split(separator: " ").map(String.init)
            let meaningful = words.filter { !stopwords.contains($0) && $0.count > 2 }
            guard !meaningful.isEmpty else { continue }
            if words.count <= 3 {
                result.insert(meaningful.joined(separator: " "))
            } else {
                meaningful.forEach { result.insert($0) }
            }
        }
        return Array(result)
    }

    static func bpm(from text: String) -> Double? {
        let lower = text.lowercased()
        guard let range = lower.range(of: #"(\d{2,3})\s?bpm"#, options: .regularExpression) else { return nil }
        let digits = lower[range].replacingOccurrences(of: "bpm", with: "").trimmingCharacters(in: .whitespaces)
        return Double(digits)
    }
}
