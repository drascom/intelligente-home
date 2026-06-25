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

    init() {
        language = defaults.string(forKey: "language") ?? "tr"
        voice = defaults.string(forKey: "voice") ?? "nese"
        sttEngine = defaults.string(forKey: "sttEngine") ?? "whisper"
        wakeWordEnabled = defaults.object(forKey: "wakeWordEnabled") as? Bool ?? true
        wakeWord = defaults.string(forKey: "wakeWord") ?? "candan"
        cuesEnabled = defaults.object(forKey: "cuesEnabled") as? Bool ?? true
        bargeInEnabled = defaults.object(forKey: "bargeInEnabled") as? Bool ?? true
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
