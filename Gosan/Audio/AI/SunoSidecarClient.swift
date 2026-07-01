import Foundation

/// Talks to a locally-running Suno session-wrapper (e.g. gcui-art/suno-api).
/// Flow: POST /api/generate (non-blocking) → poll GET /api/get?ids=… until complete.
struct SunoSidecarClient {
    let baseURL: URL

    /// Is the sidecar reachable? (Any HTTP response counts as "up".)
    func isReachable() async -> Bool {
        if case .offline = await status() { return false }
        return true
    }

    /// Distinguish "ready", "running but the cookie is missing/expired", and "not running".
    /// Any HTTP response means the sidecar is reachable, so `.offline` is reserved for genuine
    /// connection failures. A 2xx = ready; anything else from a running sidecar means the cookie
    /// needs attention — an empty cookie 401s, but an *expired* one 500s ("update SUNO_COOKIE"),
    /// and both should read as "unauthorized", not "offline".
    func status() async -> SidecarStatus {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/get_limit"))
        req.timeoutInterval = 4
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return .offline }
        if (200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Some builds return 200 with an error envelope; treat those as cookie problems.
            return body.localizedCaseInsensitiveContains("unauthorized")
                || body.localizedCaseInsensitiveContains("suno_cookie") ? .unauthorized : .ready
        }
        return .unauthorized   // reachable but not serving limits → the cookie is missing/expired
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
