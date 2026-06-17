import Foundation
import AVFoundation

/// Tek bir AVAudioEngine üzerinden hem mic input hem TTS playback geçiriyoruz.
/// Voice processing (`setVoiceProcessingEnabled(true)`) → donanım seviyesinde
/// AEC (acoustic echo cancellation) + noise suppression. TTS sesi mic'e geri
/// dönerken iOS engine içinde otomatik cancel eder, böylece speaker'da bile
/// kendi sesini "kullanıcı konuşması" sanmaz.
@MainActor
final class AudioPipeline {
    static let shared = AudioPipeline()

    private(set) var engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()

    #if os(macOS)
    // VP kurulamadığında giriş AYRI engine'de tutulur: macOS'ta tek engine'de
    // giriş ve çıkış FARKLI cihazlara denk gelince (aggregate device yok)
    // input tap'ine sürekli sıfır geliyordu. Wake detector'ın input-only
    // engine'i bu yüzden çalışırken paylaşılan engine sessiz kalıyordu.
    private(set) var inputEngine: AVAudioEngine?
    #endif

    /// Mikrofon tap'lerinin bağlanacağı engine (macOS VP'siz modda ayrı motor).
    var captureEngine: AVAudioEngine {
        #if os(macOS)
        if let inputEngine { return inputEngine }
        #endif
        return engine
    }

    private var configured = false
    private(set) var connectedFormat: AVAudioFormat?

    /// Donanım voice-processing (VPIO/AEC) aktif mi. iOS'ta genelde true (donanım
    /// AEC) → yazılım AEC'e gerek yok; macOS 26'da false (VPIO bozuk) → yazılım AEC.
    var voiceProcessingActive: Bool {
        #if os(macOS)
        if useVPIO { return true }   // raw VPIO donanım AEC
        #endif
        return engine.inputNode.isVoiceProcessingEnabled
    }

    #if os(macOS)
    /// macOS konuşma ses yolu: AVAudioEngine yerine raw AUVoiceProcessingIO
    /// (donanım AEC). AVAudioEngine'in VPIO sarmalayıcısı macOS 26'da bozuk.
    let vpio = VPIOEngine()
    var useVPIO = true
    #endif

    private init() {}

    /// İlk çağrıda voice processing'i açıp playerNode'u attach eder.
    /// Sonraki çağrılarda sadece engine'i (varsa duraklatılmış) yeniden başlatır.
    /// macOS: VP (AEC) bazı cihaz/çoklu-mikrofon kurulumlarında -10875 ile
    /// başlatılamıyor → VP kapatılıp tekrar denenir (eko iptali olmadan devam).
    func prepareIfNeeded() throws {
        #if os(macOS)
        if useVPIO {
            if !vpio.running { try vpio.start() }
            return
        }
        #endif
        if !configured {
            do {
                try buildGraph(voiceProcessing: true)
            } catch {
                #if os(macOS)
                Log.line("[Pipeline] VP kurulamadı (\(error)) → voice processing OLMADAN kuruluyor")
                try buildGraph(voiceProcessing: false)
                #else
                throw error
                #endif
            }
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                #if os(macOS)
                guard engine.inputNode.isVoiceProcessingEnabled else { throw error }
                // VPIO eşleşmemiş giriş/çıkış cihazında -10875 ile patlar. AEC'den
                // vazgeçmeden önce dahili mic+hoparlöre (bilinen-çalışan VPIO çifti)
                // zorlayıp VP'yi bir kez daha dene; o da olmazsa AEC'siz devam.
                Log.line("[Pipeline] VP start başarısız (\(error)) → dahili cihaza zorlayıp VP yeniden deneniyor")
                MacAudioDevices.forceBuiltInDefaults()
                do {
                    try buildGraph(voiceProcessing: true)
                    try engine.start()
                } catch {
                    Log.line("[Pipeline] dahili cihazla da VP başarısız (\(error)) → VP kapatılıyor (AEC yok)")
                    try buildGraph(voiceProcessing: false)
                    try engine.start()
                }
                #else
                throw error
                #endif
            }
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            Log.line("[Pipeline] engine started — VP=\(engine.inputNode.isVoiceProcessingEnabled) inputSR=\(Int(inputFormat.sampleRate))Hz ch=\(inputFormat.channelCount)")
        }
    }

    /// Engine graph'ını (yeniden) kurar. VPIO input ile aynı format kullanılır:
    /// AEC, output path'ı (echo reference) ile input path'ını aynı sample rate
    /// ve channel count'ta görmek zorunda; mismatch echo subtraction'ı bozar.
    private func buildGraph(voiceProcessing: Bool) throws {
        // Her kurulumda TEMİZ engine: VP'yi aynı engine üzerinde aç/kapat
        // yapmak macOS'ta IO unit'i yarım durumda bırakıp input'u sessize
        // çeviriyordu (tap'e hep sıfır geliyordu).
        engine.stop()
        if configured {
            engine.detach(playerNode)
        }
        engine = AVAudioEngine()
        engine.attach(playerNode)
        #if os(macOS)
        inputEngine?.stop()
        inputEngine = nil
        #endif

        let inputFormat: AVAudioFormat
        if voiceProcessing {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            inputFormat = engine.inputNode.outputFormat(forBus: 0)
        } else {
            #if os(macOS)
            // VP yok → giriş ayrı engine'de; çıkış engine'inin inputNode'una
            // hiç dokunma (dokunmak AUHAL input'u instantiate edip sorunu
            // geri getiriyor).
            let capture = AVAudioEngine()
            inputFormat = capture.inputNode.outputFormat(forBus: 0)
            inputEngine = capture
            #else
            inputFormat = engine.inputNode.outputFormat(forBus: 0)
            #endif
        }

        let connectFormat = AVAudioFormat(
            standardFormatWithSampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount
        ) ?? engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(playerNode, to: engine.mainMixerNode, format: connectFormat)
        connectedFormat = connectFormat
        engine.prepare()
        configured = true
        Log.line("[Pipeline] configured (VP=\(voiceProcessing), connect sr=\(Int(connectFormat.sampleRate))Hz ch=\(connectFormat.channelCount))")
    }

    /// Mikrofon tap'i kurulduktan sonra çağrılır: macOS'ta ayrı input engine
    /// kullanılıyorsa onu başlatır (tap'siz başlatmak graph hatası verir).
    func startCaptureIfNeeded() throws {
        #if os(macOS)
        if useVPIO { return }   // VPIO zaten capture ediyor
        #endif
        #if os(macOS)
        if let inputEngine, !inputEngine.isRunning {
            inputEngine.prepare()
            try inputEngine.start()
            let fmt = inputEngine.inputNode.outputFormat(forBus: 0)
            Log.line("[Pipeline] capture engine started (ayrı input) sr=\(Int(fmt.sampleRate))Hz ch=\(fmt.channelCount)")
        }
        #endif
    }

    /// Wake mode'a geçerken engine'i durdur — wake kendi AVAudioEngine'ini kullanır,
    /// iki engine aynı anda mic'i tutmasın.
    func pause() {
        #if os(macOS)
        if useVPIO {
            if vpio.running { vpio.stop() }
            return
        }
        #endif
        if engine.isRunning {
            engine.stop()
            Log.line("[Pipeline] engine paused (wake mode)")
        }
        #if os(macOS)
        if let inputEngine, inputEngine.isRunning {
            inputEngine.stop()
        }
        #endif
    }

    /// PlayerNode'u verilen format'a bağlar — SADECE format gerçekten değiştiyse.
    /// Engine çalışırken graph topology değişikliği VP IO unit'i render err -1
    /// ile düşürür; bu yüzden format değiştiğinde stop → reconnect → start.
    /// Aynı format için no-op, AEC reference path'ını korur.
    func reconnectPlayer(format: AVAudioFormat) {
        if let current = connectedFormat,
           current.sampleRate == format.sampleRate,
           current.channelCount == format.channelCount {
            return
        }
        let wasRunning = engine.isRunning
        if wasRunning { engine.stop() }
        if connectedFormat != nil {
            engine.disconnectNodeOutput(playerNode)
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        connectedFormat = format
        if wasRunning {
            do { try engine.start() }
            catch { Log.line("[Pipeline] engine restart failed: \(error)") }
        }
        Log.line("[Pipeline] player reconnected sr=\(Int(format.sampleRate))Hz ch=\(format.channelCount)")
    }

    static func computeLevel(buffer: AVAudioPCMBuffer) -> Float {
        normalize(dB: computeDB(buffer: buffer))
    }

    /// Ham (normalize edilmemiş) dB RMS — teşhis için: normalize edilmiş
    /// 0.000, dijital sessizlik mi yoksa -55dB altı çok kısık ses mi
    /// ayırt ettirmiyor.
    static func computeDB(buffer: AVAudioPCMBuffer) -> Float {
        // TÜM kanalların RMS'i: macOS'ta bazı (çoklu/stereo) mikrofonlarda
        // 0. kanal ölü olabiliyor — yalnız ch0 okumak seviyeyi 0 gösteriyordu.
        guard let data = buffer.floatChannelData else { return -120 }
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard count > 0, channels > 0 else { return -120 }
        var sumSquares: Float = 0
        for ch in 0..<channels {
            let samples = data[ch]
            for i in 0..<count {
                let s = samples[i]
                sumSquares += s * s
            }
        }
        let rms = sqrtf(sumSquares / Float(count * channels))
        return 20 * log10f(max(rms, 1e-9))
    }

    static func normalize(dB: Float) -> Float {
        let minDb: Float = -55
        if dB < minDb { return 0 }
        if dB >= 0 { return 1 }
        return (dB - minDb) / -minDb
    }
}
