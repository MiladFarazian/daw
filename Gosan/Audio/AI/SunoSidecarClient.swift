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

    func customGenerate(_ req: CustomGenerateRequest,
                        progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        do {
            return try await runCustomGenerate(req, progress: progress)
        } catch let error as URLError where Self.isConnectionError(error.code) {
            throw AIError.sidecarUnreachable(baseURL.absoluteString)
        }
    }

    func generateStems(audioID: String,
                       progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        do {
            return try await runGenerateStems(audioID: audioID, progress: progress)
        } catch let error as URLError where Self.isConnectionError(error.code) {
            throw AIError.sidecarUnreachable(baseURL.absoluteString)
        }
    }

    func extend(audioID: String, prompt: String, styleTags: String, continueAt: Double?,
                model: String?,
                progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        do {
            return try await runExtend(audioID: audioID, prompt: prompt, styleTags: styleTags,
                                       continueAt: continueAt, model: model, progress: progress)
        } catch let error as URLError where Self.isConnectionError(error.code) {
            throw AIError.sidecarUnreachable(baseURL.absoluteString)
        }
    }

    /// Generate lyrics for a given style prompt. Returns (title, text).
    /// Wraps POST /api/generate_lyrics → {title, text} (no polling needed; the sidecar polls internally).
    func generateLyrics(prompt: String) async throws -> (title: String, text: String) {
        do {
            return try await runGenerateLyrics(prompt: prompt)
        } catch let error as URLError where Self.isConnectionError(error.code) {
            throw AIError.sidecarUnreachable(baseURL.absoluteString)
        }
    }

    /// Best-effort credits fetch; returns nil on any failure (network, parse, etc.).
    func credits() async -> SunoCredits? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/get_limit"))
        req.timeoutInterval = 6
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let left = obj["credits_left"] as? Int,
              let limit = obj["monthly_limit"] as? Int,
              let usage = obj["monthly_usage"] as? Int
        else { return nil }
        return SunoCredits(creditsLeft: left, monthlyLimit: limit, monthlyUsage: usage)
    }

    // MARK: - Private implementation

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
        return try await awaitClips(ids: ids, progress: progress)
    }

    private func runCustomGenerate(_ req: CustomGenerateRequest,
                                   progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        progress("Submitting to Suno")
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("api/custom_generate"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "tags": req.styleTags,
            "prompt": req.lyrics,
            "make_instrumental": req.instrumental,
            "wait_audio": false
        ]
        if !req.title.isEmpty { body["title"] = req.title }
        if !req.negativeTags.isEmpty { body["negative_tags"] = req.negativeTags }
        if let model = req.model { body["model"] = model }

        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: urlReq)
        try Self.check(resp, data)

        let ids = try Self.clips(from: data).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AIError.malformed("no clip ids from sidecar") }

        progress("Generating")
        return try await awaitClips(ids: ids, progress: progress)
    }

    private func runGenerateStems(audioID: String,
                                  progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        progress("Splitting stems")
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("api/generate_stems"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: ["audio_id": audioID])
        let (data, resp) = try await URLSession.shared.data(for: urlReq)
        try Self.check(resp, data)

        let ids = try Self.clips(from: data).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AIError.malformed("no stem clip ids from sidecar") }

        progress("Splitting stems (waiting)")
        return try await awaitClips(ids: ids, progress: { s in progress("Splitting stems — \(s)") })
    }

    private func runExtend(audioID: String, prompt: String, styleTags: String,
                           continueAt: Double?, model: String?,
                           progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
        progress("Extending clip")
        var urlReq = URLRequest(url: baseURL.appendingPathComponent("api/extend_audio"))
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "audio_id": audioID,
            "prompt": prompt,
            "tags": styleTags,
            "wait_audio": false
        ]
        if let at = continueAt { body["continue_at"] = at }
        if let m = model { body["model"] = m }

        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: urlReq)
        try Self.check(resp, data)

        let ids = try Self.clips(from: data).compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { throw AIError.malformed("no clip ids from sidecar extend") }

        progress("Extending")
        return try await awaitClips(ids: ids, progress: progress)
    }

    /// Shared poll loop: polls GET /api/get?ids=… every 4s up to ~3 minutes.
    /// Returns complete clips as soon as all are done, or whatever has audio on timeout.
    private func awaitClips(ids: [String],
                            progress: @escaping (String) -> Void) async throws -> [GeneratedCandidate] {
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

    private func runGenerateLyrics(prompt: String) async throws -> (title: String, text: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/generate_lyrics"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError.malformed("lyrics response not a JSON object")
        }
        let title = (obj["title"] as? String) ?? ""
        let text = (obj["text"] as? String) ?? ""
        guard !text.isEmpty else {
            throw AIError.malformed("lyrics response missing 'text' field")
        }
        return (title: title, text: text)
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

        // Parse duration tolerantly (may be a Double or Int in the JSON).
        let duration: Double?
        if let d = clip["duration"] as? Double { duration = d }
        else if let d = clip["duration"] as? Int { duration = Double(d) }
        else { duration = nil }

        // Parse style tags from metadata.tags if present.
        let styleTags: String?
        if let meta = clip["metadata"] as? [String: Any],
           let tags = meta["tags"] as? String, !tags.isEmpty {
            styleTags = tags
        } else {
            styleTags = nil
        }

        return GeneratedCandidate(id: id, title: title, audioURL: url,
                                  duration: duration, styleTags: styleTags)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if http.statusCode == 402 { throw AIError.outOfCredits }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
