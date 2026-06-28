import Foundation

/// Runs one Music.ai job end-to-end: upload → submit → poll until done.
/// Reports human-readable status through `progress`.
struct JobManager {
    let client: MusicAIClient
    var pollInterval: UInt64 = 2_500_000_000 // 2.5s

    func run(workflow: String,
             fileURL: URL,
             name: String,
             progress: @escaping (String) -> Void) async throws -> [String: String] {
        progress("Uploading")
        let urls = try await client.uploadURLs()
        try await client.put(fileURL: fileURL, to: urls.upload)

        progress("Submitting")
        let id = try await client.createJob(name: name, workflow: workflow, inputURL: urls.download)

        progress("Queued")
        while true {
            try await Task.sleep(nanoseconds: pollInterval)
            let job = try await client.job(id)
            switch job.state {
            case .succeeded:
                return job.result
            case .failed:
                throw AIError.jobFailed(job.error ?? "unknown error")
            case .queued:
                progress("Queued")
            case .started:
                progress("Processing")
            }
        }
    }
}
