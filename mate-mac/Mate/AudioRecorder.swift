import Foundation
import AVFoundation

/// AudioPipeline (voice-processing'li shared engine) üzerinden kayıt yapan facade.
/// AVAudioRecorder yerine AVAudioEngine input tap kullanır → AEC + noise
/// suppression buffer'lara uygulanır, hem dosyaya hem level callback'e temiz ses gider.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isCapturingSegment = false
    @Published var level: Float = 0

    private let pipeline = AudioPipeline.shared
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var tapInstalled = false
    private var ringBuffers: [AVAudioPCMBuffer] = []
    private var ringFrameCount: AVAudioFramePosition = 0
    private var maxRingFrames: AVAudioFramePosition = 48_000
    #if os(macOS)
    private var vpioFormat: AVAudioFormat?
    private var vpioFirstLogged = false
    #endif

    var onLevel: ((Float) -> Void)?
    /// Her kopyalanmış mic buffer'ı için çağrılır (canlı STT beslemesi).
    /// Tap (gerçek-zamanlı audio thread) üzerinden çağrılır — alıcı
    /// @Published/UI dokunuşunu kendisi MainActor'a marshal etmeli.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func requestPermission() async -> Bool {
        #if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        #endif
    }

    func startMonitoring() throws {
        try pipeline.prepareIfNeeded()

        #if os(macOS)
        if pipeline.useVPIO {
            if !tapInstalled {
                let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: VPIOEngine.sampleRate,
                                        channels: 1, interleaved: false)!
                vpioFormat = fmt
                maxRingFrames = AVAudioFramePosition(VPIOEngine.sampleRate * 2.5)
                vpioFirstLogged = false
                pipeline.vpio.onMic = { [weak self] samples, n in
                    self?.handleVPIOMic(samples, count: n)
                }
                tapInstalled = true
                Log.line("[Recorder] VPIO mic akışı bağlandı (donanım AEC, 48k mono)")
            }
            isRecording = true
            return
        }
        #endif

        guard !tapInstalled else {
            try pipeline.prepareIfNeeded()
            try pipeline.startCaptureIfNeeded()
            isRecording = true
            return
        }

        // macOS VP'siz modda giriş ayrı engine'de (captureEngine) yaşar.
        let inputNode = pipeline.captureEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        maxRingFrames = AVAudioFramePosition(inputFormat.sampleRate * 2.5)
        // Yazılım AEC'i gerçek mic sample-rate'iyle hazırla (macOS 26 VPIO yedeği).
        // Donanım VPIO açıksa (iOS) gerek yok.
        if !pipeline.voiceProcessingActive {
            EchoCanceller.shared.configure(sampleRate: Int(inputFormat.sampleRate))
        }

        var firstBufferLogged = false
        var bufferCount = 0
        Log.line("[Recorder] tap install, format=\(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let copy = Self.copyBuffer(buffer) {
                self.ringBuffers.append(copy)
                self.ringFrameCount += AVAudioFramePosition(copy.frameLength)
                while self.ringFrameCount > self.maxRingFrames, !self.ringBuffers.isEmpty {
                    let removed = self.ringBuffers.removeFirst()
                    self.ringFrameCount -= AVAudioFramePosition(removed.frameLength)
                }
            }
            try? self.file?.write(from: buffer)
            // Canlı STT beslemesi — konuşurken tanıma yürüsün.
            self.onBuffer?(buffer)
            // Barge-in seviyesi: TTS çalarken AEC-temizlenmiş sinyalden hesapla
            // (eko silinir → kendi sesini "konuşma" sanıp yanlış barge-in yapmaz).
            // AEC pasifken (TTS yok) ham sinyalden — processForLevel nil döner.
            var lvl = AudioPipeline.computeLevel(buffer: buffer)
            if let ch = buffer.floatChannelData,
               let cleaned = EchoCanceller.shared.processForLevel(ch[0], count: Int(buffer.frameLength)) {
                lvl = cleaned
            }
            bufferCount += 1
            if !firstBufferLogged {
                firstBufferLogged = true
                Log.line("[Recorder] first buffer: frames=\(buffer.frameLength) level=\(String(format: "%.3f", lvl))")
            }
            #if os(macOS)
            // Teşhis: mac mikrofon kazancı çok değişken — 2 sn'de bir ham dB
            // logla (dijital sessizlik ~-180dB, kısık oda ~-60dB, konuşma >-45dB).
            if bufferCount % 20 == 0 {
                let db = AudioPipeline.computeDB(buffer: buffer)
                Log.debug(String(format: "[Recorder] dB=%.1f level=%.3f", db, lvl))
            }
            #endif
            DispatchQueue.main.async {
                self.level = lvl
                self.onLevel?(lvl)
            }
        }
        tapInstalled = true
        try pipeline.startCaptureIfNeeded()   // tap kurulduktan SONRA (tap'siz start hata verir)
        isRecording = true
    }

    func start() throws -> URL {
        try startMonitoring()
        return try beginSegment(includePreRoll: false)
    }

    /// Kayıt dosyası ayarlarını türetmek için kullanılacak format. VPIO modunda
    /// `captureEngine` (paylaşılan AVAudioEngine) HİÇ başlatılmaz → `inputNode.
    /// outputFormat` geçersiz (0 Hz / 0 ch) döner → bozuk AAC dosyası → SFSpeech
    /// "Cannot Open". O modda gerçek mic akışının formatını (`vpioFormat`, 48k
    /// mono float) kullan. Diğer modlarda eskisi gibi capture engine formatı.
    private var captureFormat: AVAudioFormat {
        #if os(macOS)
        if pipeline.useVPIO, let fmt = vpioFormat { return fmt }
        #endif
        return pipeline.captureEngine.inputNode.outputFormat(forBus: 0)
    }

    @discardableResult
    func beginSegment(includePreRoll: Bool = true, preRollSeconds: Double = 0.75) throws -> URL {
        try startMonitoring()
        file = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let inputFormat = captureFormat
        let fileSettings = Self.fileSettings(for: inputFormat)
        let outFile = try AVAudioFile(forWriting: url, settings: fileSettings)
        file = outFile
        fileURL = url
        isCapturingSegment = true

        if includePreRoll {
            let framesNeeded = AVAudioFramePosition(inputFormat.sampleRate * preRollSeconds)
            var collected: AVAudioFramePosition = 0
            var selected: [AVAudioPCMBuffer] = []
            for buffer in ringBuffers.reversed() {
                selected.append(buffer)
                collected += AVAudioFramePosition(buffer.frameLength)
                if collected >= framesNeeded { break }
            }
            for buffer in selected.reversed() {
                try? outFile.write(from: buffer)
                // Pre-roll'ü canlı STT'ye de gönder (ilk hece tanımaya girsin).
                onBuffer?(buffer)
            }
            Log.line("[Recorder] segment begin, preRollFrames=\(collected)")
        } else {
            Log.line("[Recorder] segment begin")
        }
        return url
    }

    /// Mevcut kayıt dosyasını kapat, **aynı tap'ı koruyarak** yeni bir dosyaya
    /// yazmaya başla. Eski URL döner (caller silebilir). Barge-in trigger anında
    /// TTS-echo dolu dosyayı atıp temiz dosyaya geçmek için kullanılır.
    /// Tap durdurulmadığı için frame kaybı yok.
    func rotateFile() throws -> URL? {
        guard isRecording else { return nil }
        let oldURL = fileURL
        let newURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString).m4a")
        let inputFormat = captureFormat
        let fileSettings = Self.fileSettings(for: inputFormat)
        let newFile = try AVAudioFile(forWriting: newURL, settings: fileSettings)
        file = newFile
        fileURL = newURL
        isCapturingSegment = true
        Log.line("[Recorder] file rotated")
        return oldURL
    }

    @discardableResult
    func finishSegment() -> URL? {
        file = nil
        let url = fileURL
        fileURL = nil
        isCapturingSegment = false
        return url
    }

    func discardSegment() {
        if let url = finishSegment() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func stop() -> URL? {
        #if os(macOS)
        if pipeline.useVPIO {
            pipeline.vpio.onMic = nil
            tapInstalled = false
        } else if tapInstalled {
            pipeline.captureEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        #else
        if tapInstalled {
            pipeline.captureEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        #endif
        file = nil  // dosya flush
        let url = fileURL
        fileURL = nil
        isRecording = false
        isCapturingSegment = false
        level = 0
        ringBuffers.removeAll()
        ringFrameCount = 0
        return url
    }

    static func normalize(dB: Float) -> Float {
        AudioPipeline.normalize(dB: dB)
    }

    private static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            // Girişin GERÇEK kanal sayısı: mac mikrofonları stereo verebiliyor;
            // 1'e sabitlemek write'ı format uyuşmazlığıyla sessizce düşürüyordu
            // (try? yutuyor) → 0 frame'lik boş kayıt. Mono'ya indirme işi
            // pcm16kMono'daki AVAudioConverter'da yapılır.
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
    }

    #if os(macOS)
    /// VPIO'dan gelen (donanım echo-cancel edilmiş) mic örneklerini işle —
    /// tap closure'ı ile aynı akış: ring + dosya + canlı STT + seviye/barge-in.
    private func handleVPIOMic(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0, let fmt = vpioFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        buffer.floatChannelData?[0].update(from: samples, count: count)

        ringBuffers.append(buffer)
        ringFrameCount += AVAudioFramePosition(count)
        while ringFrameCount > maxRingFrames, !ringBuffers.isEmpty {
            let removed = ringBuffers.removeFirst()
            ringFrameCount -= AVAudioFramePosition(removed.frameLength)
        }
        try? file?.write(from: buffer)
        onBuffer?(buffer)
        let lvl = AudioPipeline.computeLevel(buffer: buffer)
        if !vpioFirstLogged {
            vpioFirstLogged = true
            Log.line("[Recorder] VPIO ilk buffer: frames=\(count) level=\(String(format: "%.3f", lvl))")
        }
        DispatchQueue.main.async {
            self.level = lvl
            self.onLevel?(lvl)
        }
    }
    #endif

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let dest = copy.floatChannelData {
            for channel in 0..<channels {
                dest[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int16ChannelData, let dest = copy.int16ChannelData {
            for channel in 0..<channels {
                dest[channel].update(from: source[channel], count: frames)
            }
        } else if let source = buffer.int32ChannelData, let dest = copy.int32ChannelData {
            for channel in 0..<channels {
                dest[channel].update(from: source[channel], count: frames)
            }
        } else {
            return nil
        }
        return copy
    }
}
