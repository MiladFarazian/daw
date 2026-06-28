import AVFoundation

/// Captures the default audio input to a file, with optional live input monitoring
/// and a level meter. Its own engine, so it never disturbs timeline playback.
@MainActor
final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var isMonitoring = false
    @Published var inputLevel: Float = 0

    var onStarted: (() -> Void)?
    var onFinish: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let monitorMixer = AVAudioMixerNode()
    private var recordedURL: URL?
    private var graphReady = false

    // MARK: Recording

    func startRecording() {
        requestPermission { [weak self] granted in
            guard let self else { return }
            granted ? self.beginRecording() : self.onError?("Microphone access denied.")
        }
    }

    private func beginRecording() {
        prepareGraph()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, let dir = try? LibraryStorage.importsDirectory() else {
            onError?("No audio input available.")
            return
        }
        let url = dir.appendingPathComponent("\(UUID().uuidString)-recording.caf")
        guard let writer = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            onError?("Could not create the recording file.")
            return
        }
        recordedURL = url

        // Realtime thread: write to the captured file, report level to the main actor.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? writer.write(from: buffer)
            let level = Recorder.level(of: buffer)
            Task { @MainActor in self?.inputLevel = level }
        }

        ensureRunning()
        isRecording = true
        onStarted?()
    }

    func stopRecording() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        inputLevel = 0
        stopIfIdle()
        if let url = recordedURL { onFinish?(url) }
        recordedURL = nil
    }

    // MARK: Monitoring

    func setMonitoring(_ on: Bool) {
        guard on else {
            isMonitoring = false
            monitorMixer.outputVolume = 0
            stopIfIdle()
            return
        }
        requestPermission { [weak self] granted in
            guard let self else { return }
            guard granted else { self.onError?("Microphone access denied."); return }
            self.prepareGraph()
            self.isMonitoring = true
            self.monitorMixer.outputVolume = 1
            self.ensureRunning()
        }
    }

    func toggleMonitoring() { setMonitoring(!isMonitoring) }

    // MARK: Engine plumbing

    private func prepareGraph() {
        guard !graphReady else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0 else { return } // retry once a device is available
        engine.attach(monitorMixer)
        engine.connect(input, to: monitorMixer, format: format)
        engine.connect(monitorMixer, to: engine.mainMixerNode, format: format)
        monitorMixer.outputVolume = isMonitoring ? 1 : 0
        graphReady = true
    }

    private func ensureRunning() {
        if !engine.isRunning { try? engine.start() }
    }

    private func stopIfIdle() {
        if !isRecording && !isMonitoring && engine.isRunning { engine.stop() }
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += channel[i] * channel[i] }
        return min(1, (sum / Float(count)).squareRoot() * 3)
    }
}
