import Combine
import Foundation

/// Kullanıcı ayarları; UserDefaults'a kalıcı yazılır.
///
/// Eski WebSocket-bridge ayarları (bridge URL/token, cihaz TTS, gürültü
/// filtresi vb.) bilinçli olarak çıkarıldı: LiveKit sunucu URL'i/token'ı
/// `Secrets.swift` içinde. Buradaki `stt_engine` / `voice` / `language`
/// agent'e LiveKit participant attribute'ları olarak gönderilir; geri kalanı
/// (wake word, cue sesleri, barge-in) istemci-yerel davranışlardır.
@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    // MARK: - Agent'e gönderilen (LiveKit attributes)

    /// Yanıt dili. Agent attribute key: `language`.
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// TTS ses adı. Agent attribute key: `voice`.
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    /// Sunucu STT motoru (whisper/nemotron). Agent attribute key: `stt_engine`.
    @Published var sttEngine: String { didSet { defaults.set(sttEngine, forKey: "sttEngine") } }

    // MARK: - İstemci-yerel davranışlar

    @Published var wakeWordEnabled: Bool { didSet { defaults.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }
    @Published var wakeWord: String { didSet { defaults.set(wakeWord, forKey: "wakeWord") } }
    @Published var cuesEnabled: Bool { didSet { defaults.set(cuesEnabled, forKey: "cuesEnabled") } }
    @Published var bargeInEnabled: Bool { didSet { defaults.set(bargeInEnabled, forKey: "bargeInEnabled") } }

    // MARK: - Sunucu / bağlantı URL'leri (kullanıcı değiştirebilir)

    /// LiveKit sunucu URL'i. Boşsa default'a (Secrets) düşülür → bkz. resolvedLivekitURL.
    @Published var livekitURL: String { didSet { defaults.set(livekitURL, forKey: Self.livekitURLKey) } }

    // MARK: - Hermes mate_voice token endpoint'i (modüler)

    /// Hermes mate_voice token endpoint TABAN URL'i (örn. `https://mate-hermes.drascom.uk`).
    /// İstek: `GET {url}/mate/token?identity=<id>&room=<opsiyonel>` + `X-Mate-Key`.
    @Published var tokenEndpointURL: String { didSet { defaults.set(tokenEndpointURL, forKey: Self.tokenEndpointURLKey) } }
    /// Hermes endpoint'i için istemci anahtarı → `X-Mate-Key` header.
    @Published var clientKey: String { didSet { defaults.set(clientKey, forKey: Self.clientKeyKey) } }
    /// Opsiyonel oda adı override'ı (boşsa endpoint'in döndürdüğü oda kullanılır).
    @Published var room: String { didSet { defaults.set(room, forKey: Self.roomKey) } }

    static let livekitURLKey = "livekitURL"
    static let tokenEndpointURLKey = "tokenEndpointURL"
    static let clientKeyKey = "clientKey"
    static let roomKey = "mateRoom"
    static let defaultLivekitURL = Secrets.livekitServerURL
    /// Onboarding sihirbazında prefill edilen varsayılan Hermes token endpoint'i.
    static let defaultTokenEndpointURL = "https://mate-token.drascom.uk"

    /// Bağlantı için kullanılacak LiveKit URL'i — boşsa default. (TokenSource bunu
    /// her bağlanışta UserDefaults'tan okur; @MainActor store gerekmeden.)
    static var resolvedLivekitURL: String {
        let v = (UserDefaults.standard.string(forKey: livekitURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? defaultLivekitURL : v
    }

    /// Hermes token endpoint taban URL'i (trailing slash temizlenir). Boş olabilir.
    static var resolvedTokenEndpointURL: String {
        var v = (UserDefaults.standard.string(forKey: tokenEndpointURLKey) ?? "").trimmingCharacters(in: .whitespaces)
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    /// Hermes istemci anahtarı (`X-Mate-Key`). Boş olabilir.
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
        tokenEndpointURL = defaults.string(forKey: Self.tokenEndpointURLKey) ?? ""
        clientKey = defaults.string(forKey: Self.clientKeyKey) ?? ""
        room = defaults.string(forKey: Self.roomKey) ?? ""
    }

    /// Agent'in beklediği participant attribute sözlüğü.
    /// Anahtarlar agent tarafıyla birebir eşleşmeli: `stt_engine`, `voice`, `language`.
    var agentAttributes: [String: String] {
        [
            "stt_engine": sttEngine,
            "voice": voice,
            "language": language,
            "mate.barge_in": bargeInEnabled ? "1" : "0",
        ]
    }
}
