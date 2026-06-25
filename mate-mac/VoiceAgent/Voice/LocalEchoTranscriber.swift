import AVFoundation
import Foundation
import Speech

/// Kullanıcının kendi sözünü ANINDA (optimistic) gösteren on-device SFSpeech
/// tanıyıcı. Brain STT'si (`lk.transcription`) geç döndüğü için, kullanıcı
/// konuşurken partial sonuçları lokal bir "user" balonu olarak hemen gösterir;
/// brain'in kesin `.userTranscript`'i gelince ``reconcile()`` ile temizlenir
/// (gerçek balon zaten session.messages'ta → duplicate olmaz).
///
/// ``WakeWordDetector`` ile AYNI desende ama kendi `request`'i var; ikisi de
/// ``WakeCoordinator``'ın TEK PCM renderer'ından beslenir. Mod bazlı çalışırlar:
/// wake YALNIZ sleeping, echo YALNIZ awake/continuous → asla aynı anda aktif
/// değiller, SFSpeech çakışması olmaz. Aktif olmayanın `request`'i nil → appendPCM
/// sessiz no-op. Yeni AVAudioEngine AÇILMAZ (CoreAudio overload riski yok).
@MainActor
final class LocalEchoTranscriber: NSObject, ObservableObject {
    /// Kullanıcının o anki (kesinleşmemiş) sözü; boş = gösterilecek bir şey yok.
    @Published private(set) var provisional: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var rotationTimer: DispatchSourceTimer?
    private var running = false

    private nonisolated(unsafe) var request: SFSpeechAudioBufferRecognitionRequest?
    private nonisolated let requestLock = NSLock()

    /// LiveKit yerel mic PCM tamponunu aktif isteğe ekler (ses render thread'i).
    /// Aktif istek yoksa (uyku/teardown) sessiz no-op.
    nonisolated func appendPCM(_ buffer: AVAudioPCMBuffer) {
        requestLock.lock(); defer { requestLock.unlock() }
        request?.append(buffer)
    }

    func start(language: String) {
        guard !running else { return }
        Task { [weak self] in
            guard let self else { return }
            let ok = await Self.requestPermission()
            guard ok, !self.running else { return }
            let localeId = language.contains("-") ? language : (language.lowercased() == "tr" ? "tr-TR" : language)
            guard let rec = SFSpeechRecognizer(locale: Locale(identifier: localeId)), rec.isAvailable else {
                Log.error("[Echo] recognizer mevcut değil: \(localeId)")
                return
            }
            self.recognizer = rec
            self.running = true
            self.startRecognition()
            self.scheduleRotation()
            Log.line("[Echo] başladı locale=\(localeId) onDevice=\(rec.supportsOnDeviceRecognition)")
        }
    }

    func stop() {
        rotationTimer?.cancel(); rotationTimer = nil
        endRecognition()
        running = false
        provisional = ""
    }

    /// Brain kesin transkripti geldi → optimistic satırı temizle ve tanımayı taze
    /// başlat (biriken ses bir sonraki cümleye sızmasın). Çalışmıyorsa sadece temizle.
    func reconcile() {
        provisional = ""
        guard running else { return }
        endRecognition()
        startRecognition()
    }

    private func startRecognition() {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            req.requiresOnDeviceRecognition = true
        }
        requestLock.lock(); request = req; requestLock.unlock()

        let handler: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self?.provisional = text }
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
        timer.schedule(deadline: .now() + 50, repeating: 50) // Apple ~1dk limiti dolmadan
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self, self.running else { return }
                // Yalnız isteği/task'ı yenile; provisional'ı koru (yeni partials gelene dek).
                self.endRecognition()
                self.startRecognition()
            }
        }
        timer.resume()
        rotationTimer = timer
    }

    nonisolated static func requestPermission() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}
