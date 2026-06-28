import Foundation

/// Talks to a locally-running Suno session-wrapper (e.g. gcui-art/suno-api).
/// Flow: POST /api/generate (non-blocking) → poll GET /api/get?ids=… until complete.
struct SunoSidecarClient {
    let baseURL: URL

    /// Is the sidecar reachable? (Any HTTP response counts as "up".)
    func isReachable() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/get_limit"))
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    func generate(_ prompt: GeneratePrompt,
                  progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        do {
            return try await runGenerate(prompt, progress: progress)
        } catch let error as URLError where Self.isConnectionError(error.code) {
            throw AIError.sidecarUnreachable(baseURL.absoluteString)
        }
    }

    private static func isConnectionError(_ code: URLError.Code) -> Bool {
        [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
         .notConnectedToInternet, .timedOut, .dnsLookupFailed].contains(code)
    }

    private func runGenerate(_ prompt: GeneratePrompt,
                             progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        progress("Submitting to Suno")
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt.compiled,
            "make_instrumental": prompt.instrumental,
            "wait_audio": false
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)

        let ids = try Self.clips(from: data).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AIError.malformed("no clip ids from sidecar") }

        progress("Generating")
        let idParam = ids.joined(separator: ",")
        var lastWithAudio: [GeneratedCandidate] = []

        for _ in 0..<45 { // ~3 minutes at 4s
            try await Task.sleep(nanoseconds: 4_000_000_000)

            var components = URLComponents(url: baseURL.appendingPathComponent("api/get"),
                                           resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "ids", value: idParam)]
            let (gdata, gresp) = try await URLSession.shared.data(from: components.url!)
            try Self.check(gresp, gdata)

            let clips = try Self.clips(from: gdata)
            if clips.contains(where: { ($0["status"] as? String) == "error" }) {
                throw AIError.jobFailed("Suno returned an error status")
            }

            lastWithAudio = clips.compactMap(Self.candidate)
            let complete = clips.filter { ($0["status"] as? String) == "complete" }.compactMap(Self.candidate)
            if !complete.isEmpty && complete.count == clips.count {
                return complete
            }
            progress("Generating (\(lastWithAudio.count)/\(clips.count))")
        }

        // Timed out — return anything that already has audio, else fail.
        if !lastWithAudio.isEmpty { return lastWithAudio }
        throw AIError.jobFailed("Suno generation timed out")
    }

    // MARK: - Parsing

    private static func clips(from data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] { return array }
        if let dict = object as? [String: Any] {
            if let array = dict["clips"] as? [[String: Any]] { return array }
            if let array = dict["data"] as? [[String: Any]] { return array }
        }
        throw AIError.malformed("sidecar clip list")
    }

    private static func candidate(from clip: [String: Any]) -> GeneratedCandidate? {
        guard let id = clip["id"] as? String,
              let urlString = clip["audio_url"] as? String, !urlString.isEmpty,
              let url = URL(string: urlString) else { return nil }
        let title = (clip["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled idea"
        return GeneratedCandidate(id: id, title: title, audioURL: url)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
