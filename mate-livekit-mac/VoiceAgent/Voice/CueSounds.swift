import AVFoundation
import Foundation
import LiveKit

/// Kısa, sıcak çok-notalı geçiş tonları (wake / dinleme bitti / uyku / hatırlatma).
///
/// ÖNEMLİ — neden LiveKit mixer'ı: Bağımsız bir AVAudioEngine, LiveKit ses
/// motoru/oturumu cihazı yönetirken çıkışa ULAŞAMIYOR (sessiz çalıyordu). Bu
/// yüzden cue'ları LiveKit'in KENDİ motoruna `AudioManager.shared.mixer
/// .capture(appAudio:)` ile veriyoruz — çağrı sesiyle aynı yoldan, yerel
/// hoparlöre karışır. Mic yayını kapalı olsa bile (uyku modu) bağlantı boyunca
/// motorun input yolu bağlı kaldığından cue duyulur.
///
/// Tını "sıcak": saf sinüs yerine birkaç harmonik + çan zarfı (hızlı atak,
/// üssel sönüm) kullanılır.
@MainActor
final class CueSounds {
    /// Tek nota tanımı.
    private struct Note {
        let freq: Double
        let duration: Double
        /// Notadan sonra eklenecek sessizlik (saniye).
        let gap: Double
    }

    private let sampleRate: Double = 48_000
    private var volumePrimed = false

    // MARK: - Genel cue'lar (notalar: C5=523.25, E5=659.25, G5=783.99 …)

    /// Wake kelimesi algılandı → "duydum, konuş" — sıcak yükselen majör arpej.
    func playWakeDetected() {
        play([
            Note(freq: 523.25, duration: 0.16, gap: 0.0),
            Note(freq: 659.25, duration: 0.16, gap: 0.0),
            Note(freq: 783.99, duration: 0.30, gap: 0.0),
        ], gain: 0.55)
    }

    /// Konuşma bitti → "anladım" — tek kısa yumuşak ton.
    func playListenEnded() {
        play([Note(freq: 587.33, duration: 0.18, gap: 0.0)], gain: 0.45)
    }

    /// Tekrar uykuya geçildi → inen iki/üç nota, daha sönük.
    func playSleeping() {
        play([
            Note(freq: 783.99, duration: 0.14, gap: 0.0),
            Note(freq: 659.25, duration: 0.14, gap: 0.0),
            Note(freq: 523.25, duration: 0.26, gap: 0.0),
        ], gain: 0.38)
    }

    /// Proaktif hatırlatma → "vakti geldi" — wake'ten belirgin biçimde FARKLI:
    /// daha uzun, daha parlak, dört notalı yükselen + uzun kapanış (öne çıksın).
    func playReminder() {
        play([
            Note(freq: 659.25, duration: 0.16, gap: 0.03),
            Note(freq: 880.00, duration: 0.16, gap: 0.03),
            Note(freq: 1108.73, duration: 0.16, gap: 0.03),
            Note(freq: 1318.51, duration: 0.45, gap: 0.0),
        ], gain: 0.72)
    }

    // MARK: - Sentez + LiveKit mixer'a verme

    private func play(_ notes: [Note], gain: Float) {
        guard let buffer = makeBuffer(notes: notes, gain: gain) else { return }
        let mixer = AudioManager.shared.mixer
        if !volumePrimed {
            mixer.appVolume = 1.0 // app (cue) sesi tam duyulsun
            volumePrimed = true
        }
        // capture: motor çalışmıyorsa (bağlı değilken) sessizce no-op olur.
        mixer.capture(appAudio: buffer)
    }

    /// Notaları tek bir bitişik Float32 mono tampona sentezler (harmonikler +
    /// çan zarfı). LiveKit mixer'ı gerekli format dönüşümünü kendi yapar.
    private func makeBuffer(notes: [Note], gain: Float) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return nil
        }

        // Önce küçük bir sessizlik (soğuk başlangıç transientini maskele).
        let leadSilence = Int(0.02 * sampleRate)
        var totalFrames = leadSilence
        for n in notes {
            totalFrames += Int(n.duration * sampleRate) + Int(n.gap * sampleRate)
        }
        guard totalFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalFrames)

        let channel = buffer.floatChannelData![0]
        var cursor = leadSilence
        for i in 0 ..< leadSilence { channel[i] = 0 }

        for n in notes {
            let frames = Int(n.duration * sampleRate)
            let attackFrames = max(1.0, 0.006 * sampleRate)
            for i in 0 ..< frames {
                let t = Double(i) / sampleRate
                // Çan zarfı: hızlı atak + üssel sönüm (çınlama kuyruğu).
                let attackEnv = Double(i) < attackFrames ? Double(i) / attackFrames : 1.0
                let decayEnv = exp(-t * 4.2)
                let env = Float(attackEnv * decayEnv)
                // Sıcak tını: temel + 2. (0.5) + 3. (0.22) harmonik, normalize.
                let phase = 2.0 * Double.pi * n.freq * t
                let sample = sin(phase) + 0.5 * sin(2.0 * phase) + 0.22 * sin(3.0 * phase)
                let norm = Float(sample / 1.72)
                channel[cursor + i] = norm * env * gain
            }
            cursor += frames
            let gapFrames = Int(n.gap * sampleRate)
            for i in 0 ..< gapFrames { channel[cursor + i] = 0 }
            cursor += gapFrames
        }

        return buffer
    }
}
