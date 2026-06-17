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
            Log.line("[Cue] engine start failed: \(error)")
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
        #if os(macOS)
        // VPIO modu: ayrı engine'in çıkışı VPIO'nun AEC referansına girmez (chime
        // mic'e sızıp false barge-in yapabilir) ve tek-cihaz kurulumunda güvenilir
        // değil. VPIO çalışıyorsa cue'yu onun çıkış kuyruğundan geçir. Çalışmıyorsa
        // (ör. uyku/bekleme) private engine'e düş — o da default cihaza çalabilir.
        let pipeline = AudioPipeline.shared
        if pipeline.useVPIO, pipeline.vpio.running {
            playVPIO(notes: notes, gain: gain, pipeline: pipeline)
            return
        }
        #endif
        prepare()
        guard prepared else { return }
        var cursorFrames: AVAudioFramePosition = 0
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

    #if os(macOS)
    /// Cue'yu tek bir 48k mono float buffer'a sentezleyip VPIO çıkış kuyruğuna it.
    /// Resample yok — doğrudan VPIOEngine.sampleRate'te üretilir.
    private func playVPIO(notes: [(freq: Double, duration: Double, gap: Double)],
                          gain: Float, pipeline: AudioPipeline) {
        let sr = VPIOEngine.sampleRate
        var samples: [Float] = []
        for n in notes {
            let frames = Int(n.duration * sr)
            let attackFrames = Float(min(0.012, n.duration * 0.3) * sr)
            let releaseFrames = Float(min(0.05, n.duration * 0.5) * sr)
            let total = Float(frames)
            for i in 0..<frames {
                let t = Double(i) / sr
                let f = Float(i)
                let env: Float
                if f < attackFrames {
                    env = f / attackFrames
                } else if f > total - releaseFrames {
                    env = (total - f) / releaseFrames
                } else {
                    env = 1.0
                }
                samples.append(Float(sin(2 * .pi * n.freq * t)) * env * gain)
            }
            let gapFrames = Int(n.gap * sr)
            if gapFrames > 0 { samples.append(contentsOf: repeatElement(0, count: gapFrames)) }
        }
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { bp in
            if let base = bp.baseAddress {
                pipeline.vpio.enqueuePlayback(base, count: bp.count)
            }
        }
    }
    #endif

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
