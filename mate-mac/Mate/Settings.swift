import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var bridgeApiKey: String { didSet { defaults.set(bridgeApiKey, forKey: "bridgeApiKey") } }
    @Published var voice: String { didSet { defaults.set(voice, forKey: "voice") } }
    // Sunucu STT motoru seçimi (whisper/nemotron); boş/whisper = varsayılan.
    // audio_start ile gönderilir; bilinmeyen/eksik motor brain'de whisper'a düşer.
    @Published var sttEngine: String { didSet { defaults.set(sttEngine, forKey: "sttEngine") } }
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
        // Brain client token'ı kaynağa GÖMÜLMEZ (public repo). Ayarlar ekranından
        // gir; mevcut kurulumlar UserDefaults'tan okur. Yeni kurulumda boş gelir.
        let defaultToken = ""
        let staleTokens = ["benimsecrettokenim"]
        let storedKey = defaults.string(forKey: "bridgeApiKey") ?? ""
        self.bridgeApiKey = (storedKey.isEmpty || staleTokens.contains(storedKey))
            ? defaultToken : storedKey
        // Eski sunucudan kalan ses adlarını brain'in varsayılanına taşı.
        let storedVoice = defaults.string(forKey: "voice") ?? "nese"
        self.voice = ["ayhan.mp3", "deneme"].contains(storedVoice) ? "nese" : storedVoice
        self.sttEngine = defaults.string(forKey: "sttEngine") ?? "whisper"
        self.language = defaults.string(forKey: "language") ?? "tr"
        self.wakeWordEnabled = defaults.object(forKey: "wakeWordEnabled") as? Bool ?? true
        self.wakeWord = defaults.string(forKey: "wakeWord") ?? "candan"
        self.cuesEnabled = defaults.object(forKey: "cuesEnabled") as? Bool ?? true
        self.noiseFilterEnabled = defaults.object(forKey: "noiseFilterEnabled") as? Bool ?? true
        self.bargeInEnabled = defaults.object(forKey: "bargeInEnabled") as? Bool ?? true
        self.useOnDeviceTTS = defaults.object(forKey: "useOnDeviceTTS") as? Bool ?? false
        self.onDeviceVoiceId = defaults.string(forKey: "onDeviceVoiceId") ?? ""
        // Brain artık TEST SUNUCUSUNDA (192.168.0.25); Mac sadece istemci.
        // Eski adresler (loopback/mac mDNS/vox sunucusu) kayıtlıysa sunucuya taşı.
        let defaultURL = "ws://192.168.0.25:8800/api/voice"
        let storedURL = defaults.string(forKey: "bridgeWSURL") ?? ""
        let staleURL = storedURL.isEmpty
            || storedURL.contains("mate.drascom.uk")
            || storedURL.contains("127.0.0.1")
            || storedURL.contains("localhost")
            || storedURL.contains("drascoms-macbook")
        self.bridgeWSURL = staleURL ? defaultURL : storedURL
        self.macInputDeviceUID = defaults.string(forKey: "macInputDeviceUID") ?? ""
        self.macOutputDeviceUID = defaults.string(forKey: "macOutputDeviceUID") ?? ""
    }
}
