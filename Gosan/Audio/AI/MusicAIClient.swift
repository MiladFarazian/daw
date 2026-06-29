import Foundation

/// Thin client for the Music.ai (Moises) developer API.
/// Flow: GET /upload → PUT file → POST /job → poll GET /job/:id.
/// Uses JSONSerialization so it tolerates the per-workflow result schemas.
struct MusicAIClient {
    let apiKey: String
    private let base = URL(string: "https://api.music.ai/v1")!

    private func request(_ path: String, method: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "Authorization")
        return req
    }

    /// List the account's workflows (slug + name) so the user can pick instead of typing.
    func listWorkflows() async throws -> [WorkflowInfo] {
        let (data, resp) = try await URLSession.shared.data(for: request("workflow", method: "GET"))
        try Self.check(resp, data)
        let object = try JSONSerialization.jsonObject(with: data)
        let array: [[String: Any]]
        if let a = object as? [[String: Any]] {
            array = a
        } else if let d = object as? [String: Any], let a = (d["workflows"] ?? d["data"]) as? [[String: Any]] {
            array = a
        } else {
            throw AIError.malformed("workflow list")
        }
        return array.compactMap { item in
            guard let slug = item["slug"] as? String else { return nil }
            return WorkflowInfo(slug: slug, name: (item["name"] as? String) ?? slug)
        }
    }

    /// Ask for a temporary upload URL and the matching download URL.
    func uploadURLs() async throws -> (upload: URL, download: URL) {
        let (data, resp) = try await URLSession.shared.data(for: request("upload", method: "GET"))
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let upload = (obj["uploadUrl"] as? String).flatMap(URL.init),
              let download = (obj["downloadUrl"] as? String).flatMap(URL.init) else {
            throw AIError.malformed("upload URLs")
        }
        return (upload, download)
    }

    /// PUT the local file's bytes to the signed upload URL.
    func put(fileURL: URL, to uploadURL: URL) async throws {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        let data = try Data(contentsOf: fileURL)
        let (respData, resp) = try await URLSession.shared.upload(for: req, from: data)
        try Self.check(resp, respData)
    }

    /// Create a processing job for a workflow slug. Returns the job id.
    func createJob(name: String, workflow: String, inputURL: URL) async throws -> String {
        var req = request("job", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": name,
            "workflow": workflow,
            "params": ["inputUrl": inputURL.absoluteString]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw AIError.malformed("job id")
        }
        return id
    }

    /// Poll a job. Flattens `result` into strings (URLs stay as-is; numbers and
    /// nested JSON are stringified) so callers can pick out what they need.
    func job(_ id: String) async throws -> (state: JobState, result: [String: String], error: String?) {
        let (data, resp) = try await URLSession.shared.data(for: request("job/\(id)", method: "GET"))
        try Self.check(resp, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusString = obj["status"] as? String,
              let state = JobState(rawValue: statusString) else {
            throw AIError.malformed("job status")
        }

        var result: [String: String] = [:]
        if let raw = obj["result"] as? [String: Any] {
            for (key, value) in raw {
                if let string = value as? String {
                    result[key] = string
                } else if let number = value as? NSNumber {
                    result[key] = number.stringValue
                } else if let nested = try? JSONSerialization.data(withJSONObject: value),
                          let string = String(data: nested, encoding: .utf8) {
                    result[key] = string
                }
            }
        }
        return (state, result, obj["error"] as? String)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIError.http(http.statusCode, String(body.prefix(300)))
        }
    }
}
