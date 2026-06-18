import AVFoundation
import Foundation

/// Kısa yumuşak geçiş tonları (wake / dinleme bitti / uyku).
///
/// mate-mac'teki VPIO/AudioPipeline'a özel yol BİLİNÇLİ olarak çıkarıldı —
/// bu uygulamada ses I/O'sunu LiveKit yönetir; cue'lar bağımsız bir
/// AVAudioEngine ile (varsayılan çıkışa) çalınır.
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

    /// Wake kelimesi algılandı → "duydum, konuş" — yükselen iki ton.
    func playWakeDetected() {
        play(notes: [(660, 0.08, 0.0), (880, 0.10, 0.005)])
    }

    /// Konuşma bitti → "anladım, işliyorum" — tek kısa ton.
    func playListenEnded() {
        play(notes: [(520, 0.07, 0.0)])
    }

    /// Tekrar uykuya geçildi → inen iki ton, daha sönük.
    func playSleeping() {
        play(notes: [(880, 0.08, 0.0), (660, 0.12, 0.005)], gain: 0.13)
    }

    private func play(notes: [(freq: Double, duration: Double, gap: Double)], gain: Float = 0.18) {
        prepare()
        guard prepared else { return }
        // Soğuk engine spin-up'ı tonun başında "çat" üretebiliyor → önce kısa
        // bir sessizlik tamponu çal, transient sese değil sessizliğe denk gelsin.
        var cursorFrames: AVAudioFramePosition = 0
        let leadSilence = makeTone(freq: 0, duration: 0.045, gain: 0)
        player.scheduleBuffer(leadSilence, at: nil, options: [])
        cursorFrames += AVAudioFramePosition(leadSilence.frameLength)
        for n in notes {
            let buffer = makeTone(freq: n.freq, duration: n.duration, gain: gain)
            let when: AVAudioTime? = cursorFrames == 0
                ? nil
                : AVAudioTime(sampleTime: cursorFrames, atRate: format.sampleRate)
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
        for i in 0 ..< Int(frameCount) {
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
