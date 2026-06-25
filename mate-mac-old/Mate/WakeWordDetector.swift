import Foundation
import AVFoundation
import Speech

@MainActor
final class WakeWordDetector: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastHeard: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var wakePattern: String = "mate"
    private var rotationTimer: DispatchSourceTimer?

    var onWakeDetected: (() -> Void)?
    /// Tanıma kalıcı olarak kullanılamıyor (örn. macOS'ta Siri+Dikte kapalı).
    /// Bir kez çağrılır; UI kullanıcıyı sistem ayarına yönlendirmeli.
    var onUnavailable: ((String) -> Void)?
    private var reportedUnavailable = false

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start(wakeWord: String, language: String) throws {
        guard !isListening else { return }
        reportedUnavailable = false   // kullanıcı Dikte'yi açıp yeniden deneyebilir
        wakePattern = wakeWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wakePattern.isEmpty else {
            throw NSError(domain: "WakeWord", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Wake word boş"])
        }

        let localeId = language.contains("-") ? language : (language.lowercased() == "tr" ? "tr-TR" : language)
        let locale = Locale(identifier: localeId)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw NSError(domain: "WakeWord", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognizer mevcut değil: \(localeId)"])
        }
        recognizer = rec

        try startSession()
        // Apple session ~1 dk sonra kesilir; periyodik rotate
        scheduleRotation()
        isListening = true
        Log.line("[Wake] listening for '\(wakePattern)' (\(localeId))")
    }

    func stop() {
        rotationTimer?.cancel()
        rotationTimer = nil
        endSession()
        isListening = false
    }

    private func startSession() throws {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        request = req

        let eng = AVAudioEngine()
        let inputNode = eng.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        eng.prepare()
        try eng.start()
        engine = eng

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                Task { @MainActor in
                    self.lastHeard = text
                    if self.matches(text: text) {
                        let cb = self.onWakeDetected
                        self.stop()
                        cb?()
                    }
                }
            }
            if let error {
                // Otomatik rotate yine de yapacak; sessizce loglayıp geç
                Log.line("[Wake] task error: \(error.localizedDescription)")
                // macOS: SFSpeech, sistemde Siri veya Dikte açık olmadan hiç
                // çalışmıyor — rotate etmek çözmez, kullanıcıyı bilgilendir.
                let msg = error.localizedDescription
                if msg.localizedCaseInsensitiveContains("dictation"),
                   msg.localizedCaseInsensitiveContains("disabled") {
                    Task { @MainActor in
                        guard !self.reportedUnavailable else { return }
                        self.reportedUnavailable = true
                        self.stop()
                        self.onUnavailable?(msg)
                    }
                }
            }
        }
    }

    private func endSession() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
    }

    private func scheduleRotation() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 50, repeating: 50)  // 50s — Apple limiti dolmadan
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.endSession()
                do { try self.startSession() }
                catch { Log.line("[Wake] rotate failed: \(error)") }
            }
        }
        timer.resume()
        rotationTimer = timer
    }

    private func matches(text: String) -> Bool {
        // Word-boundary match: "matematik" içinde "mate" tetiklemez
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wakePattern))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
