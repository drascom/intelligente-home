import AVFoundation
import Foundation

/// Kısa, sıcak çok-notalı geçiş tonları (wake / dinleme bitti / uyku / hatırlatma).
///
/// PLAYBACK — neden AVAudioPlayer: Cue'yu PCM olarak sentezleyip WAV Data'ya
/// sarıp `AVAudioPlayer` ile çalıyoruz. Eski yaklaşım (uygulamanın KENDİ
/// AVAudioEngine'i) LiveKit ses yolundayken sessiz kalıyordu; AVAudioPlayer
/// LiveKit'in mic/motor durumundan BAĞIMSIZdır (uyku modunda mic kapalıyken de
/// çalar) ve macOS'ta varsayılan çıkışa güvenilir şekilde gider. Player'lar
/// bitene kadar referansta tutulur (yoksa erken serbest kalıp susardı).
///
/// Tını "sıcak": saf sinüs yerine birkaç harmonik + çan zarfı (hızlı atak,
/// üssel sönüm/çınlama).
@MainActor
final class CueSounds {
    /// Tek nota tanımı.
    private struct Note {
        let freq: Double
        let duration: Double
        /// Notadan sonra eklenecek sessizlik (saniye).
        let gap: Double
    }

    private let sampleRate = 44_100
    /// Çalan player'lar bitene kadar burada tutulur (erken dealloc → sessizlik).
    private var players: [AVAudioPlayer] = []

    // MARK: - Genel cue'lar (C5=523.25, E5=659.25, G5=783.99 …)

    /// Wake kelimesi algılandı → "duydum, konuş" — sıcak yükselen majör arpej.
    func playWakeDetected() {
        play([
            Note(freq: 523.25, duration: 0.16, gap: 0.0),
            Note(freq: 659.25, duration: 0.16, gap: 0.0),
            Note(freq: 783.99, duration: 0.32, gap: 0.0),
        ], gain: 0.5)
    }

    /// Konuşma bitti → "anladım" — tek kısa yumuşak ton.
    func playListenEnded() {
        play([Note(freq: 587.33, duration: 0.18, gap: 0.0)], gain: 0.4)
    }

    /// Tekrar uykuya geçildi → inen üç nota, daha sönük.
    func playSleeping() {
        play([
            Note(freq: 783.99, duration: 0.14, gap: 0.0),
            Note(freq: 659.25, duration: 0.14, gap: 0.0),
            Note(freq: 523.25, duration: 0.28, gap: 0.0),
        ], gain: 0.34)
    }

    /// Proaktif hatırlatma → "vakti geldi" — wake'ten belirgin biçimde FARKLI:
    /// daha uzun, daha parlak, dört notalı yükselen + uzun kapanış (öne çıksın).
    func playReminder() {
        play([
            Note(freq: 659.25, duration: 0.18, gap: 0.04),
            Note(freq: 880.00, duration: 0.18, gap: 0.04),
            Note(freq: 1108.73, duration: 0.18, gap: 0.04),
            Note(freq: 1318.51, duration: 0.50, gap: 0.0),
        ], gain: 0.62)
    }

    // MARK: - Sentez + çalma

    private func play(_ notes: [Note], gain: Float) {
        // Biten player'ları temizle (bellek + referans yönetimi).
        players.removeAll { !$0.isPlaying }
        guard let data = makeWAV(notes: notes, gain: gain),
              let player = try? AVAudioPlayer(data: data)
        else { return }
        player.volume = 1.0
        player.prepareToPlay()
        player.play()
        players.append(player)
    }

    /// Notaları (harmonikler + çan zarfı) tek bir 16-bit PCM mono WAV Data'ya
    /// sentezler.
    private func makeWAV(notes: [Note], gain: Float) -> Data? {
        let sr = Double(sampleRate)

        // Önce kısa sessizlik (soğuk başlangıç transientini maskele).
        var samples: [Int16] = []
        let leadSilence = Int(0.02 * sr)
        samples.reserveCapacity(leadSilence)
        samples.append(contentsOf: repeatElement(0, count: leadSilence))

        for n in notes {
            let frames = Int(n.duration * sr)
            let attackFrames = max(1.0, 0.006 * sr)
            for i in 0 ..< frames {
                let t = Double(i) / sr
                // Çan zarfı: hızlı atak + üssel sönüm (çınlama kuyruğu).
                let attackEnv = Double(i) < attackFrames ? Double(i) / attackFrames : 1.0
                let decayEnv = exp(-t * 4.2)
                let env = attackEnv * decayEnv
                // Sıcak tını: temel + 2.(0.5) + 3.(0.22) harmonik, normalize.
                let phase = 2.0 * Double.pi * n.freq * t
                let s = (sin(phase) + 0.5 * sin(2.0 * phase) + 0.22 * sin(3.0 * phase)) / 1.72
                let value = s * env * Double(gain)
                let clamped = max(-1.0, min(1.0, value))
                samples.append(Int16(clamped * 32767.0))
            }
            let gapFrames = Int(n.gap * sr)
            if gapFrames > 0 { samples.append(contentsOf: repeatElement(0, count: gapFrames)) }
        }

        guard !samples.isEmpty else { return nil }
        return wavData(from: samples, sampleRate: sampleRate)
    }

    /// 16-bit mono PCM örneklerini standart 44-byte başlıklı WAV Data'ya sarar.
    private func wavData(from samples: [Int16], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * MemoryLayout<Int16>.size

        var data = Data()
        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendUInt32LE(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func appendUInt16LE(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }

        appendString("RIFF")
        appendUInt32LE(UInt32(36 + dataBytes))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16) // PCM fmt chunk size
        appendUInt16LE(1) // audio format = PCM
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(blockAlign))
        appendUInt16LE(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32LE(UInt32(dataBytes))
        samples.withUnsafeBufferPointer { buf in
            data.append(buf.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: dataBytes) { ptr in
                Data(bytes: ptr, count: dataBytes)
            })
        }
        return data
    }
}
