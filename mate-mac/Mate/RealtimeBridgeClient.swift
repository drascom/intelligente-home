import Foundation
import AVFoundation

/// Mate Realtime Bridge Protocol v0 (TTS-only) istemcisi.
/// Bkz: BRIDGE_PROTOCOL.md
///
/// - Telefon `speak`/`cancel`/`ping` (text/JSON) gönderir.
/// - Sunucu `audio_start` (JSON) → ham pcm_f32le binary parçalar → `audio_end` (JSON) yollar.
/// - Bu sınıf binary parçaları `audio_start`'taki sample_rate ile `AVAudioPCMBuffer`
///   (`.pcmFormatFloat32`, mono) haline çevirip callback ile yukarı verir.
///
/// STT CİHAZDA yapılır; bu kanaldan YUKARI SES GİTMEZ — sadece metin.
@MainActor
final class RealtimeBridgeClient: NSObject {

    enum BridgeError: LocalizedError {
        case badURL
        case notConnected
        case bufferAllocFailed
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL: return "Geçersiz bridge WS URL"
            case .notConnected: return "Bridge bağlı değil"
            case .bufferAllocFailed: return "PCM buffer ayrılamadı"
            case .server(let m): return "Bridge hatası: \(m)"
            }
        }
    }

    /// Sunucu→istemci olayları. Tümü @MainActor üzerinde çağrılır.
    /// Sunucu STT sonucu (brain `transcript` mesajı) — ses-yukarı modunda.
    var onTranscript: ((_ id: String, _ text: String) -> Void)?
    /// Asistan cevap METNİ (brain `reply` mesajı) — sohbet feed'i için.
    var onReply: ((_ id: String, _ text: String) -> Void)?
    var onAudioStart: ((_ id: String, _ sampleRate: Double, _ channels: Int) -> Void)?
    var onAudioChunk: ((_ id: String, _ buffer: AVAudioPCMBuffer) -> Void)?
    var onAudioEnd: ((_ id: String) -> Void)?
    var onError: ((_ id: String?, _ message: String) -> Void)?
    /// Proaktif hatırlatma sinyali (brain `chime` mesajı): bekleyen hatırlatma var,
    /// kısa ton çal. İçerik teslimi bir sonraki turda ("candan" dedikten sonra) gelir.
    var onChime: (() -> Void)?
    var onClose: ((_ reason: String) -> Void)?
    /// Sunucuya gerçekten ulaşıldı mı (pong/mesaj geldi → true; kopma/timeout → false).
    /// UI'da "Sunucu bağlantısı yok" banner'ı için.
    var onReachable: ((_ reachable: Bool) -> Void)?

    private(set) var isConnected = false

    private var task: URLSessionWebSocketTask?
    private let session: URLSession

    // audio_start ile gelen aktif format (binary parçaları çevirmek için).
    private var activeId: String?
    private var activeFormat: AVAudioFormat?
    // Boşta bağlantı düşmesin diye periyodik ping (keepalive).
    private var keepAliveTask: Task<Void, Never>?
    // Kalıcı oturum: bağlı olduğumuz adres + oturumun açık kalması isteniyor mu.
    private var currentURL: URL?
    private var shouldStayConnected = false
    // Sunucudan ilk mesaj/pong geldi mi (gerçek erişilebilirlik onayı).
    private var confirmedReachable = false

    override init() {
        let cfg = URLSessionConfiguration.default
        // Ulaşılamayan bridge'de hızlı fallback: el sıkışma 8 sn'de olmazsa başarısız
        // (eskiden 30 sn asılıp cihaz TTS'e geç düşüyordu). waitsForConnectivity kapalı →
        // host yoksa beklemeden hata ver.
        cfg.timeoutIntervalForRequest = 8
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - Connection

    /// `urlString` ör: `ws://192.168.0.183:8643/ws` veya `wss://...`.
    /// `token` verilirse `?token=...` query'sine eklenir (VOX_API_KEY ile eşleşmeli).
    func connect(urlString: String, token: String = "") throws {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            throw BridgeError.badURL
        }
        if !token.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
        }
        guard let url = components.url else { throw BridgeError.badURL }

        // Zaten aynı adrese bağlıysak yeni oturum AÇMA — her konuşmada reconnect olmasın.
        if isConnected, currentURL == url { return }
        currentURL = url
        shouldStayConnected = true
        openConnection(url)
    }

    private func openConnection(_ url: URL) {
        task?.cancel(with: .goingAway, reason: "reconnect".data(using: .utf8))
        let task = session.webSocketTask(with: url)
        self.task = task
        isConnected = true
        confirmedReachable = false
        task.resume()
        receiveLoop()
        startKeepAlive()
        // Erken ping → pong gelince erişilebilirlik hızlı onaylanır (banner kalkar).
        Task { [weak self] in try? await self?.ping() }
        print("[Bridge] connecting: \(url.absoluteString)")
    }

    func disconnect(reason: String = "client") {
        shouldStayConnected = false          // kasıtlı kapatma → otomatik yeniden bağlanma yok
        confirmedReachable = false
        onReachable?(false)
        keepAliveTask?.cancel()
        keepAliveTask = nil
        guard task != nil else { return }
        task?.cancel(with: .goingAway, reason: reason.data(using: .utf8))
        task = nil
        isConnected = false
        activeId = nil
        activeFormat = nil
    }

    /// Boşta bağlantı düşmesini önlemek için her 10 sn'de bir ping gönder.
    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, self.isConnected else { break }
                try? await self.ping()
            }
        }
    }

    /// Beklenmedik kopmada oturumu canlı tut: kısa gecikmeyle yeniden bağlan.
    /// (Kasıtlı disconnect'te shouldStayConnected=false olduğu için tetiklenmez.)
    private func scheduleReconnect(_ url: URL) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, self.shouldStayConnected, !self.isConnected else { return }
            print("[Bridge] beklenmedik kopma → yeniden bağlanılıyor")
            self.openConnection(url)
        }
    }

    // MARK: - Client → Server

    /// Kullanıcı metnini brain'e yolla. wantAudio=false → yalnız `reply` metni
    /// döner (cihaz TTS modu); true → reply + TTS sesi. id döner.
    @discardableResult
    func speak(text: String, voice: String?, wantAudio: Bool = true) async throws -> String {
        let id = UUID().uuidString
        var payload: [String: Any] = [
            "type": "speak", "id": id, "text": text, "want_audio": wantAudio,
        ]
        if let voice, !voice.isEmpty {
            // voice "ayhan.mp3" gibi gelebilir; protokol "ayhan" bekler.
            payload["voice"] = Self.normalizeVoice(voice)
        }
        try await sendJSON(payload)
        return id
    }

    /// Ses-yukarı utterance: kayıt PCM'ini (s16le mono) brain'e yolla; sunucu
    /// Whisper'ı çözer, `transcript` + `reply` + TTS sesi döner. id döner.
    @discardableResult
    func sendUtterance(pcm: Data, rate: Int = 16000, voice: String?) async throws -> String {
        guard let task, isConnected else { throw BridgeError.notConnected }
        let id = UUID().uuidString
        var start: [String: Any] = [
            "type": "audio_start", "id": id,
            "rate": rate, "width": 2, "channels": 1,
        ]
        if let voice, !voice.isEmpty {
            start["voice"] = Self.normalizeVoice(voice)
        }
        try await sendJSON(start)
        let chunkSize = 32 * 1024
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + chunkSize, pcm.count)
            try await task.send(.data(pcm.subdata(in: offset..<end)))
            offset = end
        }
        try await sendJSON(["type": "audio_stop", "id": id])
        return id
    }

    /// Barge-in: verilen id'nin üretimini durdur.
    func cancel(id: String) async throws {
        try await sendJSON(["type": "cancel", "id": id])
    }

    func ping() async throws {
        try await sendJSON(["type": "ping"])
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let task, isConnected else { throw BridgeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
    }

    private static func normalizeVoice(_ voice: String) -> String {
        var v = voice
        for ext in [".wav", ".mp3", ".m4a"] where v.lowercased().hasSuffix(ext) {
            v = String(v.dropLast(ext.count))
        }
        return v
    }

    // MARK: - Server → Client

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                // Yalnız GÜNCEL task'ın callback'ini işle — superseded (yeniden bağlanma
                // sırasında iptal edilen) eski soketin callback'i yeni oturumu bozmasın.
                guard let self, self.task === task else { return }
                switch result {
                case .failure(let error):
                    self.isConnected = false
                    self.confirmedReachable = false
                    self.onReachable?(false)
                    print("[Bridge] receive error: \(error.localizedDescription)")
                    self.onClose?(error.localizedDescription)
                    if self.shouldStayConnected, let url = self.currentURL {
                        self.scheduleReconnect(url)
                    }
                case .success(let message):
                    if !self.confirmedReachable {
                        self.confirmedReachable = true
                        self.onReachable?(true)   // ilk mesaj/pong → sunucu erişilebilir
                    }
                    self.handle(message: message)
                    // Bir sonraki frame'i dinlemeye devam et.
                    if self.isConnected { self.receiveLoop() }
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleText(text)
        case .data(let data):
            handleBinary(data)
        @unknown default:
            break
        }
    }

    private func handleText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            print("[Bridge] unparseable text frame")
            return
        }
        let id = obj["id"] as? String
        switch type {
        case "transcript":
            let text = (obj["text"] as? String) ?? ""
            print("[Bridge] transcript id=\(id ?? "?") \(text.prefix(60))")
            onTranscript?(id ?? "", text)
        case "reply":
            let text = (obj["text"] as? String) ?? ""
            print("[Bridge] reply id=\(id ?? "?") \(text.prefix(60))")
            onReply?(id ?? "", text)
        case "audio_start":
            let sr = (obj["sample_rate"] as? Double) ?? (obj["sample_rate"] as? Int).map(Double.init) ?? 48000
            let channels = (obj["channels"] as? Int) ?? 1
            activeId = id
            activeFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sr,
                channels: AVAudioChannelCount(max(1, channels)),
                interleaved: false
            )
            print("[Bridge] audio_start id=\(id ?? "?") sr=\(Int(sr)) ch=\(channels)")
            onAudioStart?(id ?? "", sr, channels)
        case "audio_end":
            print("[Bridge] audio_end id=\(id ?? "?")")
            onAudioEnd?(id ?? "")
            if id == activeId {
                activeId = nil
                activeFormat = nil
            }
        case "error":
            let msg = (obj["message"] as? String) ?? "bilinmeyen hata"
            print("[Bridge] error id=\(id ?? "?"): \(msg)")
            onError?(id, msg)
        case "chime":
            print("[Bridge] chime (proaktif hatırlatma sinyali)")
            onChime?()
        case "pong":
            break
        default:
            print("[Bridge] unknown text type: \(type)")
        }
    }

    private func handleBinary(_ data: Data) {
        guard let format = activeFormat else {
            print("[Bridge] binary frame ama aktif format yok (audio_start gelmedi) — atlanıyor")
            return
        }
        guard let buffer = Self.pcmBuffer(from: data, format: format) else {
            print("[Bridge] pcm_f32le → buffer dönüşümü başarısız")
            return
        }
        onAudioChunk?(activeId ?? "", buffer)
    }

    /// Ham little-endian float32 mono byte'ları AVAudioPCMBuffer'a (deinterleaved
    /// float32) yazar. Protokol mono garanti ediyor ama channelCount > 1 için de
    /// güvenli deinterleave yapar.
    static func pcmBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let bytesPerSample = MemoryLayout<Float>.size  // 4
        let channels = Int(format.channelCount)
        guard channels > 0 else { return nil }
        let totalSamples = data.count / bytesPerSample
        let frames = totalSamples / channels
        guard frames > 0 else { return nil }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        ), let channelData = buffer.floatChannelData else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frames)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            // Little-endian float32; iOS de little-endian → doğrudan kopyalanabilir.
            let src = raw.bindMemory(to: Float.self)
            if channels == 1 {
                channelData[0].update(from: src.baseAddress!, count: frames)
            } else {
                for frame in 0..<frames {
                    for ch in 0..<channels {
                        channelData[ch][frame] = src[frame * channels + ch]
                    }
                }
            }
        }
        return buffer
    }
}
