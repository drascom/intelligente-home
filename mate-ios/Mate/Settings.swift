import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var bridgeApiKey: String { didSet { defaults.set(bridgeApiKey, forKey: "bridgeApiKey") } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var wakeWordEnabled: Bool { didSet { defaults.set(wakeWordEnabled, forKey: "wakeWordEnabled") } }
    @Published var wakeWord: String { didSet { defaults.set(wakeWord, forKey: "wakeWord") } }
    @Published var cuesEnabled: Bool { didSet { defaults.set(cuesEnabled, forKey: "cuesEnabled") } }
    @Published var noiseFilterEnabled: Bool { didSet { defaults.set(noiseFilterEnabled, forKey: "noiseFilterEnabled") } }
    @Published var bargeInEnabled: Bool { didSet { defaults.set(bargeInEnabled, forKey: "bargeInEnabled") } }
    // Cihaz TTS yedek/override: açıkken bridge atlanır, doğrudan AVSpeechSynthesizer kullanılır.
    @Published var useOnDeviceTTS: Bool { didSet { defaults.set(useOnDeviceTTS, forKey: "useOnDeviceTTS") } }
    @Published var onDeviceVoiceId: String { didSet { defaults.set(onDeviceVoiceId, forKey: "onDeviceVoiceId") } }
    // Realtime bridge (WebSocket): kayıt PCM'i brain'e gider (sunucu STT),
    // cevap metni + pcm_f32le ses parçaları gerçek zamanlı döner.
    @Published var bridgeWSURL: String { didSet { defaults.set(bridgeWSURL, forKey: "bridgeWSURL") } }
    // macOS ana ekranındaki mikrofon/hoparlör seçimi (cihaz UID; "" = sistem
    // varsayılanı). iOS'ta kullanılmaz — route'u AVAudioSession yönetir.
    @Published var macInputDeviceUID: String { didSet { defaults.set(macInputDeviceUID, forKey: "macInputDeviceUID") } }
    @Published var macOutputDeviceUID: String { didSet { defaults.set(macOutputDeviceUID, forKey: "macOutputDeviceUID") } }

    init() {
        // Brain'in client token'ı (/api/clients ile bu telefon için üretildi).
        // Eski sunucudan kalan anahtarlar geçersiz — yenisine taşı.
        let defaultToken = "Y9td20fpS9mJ3BqRmFPt5zs7TF8Y0Rr3o1xxerc_sQ0"
        let storedKey = defaults.string(forKey: "bridgeApiKey") ?? ""
        self.bridgeApiKey = (storedKey.isEmpty || storedKey == "benimsecrettokenim")
            ? defaultToken : storedKey
        // Eski sunucudan kalan ses adlarını brain'in varsayılanına taşı.
        let storedVoice = defaults.string(forKey: "voice") ?? "nese"
        self.voice = ["ayhan.mp3", "deneme"].contains(storedVoice) ? "nese" : storedVoice
        self.language = defaults.string(forKey: "language") ?? "tr"
        self.wakeWordEnabled = defaults.object(forKey: "wakeWordEnabled") as? Bool ?? true
        self.wakeWord = defaults.string(forKey: "wakeWord") ?? "candan"
        self.cuesEnabled = defaults.object(forKey: "cuesEnabled") as? Bool ?? true
        self.noiseFilterEnabled = defaults.object(forKey: "noiseFilterEnabled") as? Bool ?? true
        self.bargeInEnabled = defaults.object(forKey: "bargeInEnabled") as? Bool ?? true
        self.useOnDeviceTTS = defaults.object(forKey: "useOnDeviceTTS") as? Bool ?? false
        self.onDeviceVoiceId = defaults.string(forKey: "onDeviceVoiceId") ?? ""
        // Brain'in Bridge v0 voice endpoint'i (dev: Mac, LAN üzerinden mDNS).
        // Eski vox sunucusu adresi kayıtlıysa brain'e taşı.
        // macOS istemcisi brain ile aynı makinede çalışıyor → loopback.
        #if os(macOS)
        let defaultURL = "ws://127.0.0.1:8800/api/voice"
        #else
        let defaultURL = "ws://drascoms-macbook-pro.local:8800/api/voice"
        #endif
        let storedURL = defaults.string(forKey: "bridgeWSURL") ?? ""
        self.bridgeWSURL = (storedURL.isEmpty || storedURL.contains("mate.drascom.uk"))
            ? defaultURL : storedURL
        self.macInputDeviceUID = defaults.string(forKey: "macInputDeviceUID") ?? ""
        self.macOutputDeviceUID = defaults.string(forKey: "macOutputDeviceUID") ?? ""
    }
}
