import Foundation

/// Copies externally-selected audio into the app's container so playback no longer
/// depends on holding security-scoped access to the original file.
enum LibraryStorage {
    static func importsDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Gosan/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func copyIntoLibrary(_ source: URL) throws -> URL {
        let directory = try importsDirectory()
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Move a freshly-downloaded temp file into the library under a friendly name.
    static func adopt(tempURL: URL, suggestedName: String) throws -> URL {
        let directory = try importsDirectory()
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(suggestedName)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            try FileManager.default.copyItem(at: tempURL, to: destination)
        }
        return destination
    }
}
