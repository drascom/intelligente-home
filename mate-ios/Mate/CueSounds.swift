import Foundation
import AVFoundation

@MainActor
final class CueSounds {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var prepared = false

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    }

    private func prepare() {
        if !prepared {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            prepared = true
        }
        do {
            if !engine.isRunning {
                try engine.start()
            }
            if !player.isPlaying {
                player.play()
            }
        } catch {
            print("[Cue] engine start failed: \(error)")
        }
    }

    /// Wake duyuldu → "dinliyorum" — yükselen iki ton
    /// Wake kelimesi algılandı → "duydum" — kısa tek ton (onay).
    func playWakeAck() {
        play(notes: [(620, 0.07, 0.0)])
    }

    /// Isınma bitti → "konuş" — yükselen iki ton.
    func playWakeDetected() {
        play(notes: [(660, 0.08, 0.0), (880, 0.10, 0.005)])
    }

    /// Konuşma bitti → "anladım, işliyorum" — tek kısa ton
    func playListenEnded() {
        play(notes: [(520, 0.07, 0.0)])
    }

    /// Pencere doldu → "uykudayım" — inen iki ton, daha sönük
    func playSleeping() {
        play(notes: [(880, 0.08, 0.0), (660, 0.12, 0.005)], gain: 0.13)
    }

    /// Proaktif hatırlatma → "vakti geldi, candan de" — belirgin üç-notalı yükselen
    /// chime (wake cue'larından daha uzun/dolgun, bildirim olarak öne çıksın).
    func playReminderChime() {
        play(notes: [(660, 0.12, 0.04), (880, 0.12, 0.04), (1175, 0.20, 0.0)], gain: 0.22)
    }

    private func play(notes: [(freq: Double, duration: Double, gap: Double)], gain: Float = 0.18) {
        prepare()
        guard prepared else { return }
        // Özel engine SOĞUK başlıyorsa (uyku/wake modunda durdurulmuş → cue buraya
        // düşer) engine/cihaz spin-up'ı tonun başında "çat/cızırtı" üretebiliyor
        // (kullanıcı: "bip'ten ÖNCE gürültü"). Tonlardan önce kısa bir sessizlik
        // tamponu çal → transient sese değil, sessizliğe denk gelsin. (mac parite)
        var cursorFrames: AVAudioFramePosition = 0
        let leadSilence = makeTone(freq: 0, duration: 0.045, gain: 0)
        player.scheduleBuffer(leadSilence, at: nil, options: [])
        cursorFrames += AVAudioFramePosition(leadSilence.frameLength)
        for n in notes {
            let buffer = makeTone(freq: n.freq, duration: n.duration, gain: gain)
            let when: AVAudioTime?
            if cursorFrames == 0 {
                when = nil
            } else {
                when = AVAudioTime(sampleTime: cursorFrames, atRate: format.sampleRate)
            }
            player.scheduleBuffer(buffer, at: when, options: [])
            cursorFrames += AVAudioFramePosition(buffer.frameLength)
            cursorFrames += AVAudioFramePosition(n.gap * format.sampleRate)
        }
    }

    private func makeTone(freq: Double, duration: Double, gain: Float) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channel = buffer.floatChannelData![0]
        let attackFrames = Float(min(0.012, duration * 0.3) * sampleRate)
        let releaseFrames = Float(min(0.05, duration * 0.5) * sampleRate)
        let total = Float(frameCount)
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let f = Float(i)
            let env: Float
            if f < attackFrames {
                env = f / attackFrames
            } else if f > total - releaseFrames {
                env = (total - f) / releaseFrames
            } else {
                env = 1.0
            }
            channel[i] = Float(sin(2 * .pi * freq * t)) * env * gain
        }
        return buffer
    }
}
