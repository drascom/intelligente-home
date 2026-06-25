import AVFoundation
import Foundation
import LiveKit
import Speech

/// SFSpeech tabanlı wake-word tanıyıcı — **kendi AVAudioEngine'i YOK**.
///
/// Eski tasarımda bu sınıf mikrofonu kendi `AVAudioEngine`'iyle dinliyordu; bu da
/// LiveKit'in WebRTC ses motoruyla AYNI fiziksel cihazı çekiştiriyordu → macOS
/// CoreAudio iki motor arası temiz devir yapamıyor (`StartIO error 35`, aggregate
/// device hatası, "there already is a thread"). Çözüm: TEK motor. LiveKit mikrofonu
/// SÜREKLİ yakalar; bu sınıf yalnızca o PCM tamponlarını **gözlemler**.
///
/// PCM, `WakePCMRenderer` (LiveKit `AudioRenderer`) üzerinden ses render thread'inde
/// `appendPCM(_:)`'e gelir ve aktif `SFSpeechAudioBufferRecognitionRequest`'e eklenir.
/// Tetikleyici kelime duyulunca `onWakeDetected` çağrılır.
@MainActor
final class WakeWordDetector: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var lastHeard: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var wakePattern: String = "candan"
    private var rotationTimer: DispatchSourceTimer?

    // Aktif tanıma isteği — ses render thread'inden (`appendPCM`) ve main'den
    // (rotate/stop) erişildiği için kilitle korunur.
    private nonisolated(unsafe) var request: SFSpeechAudioBufferRecognitionRequest?
    private nonisolated let requestLock = NSLock()

    var onWakeDetected: (() -> Void)?
    /// Tanıma kalıcı olarak kullanılamıyor (örn. macOS'ta Siri+Dikte kapalı).
    var onUnavailable: ((String) -> Void)?
    private var reportedUnavailable = false

    // MARK: - PCM girişi (ses render thread'i)

    // TEŞHİS: PCM gerçekten akıyor mu? render() çağrılıyor mu? İlk tamponu (format
    // ile) ve her ~500 tamponda bir akışı logla. PCM hiç gelmiyorsa → renderer
    // bağlanması/startLocalRecording sorunu. Geliyorsa ama wake yoksa → format/tanıma.
    private nonisolated let pcmDiagLock = NSLock()
    private nonisolated(unsafe) var pcmCount = 0

    /// LiveKit yerel mic PCM tamponunu aktif tanıma isteğine ekler. Ses render
    /// thread'inden çağrılır → MainActor'a HOP ETME, her tampon için Task AÇMA.
    /// `request` kilitle korunur; aktif istek yoksa sessiz no-op (uyanık/teardown).
    nonisolated func appendPCM(_ buffer: AVAudioPCMBuffer) {
        pcmDiagLock.lock()
        let n = pcmCount; pcmCount += 1
        pcmDiagLock.unlock()
        if n == 0 {
            let f = buffer.format
            Log.line("[Wake] PCM İLK tampon: \(Int(f.sampleRate))Hz ch=\(f.channelCount) fmt=\(f.commonFormat.rawValue) interleaved=\(f.isInterleaved) frames=\(buffer.frameLength)")
        } else if n % 500 == 0 {
            Log.line("[Wake] PCM akıyor: \(n) tampon")
        }
        requestLock.lock(); defer { requestLock.unlock() }
        request?.append(buffer)
    }

    // MARK: - İzinler

    // nonisolated: SFSpeech, yetki completion'ını ARBITRARY bir arka plan
    // kuyruğunda çağırır; @MainActor olsaydı executor assertion'ı (SIGTRAP) atardı.
    nonisolated func requestPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Yaşam döngüsü

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

        startRecognition()
        // Apple tanıma oturumu ~1 dk sonra kesilir; periyodik olarak yalnız
        // isteği/task'ı yenile (LiveKit kaydı/motoru ASLA dokunulmaz).
        scheduleRotation()
        isListening = true
        Log.line("[Wake] SFSpeech dinliyor '\(wakePattern)' locale=\(localeId) onDevice=\(rec.supportsOnDeviceRecognition) available=\(rec.isAvailable) · PCM=LiveKit capture")
    }

    func stop() {
        rotationTimer?.cancel()
        rotationTimer = nil
        endRecognition()
        isListening = false
    }

    // MARK: - Tanıma isteği (yalnız bu yenilenir; ses motoru LiveKit'te kalır)

    private func startRecognition() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        requestLock.lock(); request = req; requestLock.unlock()

        // @Sendable: SFSpeech result handler'ı arka plan kuyruğunda çağrılır.
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
                let msg = error.localizedDescription
                // BEKLENEN durumlar — gerçek hata DEĞİL, loglamaya gerek yok:
                //  • "No speech detected": wake dinleyici boştayken sessizlik penceresi
                //    dolunca her re-arm'da döner (idle'da sürekli tekrarlar).
                //  • "canceled/cancelled": rotate (50s) veya stop() tanımayı iptal edince.
                let benign = msg.localizedCaseInsensitiveContains("No speech")
                    || msg.localizedCaseInsensitiveContains("cancel")
                if !benign {
                    Log.error("[Wake] SFSpeech task hatası: \(msg)")
                }
                // macOS: SFSpeech, Siri/Dikte açık değilse hiç çalışmaz — rotate
                // çözmez, kullanıcıyı sistem ayarına yönlendir.
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

    private func endRecognition() {
        requestLock.lock()
        request?.endAudio()
        request = nil
        requestLock.unlock()
        task?.cancel()
        task = nil
    }

    private func scheduleRotation() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 50, repeating: 50) // 50s — Apple limiti dolmadan
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.isListening else { return }
                // Yalnız isteği/task'ı yenile — LiveKit kaydı dokunulmaz.
                self.endRecognition()
                self.startRecognition()
            }
        }
        timer.resume()
        rotationTimer = timer
    }

    private func matches(text: String) -> Bool {
        // Word-boundary match: "candanca" içinde "candan" tetiklemez.
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wakePattern))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

/// LiveKit `AudioManager.shared.add(localAudioRenderer:)` ile kaydedilir; yerel mic
/// PCM tamponlarını ses render thread'inde alıp wake tanıyıcıya iletir. Ayrı küçük
/// bir tip: `AudioRenderer` `@objc` protokolü `render`'ı nonisolated ister, oysa
/// `WakeWordDetector` @MainActor. `onPCM` `@Sendable` ve `appendPCM` nonisolated
/// olduğundan render thread'inden güvenle çağrılır (MainActor hop yok).
final class WakePCMRenderer: NSObject, AudioRenderer {
    private let onPCM: @Sendable (AVAudioPCMBuffer) -> Void
    init(onPCM: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { self.onPCM = onPCM }
    func render(pcmBuffer: AVAudioPCMBuffer) { onPCM(pcmBuffer) }
}
