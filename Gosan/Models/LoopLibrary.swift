import Foundation
import AVFoundation

/// A reusable audio loop saved in the library.
struct LoopEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var file: String            // filename within the Loops directory
    var bpm: Int?
    var duration: TimeInterval
}

/// A persistent, browsable library of loops (drag onto the timeline / add to a project).
/// Stored in Application Support/Gosan/Loops + a loops.json index.
@MainActor
final class LoopLibrary: ObservableObject {
    @Published private(set) var loops: [LoopEntry] = []

    static func loopsDir() throws -> URL {
        let dir = try LibraryStorage.supportDirectory().appendingPathComponent("Loops", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private static var indexURL: URL? { try? loopsDir().appendingPathComponent("loops.json") }

    init() { load() }

    func load() {
        guard let url = Self.indexURL, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LoopEntry].self, from: data) else { return }
        loops = entries.filter { FileManager.default.fileExists(atPath: (try? Self.loopsDir().appendingPathComponent($0.file).path) ?? "") }
    }

    private func save() {
        guard let url = Self.indexURL, let data = try? JSONEncoder().encode(loops) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func url(for loop: LoopEntry) -> URL? { try? Self.loopsDir().appendingPathComponent(loop.file) }

    /// Copy a source audio file into the library as a new loop.
    @discardableResult
    func addLoop(from source: URL, name: String? = nil, bpm: Int? = nil) -> LoopEntry? {
        guard let dir = try? Self.loopsDir() else { return nil }
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            var duration: TimeInterval = 0
            if let f = try? AVAudioFile(forReading: dest) {
                duration = Double(f.length) / f.processingFormat.sampleRate
            }
            let entry = LoopEntry(name: name ?? source.deletingPathExtension().lastPathComponent,
                                  file: filename, bpm: bpm, duration: duration)
            loops.insert(entry, at: 0)
            save()
            return entry
        } catch {
            return nil
        }
    }

    func importFiles(_ urls: [URL]) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            addLoop(from: url)
        }
    }

    func rename(_ loop: LoopEntry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = loops.firstIndex(where: { $0.id == loop.id }) else { return }
        loops[i].name = trimmed
        save()
    }

    func remove(_ loop: LoopEntry) {
        if let url = url(for: loop) { try? FileManager.default.removeItem(at: url) }
        loops.removeAll { $0.id == loop.id }
        save()
    }
}
