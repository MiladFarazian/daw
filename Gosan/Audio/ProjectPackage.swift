import Foundation

/// A `.gosan` project package: a folder containing `project.json` plus an `audio/`
/// subfolder with copies of every referenced asset, so projects are self-contained
/// and portable (don't depend on the app library).
enum ProjectPackage {
    static func write(_ document: ProjectDocument, assetURLs: [String: URL], to packageURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: packageURL.path) { try fm.removeItem(at: packageURL) }
        let audioDir = packageURL.appendingPathComponent("audio", isDirectory: true)
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        for (name, source) in assetURLs {
            let dest = audioDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: source, to: dest)
            }
        }
        let data = try JSONEncoder().encode(document)
        try data.write(to: packageURL.appendingPathComponent("project.json"))
    }

    static func read(_ packageURL: URL) throws -> (document: ProjectDocument, audioDir: URL) {
        let data = try Data(contentsOf: packageURL.appendingPathComponent("project.json"))
        let document = try JSONDecoder().decode(ProjectDocument.self, from: data)
        return (document, packageURL.appendingPathComponent("audio", isDirectory: true))
    }
}
