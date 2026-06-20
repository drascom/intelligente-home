import AVFoundation
import Foundation
import Speech

/// SFSpeech tabanlı wake-word dinleyici. Kendi AVAudioEngine'iyle mikrofonu
/// dinler; tetikleyici kelimeyi duyunca `onWakeDetected` çağırır ve durur.
///
/// mate-mac'ten port edildi; bu uygulamada LiveKit mikrofonu wake olana kadar
/// kapalı tutulur, wake duyulunca açılır (bkz. WakeCoordinator).
@MainActor
final class WakeWordDetector: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastHeard: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine: AVAudioEngine?
    private var wakePattern: String = "candan"
    private var rotationTimer: DispatchSourceTimer?

    var onWakeDetected: (() -> Void)?
    /// Tanıma kalıcı olarak kullanılamıyor (örn. macOS'ta Siri+Dikte kapalı).
    /// Bir kez çağrılır; UI kullanıcıyı sistem ayarına yönlendirmeli.
    var onUnavailable: ((String) -> Void)?
    private var reportedUnavailable = false

    // nonisolated: SFSpeech, yetki completion'ını ARBITRARY bir arka plan
    // kuyruğunda çağırır. Bu metot @MainActor olsaydı completion closure'ı da
    // main-actor-isolated sayılır ve arka planda çağrılınca Swift executor
    // assertion'ı (SIGTRAP) ile çökerdi. nonisolated → assertion eklenmez.
    nonisolated func requestPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    func start(wakeWord: String, language: String) throws {
        guard !isListening else { return }
        reportedUnavailable = false // kullanıcı Dikte'yi açıp yeniden deneyebilir
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
        // Apple session ~1 dk sonra kesilir; periyodik rotate.
        scheduleRotation()
        isListening = true
        print("[Wake] listening for '\(wakePattern)' (\(localeId))")
        Log.line("[Wake] SFSpeech dinliyor '\(wakePattern)' locale=\(localeId) onDevice=\(rec.supportsOnDeviceRecognition) available=\(rec.isAvailable)")
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
        // Tap'i nonisolated yardımcıdan kur: tap closure'ı ses render thread'inde
        // çağrılır; @MainActor bağlamında oluşturulursa isolation assertion'ı ile
        // çökerdi. nonisolated helper içindeki closure main-actor-isolated olmaz.
        Self.installTap(on: eng, feeding: req)
        eng.prepare()
        try eng.start()
        engine = eng

        // @Sendable: SFSpeech result handler'ı da arka plan kuyruğunda çağrılır.
        // Closure'ı @Sendable yapınca main-actor izolasyon assertion'ı eklenmez;
        // tüm @MainActor state erişimi içeride Task { @MainActor in } ile yapılır.
        let handler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, error in
            if let result {
                let text = result.bestTranscription.formattedString.lowercased()
                Log.line("[Wake] duydu: '\(text)'")
                Task { @MainActor in
                    guard let self else { return }
                    self.lastHeard = text
                    if self.matches(text: text) {
                        Log.line("[Wake] EŞLEŞTİ → tetikle")
                        let cb = self.onWakeDetected
                        self.stop()
                        cb?()
                    }
                }
            }
            if let error {
                // Otomatik rotate yine de yapacak; sessizce loglayıp geç.
                print("[Wake] task error: \(error.localizedDescription)")
                Log.error("[Wake] SFSpeech task hatası: \(error.localizedDescription)")
                // macOS: SFSpeech, sistemde Siri veya Dikte açık olmadan hiç
                // çalışmıyor — rotate çözmez, kullanıcıyı bilgilendir.
                let msg = error.localizedDescription
                if msg.localizedCaseInsensitiveContains("dictation"),
                   msg.localizedCaseInsensitiveContains("disabled") {
                    Task { @MainActor in
                        guard let self, !self.reportedUnavailable else { return }
                        self.reportedUnavailable = true
                        self.stop()
                        self.onUnavailable?(msg)
                    }
                }
            }
        }
        task = recognizer?.recognitionTask(with: req, resultHandler: handler)
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
        timer.schedule(deadline: .now() + 50, repeating: 50) // 50s — Apple limiti dolmadan
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                self.endSession()
                do { try self.startSession() }
                catch { print("[Wake] rotate failed: \(error)") }
            }
        }
        timer.resume()
        rotationTimer = timer
    }

    /// Tap kurulumu — nonisolated: kurulan closure ses render thread'inde çalışır,
    /// main-actor bağlamında oluşturulmamalı (yoksa isolation assertion → çöker).
    nonisolated private static func installTap(
        on engine: AVAudioEngine, feeding req: SFSpeechAudioBufferRecognitionRequest
    ) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
    }

    private func matches(text: String) -> Bool {
        // Word-boundary match: "candanca" içinde "candan" tetiklemez.
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wakePattern))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
