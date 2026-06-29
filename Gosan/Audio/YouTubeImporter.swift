import Foundation

/// Downloads a YouTube (or other yt-dlp-supported) URL's audio via the `yt-dlp` CLI.
/// Requires the app to run un-sandboxed (so it can spawn the tool).
enum YouTubeImporter {
    enum YTError: LocalizedError {
        case notInstalled
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "yt-dlp not found. Install it with:  brew install yt-dlp"
            case .failed(let message):
                return "YouTube download failed: \(message)"
            }
        }
    }

    static func ytdlpPath() -> String? {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp",
                          "/usr/bin/yt-dlp", NSHomeDirectory() + "/.local/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Download the best m4a audio into `dir`. Returns the downloaded file URL. Blocking.
    static func download(url: String, into dir: URL) throws -> URL {
        guard let tool = ytdlpPath() else { throw YTError.notInstalled }

        let uuid = UUID().uuidString
        let template = dir.appendingPathComponent("\(uuid).%(ext)s").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-f", "bestaudio[ext=m4a]/bestaudio",
                             "--no-playlist", "--no-progress", "--no-warnings",
                             "-o", template, "--print", "after_move:filepath", url]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Send progress/errors to a temp file (avoids pipe-buffer deadlock).
        let errLog = dir.appendingPathComponent("\(uuid).yt-err.log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errLog)
        process.standardError = errHandle

        try process.run()
        process.waitUntilExit()
        errHandle.closeFile()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = (try? String(contentsOf: errLog, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: errLog)

        guard process.terminationStatus == 0 else {
            throw YTError.failed(String((errText.isEmpty ? out : errText).suffix(300)))
        }

        if let path = out.split(separator: "\n").map(String.init).last(where: { !$0.isEmpty }),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fallback: find the file we wrote by its UUID prefix.
        if let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
           let match = files.first(where: { $0.hasPrefix(uuid) && !$0.hasSuffix(".log") }) {
            return dir.appendingPathComponent(match)
        }
        throw YTError.failed("downloaded file not found")
    }
}
