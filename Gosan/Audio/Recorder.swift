import AVFoundation

/// Captures the default audio input to a file, then hands the URL back.
/// Records a take into a fresh file (placed on a new track by the caller).
@MainActor
final class Recorder: ObservableObject {
    @Published var isRecording = false
    var onFinish: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var recordedURL: URL?

    func toggle() { isRecording ? stop() : start() }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    granted ? self.begin() : self.onError?("Microphone access denied.")
                }
            }
        default:
            onError?("Microphone access denied. Enable it in System Settings → Privacy → Microphone.")
        }
    }

    private func begin() {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, let dir = try? LibraryStorage.importsDirectory() else {
            onError?("No audio input available.")
            return
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString)-recording.caf")
        guard let writer = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            onError?("Could not create the recording file.")
            return
        }
        recordedURL = url

        // The tap runs on a realtime thread; it writes to a captured file, not to self.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? writer.write(from: buffer)
        }

        do {
            try engine.start()
            isRecording = true
        } catch {
            input.removeTap(onBus: 0)
            onError?("Could not start the audio engine.")
        }
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        if let url = recordedURL { onFinish?(url) }
        recordedURL = nil
    }
}
