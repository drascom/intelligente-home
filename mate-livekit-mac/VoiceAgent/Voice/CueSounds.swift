import AVFoundation
import Foundation

/// Geçiş sesleri (cue) — kullanıcı seçimi gömülü WAV dosyaları.
///
/// `VoiceAgent/Sounds/` altındaki dosyalar app paketine gömülür (synced folder):
///   knock-knock.wav → hazır (bağlanıp wake'e hazır olunca, bir kez)
///   awake.wav       → wake kelimesi sonrası uyanma
///   sleep.wav       → tekrar uykuya geçiş
///   bird.wav        → proaktif hatırlatma/bildirim
///
/// PLAYBACK — AVAudioPlayer: LiveKit'in mic/motor durumundan BAĞIMSIZ (uyku
/// modunda mic kapalıyken de çalar), macOS'ta varsayılan YEREL çıkışa gider
/// (mixer.capture uplink'e gidip kullanıcıya duyulmuyordu). Player'lar bitene
/// kadar referansta tutulur (yoksa erken dealloc → sessizlik).
@MainActor
final class CueSounds {
    /// Çalan player'lar bitene kadar burada tutulur (erken dealloc → sessizlik).
    private var players: [AVAudioPlayer] = []
    /// Yüklenen ses verileri (tekrar tekrar diskten okumamak için).
    private var cache: [String: Data] = [:]

    // MARK: - Cue'lar

    /// Her şey hazır (bağlandı + wake'e hazır) → "tık tık".
    func playReady() { play("knock-knock") }

    /// Wake kelimesi algılandı → uyanma sesi ("konuş").
    func playWakeDetected() { play("awake") }

    /// Tekrar uykuya geçildi.
    func playSleeping() { play("sleep") }

    /// Proaktif hatırlatma/bildirim → wake'ten belirgin biçimde farklı (kuş).
    func playReminder() { play("bird") }

    /// Konuşma bitti — ayrı bir ses atanmadı (no-op).
    func playListenEnded() {}

    // MARK: - Çalma

    private func play(_ resource: String) {
        players.removeAll { !$0.isPlaying }
        guard let data = data(for: resource),
              let player = try? AVAudioPlayer(data: data)
        else { return }
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    private func data(for resource: String) -> Data? {
        if let d = cache[resource] { return d }
        // Synced folder kaynakları pakete düz (flat) gömülür; alt klasör dene-yedek.
        let url = Bundle.main.url(forResource: resource, withExtension: "wav")
            ?? Bundle.main.url(forResource: resource, withExtension: "wav", subdirectory: "Sounds")
        guard let url, let d = try? Data(contentsOf: url) else {
            print("[Cue] ses bulunamadı: \(resource).wav")
            return nil
        }
        cache[resource] = d
        return d
    }
}
