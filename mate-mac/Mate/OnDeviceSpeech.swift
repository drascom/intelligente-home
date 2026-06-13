import Foundation
import AVFoundation
import Speech

enum OnDeviceSpeechError: LocalizedError {
    case recognizerUnavailable(String)
    case synthesizerFailed
    case bufferAllocFailed
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable(let loc): return "Cihazda STT mevcut değil: \(loc)"
        case .synthesizerFailed: return "Cihaz TTS başarısız"
        case .bufferAllocFailed: return "PCM buffer ayrılamadı"
        case .emptyTranscript: return "Boş transkript"
        }
    }
}

enum OnDeviceSTT {
    // Recognizer'ı locale başına SAKLA: her çağrıda yeniden yaratmak on-device modeli
    // tekrar tekrar yükleyip throttle'a sokuyor (ardışık boş sonuçların sebebi). Reuse et.
    private static var cachedRecognizers: [String: SFSpeechRecognizer] = [:]
    private static var activeTask: SFSpeechRecognitionTask?

    /// YEDEK cihaz-içi STT: Apple SFSpeech. Birincil STT artık SUNUCUDA
    /// (brain → faster-whisper); bu yol yalnız sunucuya ulaşılamadığında kullanılır.
    static func transcribe(audioURL: URL, language: String) async throws -> String {
        // TANI: yakalanan dosyanın süresi — boş STT'nin sebebi capture (kısa/sessiz
        // dosya) mı yoksa recognition mı, ayırt etmek için.
        if let f = try? AVAudioFile(forReading: audioURL) {
            let sr = f.fileFormat.sampleRate
            let dur = sr > 0 ? Double(f.length) / sr : 0
            print(String(format: "[STT] file dur=%.2fs frames=%lld", dur, f.length))
        } else {
            print("[STT] file AÇILAMADI: \(audioURL.lastPathComponent)")
        }
        return try await transcribeSFSpeech(audioURL: audioURL, language: language)
    }

    /// SFSpeech yolu (cihaz-içi yedek).
    private static func transcribeSFSpeech(audioURL: URL, language: String) async throws -> String {
        let localeId = language.contains("-")
            ? language
            : (language.lowercased() == "tr" ? "tr-TR" : language)
        let recognizer: SFSpeechRecognizer
        if let cached = cachedRecognizers[localeId] {
            recognizer = cached
        } else {
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeId)) else {
                throw OnDeviceSpeechError.recognizerUnavailable(localeId)
            }
            cachedRecognizers[localeId] = r
            recognizer = r
        }
        guard recognizer.isAvailable else {
            throw OnDeviceSpeechError.recognizerUnavailable(localeId)
        }
        // Önceki tanıma görevini iptal et — on-device kaynağı meşgul kalmasın.
        activeTask?.cancel()
        activeTask = nil
        print("[STT] engine=sfspeech onDevice=\(recognizer.supportsOnDeviceRecognition ? "yes" : "no")")

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }
                if let error {
                    print("[STT] recognition ERROR: \(error.localizedDescription)")
                    resumed = true
                    Self.activeTask = nil
                    cont.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                Self.activeTask = nil
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                print("[STT] engine=sfspeech final empty=\(text.isEmpty)")
                cont.resume(returning: text)
            }
            Self.activeTask = task
        }
    }
}

/// CANLI (streaming) cihaz-içi STT. Mic buffer'ları konuşma sürerken
/// `SFSpeechAudioBufferRecognitionRequest`'e beslenir; partial sonuçlar
/// sürekli güncellenir. VAD turu kapanınca `finishText()` o ana kadarki en
/// güncel transcript'i (veya kısa bir timeout ile final'i) döndürür → uzun
/// konuşmalarda batch transcribe gecikmesi ~sıfıra iner.
/// OnDeviceSTT.transcribe yedek olarak korunur.
final class LiveSTT: @unchecked Sendable {
    private let lock = NSLock()
    // lock altında: tap (audio thread) append'i ve start/finish/cancel'in
    // request reset'i yarışmasın.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestText: String = ""
    private var receivedFinal = false
    private var isActive = false

    /// Tanımayı başlat. tr-TR locale mantığı OnDeviceSTT ile aynı.
    func start(language: String) {
        // Önceki oturum sızmasın.
        cancel()

        let localeId = language.contains("-")
            ? language
            : (language.lowercased() == "tr" ? "tr-TR" : language)
        let locale = Locale(identifier: localeId)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            print("[LiveSTT] recognizer unavailable for \(localeId)")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        lock.lock()
        self.recognizer = recognizer
        self.request = request
        self.latestText = ""
        self.receivedFinal = false
        self.isActive = true
        lock.unlock()

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Sonuç handler arbitrary bir queue'da çağrılabilir → @Published/UI
            // güncellemesi yok; sadece lock altında saklanan state güncelleniyor.
            guard let self else { return }
            self.lock.lock()
            if self.isActive {
                if let result {
                    self.latestText = result.bestTranscription.formattedString
                    if result.isFinal { self.receivedFinal = true }
                }
                // Hata: o ana kadarki partial korunsun, final beklenmesin.
                if error != nil { self.receivedFinal = true }
            }
            self.lock.unlock()
        }
        lock.lock()
        self.task = task
        lock.unlock()
        print("[LiveSTT] started locale=\(localeId) onDevice=\(recognizer.supportsOnDeviceRecognition)")
    }

    /// Mic buffer'ı tanımaya besle. Tap callback'inden (audio thread) çağrılabilir;
    /// SFSpeechAudioBufferRecognitionRequest.append thread-safe; lock yalnızca
    /// request referansını start/cancel ile yarıştırmamak için.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = isActive ? self.request : nil
        lock.unlock()
        request?.append(buffer)
    }

    /// Audio'yu bitir, final sonucu ~1.5s'ye kadar bekle; gelmezse o ana kadarki
    /// en güncel partial'ı döndür. Sonra oturumu temizle.
    func finishText() async -> String {
        lock.lock()
        let active = isActive
        let request = self.request
        lock.unlock()
        guard active else { return "" }
        request?.endAudio()

        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            lock.lock()
            let done = receivedFinal
            lock.unlock()
            if done { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        lock.lock()
        let text = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanupLocked()
        lock.unlock()
        return text
    }

    /// Tanımayı iptal et, saklanan metni sıfırla (barge-in / discard / no-speech).
    func cancel() {
        lock.lock()
        let task = self.task
        cleanupLocked()
        lock.unlock()
        task?.cancel()
    }

    private func cleanupLocked() {
        isActive = false
        task = nil
        request = nil
        recognizer = nil
        latestText = ""
        receivedFinal = false
    }
}

/// AVSpeechSynthesizer'ı PCM buffer'a render eder. Synthesizer kalıcı tutulur —
/// `write(...)` async callback'leri çağırırken referans kaybolursa iOS crash atar.
@MainActor
final class OnDeviceTTS {
    static let shared = OnDeviceTTS()
    private let synthesizer = AVSpeechSynthesizer()
    private var inFlight = false

    struct VoiceOption: Identifiable, Hashable {
        let id: String          // AVSpeechSynthesisVoice.identifier
        let displayName: String
        let language: String
    }

    /// speechVoices() thread-safe ama İLK çağrısı yavaş (sistem ses kataloğu,
    /// bloklayan XPC) → main thread'i kilitlememek için GCD kuyruğunda çağrılır.
    /// Swift Concurrency havuzunda (Task.detached) çağırmak "unsafeForcedSync
    /// called from Swift Concurrent context" uyarısı üretiyor — cooperative
    /// thread bloklanamaz; o yüzden continuation + global queue.
    nonisolated static func availableVoices(language: String) async -> [VoiceOption] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: listVoices(language: language))
            }
        }
    }

    nonisolated private static func listVoices(language: String) -> [VoiceOption] {
        let localeId = language.contains("-")
            ? language
            : (language.lowercased() == "tr" ? "tr-TR" : language)
        let prefix = String(localeId.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix) }
            .map { v in
                let q: String
                switch v.quality {
                case .premium: q = "Premium"
                case .enhanced: q = "Enhanced"
                default: q = "Default"
                }
                return VoiceOption(
                    id: v.identifier,
                    displayName: "\(v.name) (\(q)) — \(v.language)",
                    language: v.language
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    func synthesize(text: String, language: String, voiceId: String) async throws -> AVAudioPCMBuffer {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnDeviceSpeechError.emptyTranscript }

        // Aynı anda iki write çalıştırma — AVSpeechSynthesizer tek queue'ya sahip.
        while inFlight {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        inFlight = true
        defer { inFlight = false }

        let utterance = AVSpeechUtterance(string: trimmed)
        if !voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceId) {
            utterance.voice = v
        } else {
            let localeId = language.contains("-")
                ? language
                : (language.lowercased() == "tr" ? "tr-TR" : language)
            utterance.voice = AVSpeechSynthesisVoice(language: localeId)
        }

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            var collected: [AVAudioPCMBuffer] = []
            var detectedFormat: AVAudioFormat?

            synthesizer.write(utterance) { buffer in
                if resumed { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else {
                    resumed = true
                    cont.resume(throwing: OnDeviceSpeechError.synthesizerFailed)
                    return
                }
                if pcm.frameLength == 0 {
                    // Bitti — chunk'ları birleştir.
                    guard let fmt = detectedFormat else {
                        resumed = true
                        cont.resume(throwing: OnDeviceSpeechError.synthesizerFailed)
                        return
                    }
                    let total = collected.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
                    guard total > 0,
                          let combined = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total) else {
                        resumed = true
                        cont.resume(throwing: OnDeviceSpeechError.bufferAllocFailed)
                        return
                    }
                    var offset: AVAudioFrameCount = 0
                    let channels = Int(fmt.channelCount)
                    for chunk in collected {
                        let n = Int(chunk.frameLength)
                        if let src = chunk.floatChannelData, let dst = combined.floatChannelData {
                            for ch in 0..<channels {
                                dst[ch].advanced(by: Int(offset)).update(from: src[ch], count: n)
                            }
                        } else if let src = chunk.int16ChannelData, let dst = combined.int16ChannelData {
                            for ch in 0..<channels {
                                dst[ch].advanced(by: Int(offset)).update(from: src[ch], count: n)
                            }
                        }
                        offset += chunk.frameLength
                    }
                    combined.frameLength = total
                    resumed = true
                    cont.resume(returning: combined)
                    return
                }
                if detectedFormat == nil { detectedFormat = pcm.format }
                // Buffer hayatta kalsın diye kopyala — write() reuse edebiliyor.
                if let copy = Self.copyBuffer(pcm) {
                    collected.append(copy)
                }
            }
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
        } else {
            return nil
        }
        return copy
    }
}
