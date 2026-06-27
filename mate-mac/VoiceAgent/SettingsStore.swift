import Combine
import Foundation

/// Kullanıcı ayarları; UserDefaults'a kalıcı yazılır.
///
/// Eski WebSocket-bridge ayarları (bridge URL/token, cihaz TTS, gürültü
/// filtresi vb.) bilinçli olarak çıkarıldı: LiveKit sunucu URL'i/token'ı
/// `Secrets.swift` içinde. Buradaki `stt_engine` / `voice` / `language`
/// brain'e LiveKit participant attribute'ları olarak gönderilir; geri kalanı
/// (wake word, cue sesleri, barge-in) istemci-yerel davranışlardır.
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: - Brain'e gönderilen (LiveKit attributes)

    /// Yanıt dili. Brain attribute key: `language`.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// TTS ses adı. Brain attribute key: `voice`.
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    /// Sunucu STT motoru (whisper/nemotron). Brain attribute key: `stt_engine`.
    @Published var sttEngine: String { didSet { defaults.set(sttEngine, forKey: "sttEngine") } }

    // MARK: - İstemci-yerel davranışlar

    @Published var wakeWordEnabled: Bool { didSet { defaults.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }
    @Published var wakeWord: String { didSet { defaults.set(wakeWord, forKey: "wakeWord") } }
    @Published var cuesEnabled: Bool { didSet { defaults.set(cuesEnabled, forKey: "cuesEnabled") } }
    @Published var bargeInEnabled: Bool { didSet { defaults.set(bargeInEnabled, forKey: "bargeInEnabled") } }

    // MARK: - Sunucu / bağlantı URL'leri (kullanıcı değiştirebilir)

    /// LiveKit sunucu URL'i. Boşsa default'a (Secrets) düşülür → bkz. resolvedLivekitURL.
    @Published var livekitURL: String { didSet { defaults.set(livekitURL, forKey: Self.livekitURLKey) } }
    /// Brain URL'i — `{brainURL}/api/livekit-token` ile TAZE LiveKit token çekilir.
    @Published var brainURL: String { didSet { defaults.set(brainURL, forKey: Self.brainURLKey) } }
    /// Brain API token'ı (Bearer). Boşsa → statik Secrets token'a düşülür.
    @Published var brainToken: String { didSet { defaults.set(brainToken, forKey: Self.brainTokenKey) } }

    // MARK: - Bağlantı modu + Hermes candan_voice token endpoint'i (modüler)

    /// Bağlantı modu: `"hermes"` (candan_voice plugin token endpoint) veya
    /// `"brain"` (eski device-register/brain endpoint). Başkaları kendi Hermes
    /// deploy'larına bağlanabilsin diye endpoint+key Settings'ten gelir (hardcode YOK).
    @Published var connectionMode: String { didSet { defaults.set(connectionMode, forKey: Self.connectionModeKey) } }
    /// Hermes candan_voice token endpoint TABAN URL'i (örn. `https://mate-hermes.drascom.uk`).
    /// İstek: `GET {url}/candan/token?identity=<id>&room=<opsiyonel>` + `X-Candan-Key`.
    @Published var tokenEndpointURL: String { didSet { defaults.set(tokenEndpointURL, forKey: Self.tokenEndpointURLKey) } }
    /// Hermes endpoint'i için istemci anahtarı → `X-Candan-Key` header.
    @Published var clientKey: String { didSet { defaults.set(clientKey, forKey: Self.clientKeyKey) } }
    /// Opsiyonel oda adı override'ı (boşsa endpoint'in döndürdüğü oda kullanılır).
    @Published var room: String { didSet { defaults.set(room, forKey: Self.roomKey) } }

    static let livekitURLKey = "livekitURL"
    static let brainURLKey = "brainURL"
    static let brainTokenKey = "brainToken"
    static let connectionModeKey = "connectionMode"
    static let tokenEndpointURLKey = "tokenEndpointURL"
    static let clientKeyKey = "clientKey"
    static let roomKey = "candanRoom"
    static let defaultLivekitURL = Secrets.livekitServerURL
    static let defaultBrainURL = "https://mate-brain.drascom.uk"

    /// Bağlantı için kullanılacak LiveKit URL'i — boşsa default. (TokenSource bunu
    /// her bağlanışta UserDefaults'tan okur; @MainActor store gerekmeden.)
    static var resolvedLivekitURL: String {
        let v = (UserDefaults.standard.string(forKey: livekitURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? defaultLivekitURL : v
    }

    /// Token çekmek için brain URL'i — boşsa default.
    static var resolvedBrainURL: String {
        let v = (UserDefaults.standard.string(forKey: brainURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? defaultBrainURL : v
    }

    /// Brain API token'ı — boş olabilir (o zaman statik token'a düşülür).
    static var resolvedBrainToken: String {
        (UserDefaults.standard.string(forKey: brainTokenKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Bağlantı modu — boşsa varsayılan `hermes` (candan_voice plugin).
    static var resolvedConnectionMode: String {
        let v = (UserDefaults.standard.string(forKey: connectionModeKey) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "hermes" : v
    }

    /// Hermes token endpoint taban URL'i (trailing slash temizlenir). Boş olabilir.
    static var resolvedTokenEndpointURL: String {
        var v = (UserDefaults.standard.string(forKey: tokenEndpointURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    /// Hermes istemci anahtarı (`X-Candan-Key`). Boş olabilir.
    static var resolvedClientKey: String {
        (UserDefaults.standard.string(forKey: clientKeyKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// Opsiyonel oda override'ı. Boş olabilir.
    static var resolvedRoom: String {
        (UserDefaults.standard.string(forKey: roomKey) ?? "").trimmingCharacters(in: .whitespaces)
    }

    init() {
        language = defaults.string(forKey: "language") ?? "tr"
        voice = defaults.string(forKey: "voice") ?? "nese"
        sttEngine = defaults.string(forKey: "sttEngine") ?? "whisper"
        wakeWordEnabled = defaults.object(forKey: "wakeWordEnabled") as? Bool ?? true
        wakeWord = defaults.string(forKey: "wakeWord") ?? "candan"
        cuesEnabled = defaults.object(forKey: "cuesEnabled") as? Bool ?? true
        bargeInEnabled = defaults.object(forKey: "bargeInEnabled") as? Bool ?? true
        livekitURL = defaults.string(forKey: Self.livekitURLKey) ?? Self.defaultLivekitURL
        brainURL = defaults.string(forKey: Self.brainURLKey) ?? Self.defaultBrainURL
        brainToken = defaults.string(forKey: Self.brainTokenKey) ?? ""
        connectionMode = defaults.string(forKey: Self.connectionModeKey) ?? "hermes"
        tokenEndpointURL = defaults.string(forKey: Self.tokenEndpointURLKey) ?? ""
        clientKey = defaults.string(forKey: Self.clientKeyKey) ?? ""
        room = defaults.string(forKey: Self.roomKey) ?? ""
    }

    /// Brain'in beklediği participant attribute sözlüğü.
    /// Anahtarlar brain tarafıyla birebir eşleşmeli: `stt_engine`, `voice`, `language`.
    var brainAttributes: [String: String] {
        [
            "stt_engine": sttEngine,
            "voice": voice,
            "language": language,
            "candan.barge_in": bargeInEnabled ? "1" : "0",
        ]
    }
}
