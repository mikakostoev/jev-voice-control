import AVFoundation
import Speech

/// Always-on speech recognition. An utterance ends after a short silence; onFinal then fires with its text
/// and a fresh recognition session starts straight away.
@MainActor
final class Listener {
    var onPartial: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    private(set) var enabled = false

    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: Registry.locale))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Task<Void, Never>?
    private var last = ""

    static func requestPermissions(then done: @escaping @MainActor () -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in
            AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in done() } }
        }
    }

    /// Called after a config reload: a new language needs a new recognizer.
    func applyConfig() {
        guard recognizer?.locale.identifier.replacingOccurrences(of: "_", with: "-") != Registry.locale else { return }
        log("recognition language → \(Registry.locale)")
        end()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: Registry.locale))
        begin()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        log("listening \(on ? "on" : "paused")")
        if on { begin() } else { end() }
    }

    private func begin() {
        guard enabled, request == nil else { return }
        last = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let recognizer, recognizer.isAvailable, format.sampleRate > 0,
              SFSpeechRecognizer.authorizationStatus() == .authorized else {
            log("cannot listen: locale=\(recognizer?.locale.identifier ?? "unsupported") available=\(recognizer?.isAvailable ?? false) speechAuth=\(SFSpeechRecognizer.authorizationStatus().rawValue) micAuth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) input=\(format.sampleRate)Hz")
            retry(after: 5)
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request = req
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in req.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch {
            log("audio engine failed: \(error)")
            end()
            retry(after: 5)
            return
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.request === req else { return }
                // the on-device final result can come back empty; keep the last partial
                if let text, !text.isEmpty, text != self.last {
                    self.last = text
                    self.onPartial(text)
                    self.silenceTimer?.cancel()
                    self.silenceTimer = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(Registry.silence * 1_000_000_000))  // no new words = end of utterance
                        if !Task.isCancelled { self.utteranceDone(req) }
                    }
                }
                if done { self.utteranceDone(req) }  // also the recognizer's own "no speech" timeouts: just restart
            }
        }
    }

    private func utteranceDone(_ req: SFSpeechAudioBufferRecognitionRequest) {
        guard request === req else { return }
        let text = last
        end()
        if text.isEmpty {
            retry(after: 0.3)
        } else {
            log("heard: “\(text)”")
            onFinal(text)
            begin()
        }
    }

    private func end() {
        silenceTimer?.cancel()
        silenceTimer = nil
        request?.endAudio()
        request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
    }

    private func retry(after seconds: Double) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.begin()
        }
    }
}
