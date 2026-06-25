import Foundation
@preconcurrency import AVFoundation

/// AudioPipeline (voice-processing'li shared engine) üzerinden TTS çalan facade.
/// AVAudioPlayer yerine AVAudioPlayerNode kullanır → playback aynı engine'den
/// geçtiği için AEC referans sinyalini biliyor, mic'e geri dönen echo cancel edilir.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var amplitude: Float = 0

    private let pipeline = AudioPipeline.shared
    private var continuation: CheckedContinuation<Void, Error>?
    private var amplitudeTimer: DispatchSourceTimer?

    func play(data: Data) async throws {
        try pipeline.prepareIfNeeded()

        let hint = Self.detectFileType(data)
        let decoded = try Self.decode(data: data, hint: hint)
        Log.line("[Player] hint=\(hint ?? "nil") frames=\(decoded.frameLength) sr=\(Int(decoded.format.sampleRate))Hz")

        #if os(macOS)
        // VPIO modunda paylaşılan AVAudioEngine HİÇ başlamaz → playerNode sessiz
        // kalır VE completion tetiklenmediği için continuation asılır. TTS'i raw
        // VPIO çıkış kuyruğuna ver (donanım AEC referansı da bu olur) ve drain bekle.
        if pipeline.useVPIO {
            pipeline.vpio.flushPlayback()
            await playViaVPIO(decoded)
            return
        }
        #endif

        // Buffer format'ı player output bus format'ı ile eşleşmeli — aksi halde
        // AVAudioPlayerNode resample yapmıyor ve buffer örnek-bazında çalınıyor
        // (24kHz buffer 48kHz bus'tan 2x hızlı duyulur). reconnectPlayer YOK
        // (AEC echo-path'i bozar); bunun yerine buffer'ı target format'a manuel
        // resample ediyoruz.
        let buffer: AVAudioPCMBuffer
        if let target = pipeline.connectedFormat,
           target.sampleRate != decoded.format.sampleRate
            || target.channelCount != decoded.format.channelCount {
            buffer = try Self.resample(decoded, to: target)
            Log.line("[Player] resampled \(Int(decoded.format.sampleRate))Hz → \(Int(target.sampleRate))Hz, frames=\(buffer.frameLength)")
        } else {
            buffer = decoded
        }

        let player = pipeline.playerNode
        isPlaying = true
        startAmplitudeMetering()

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                let handler: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.handleFinish(success: true)
                    }
                }
                player.scheduleBuffer(
                    buffer,
                    at: nil,
                    options: [.interrupts],
                    completionCallbackType: .dataPlayedBack,
                    completionHandler: handler
                )
                player.play()
            }
        } catch {
            isPlaying = false
            stopAmplitudeMetering()
            throw error
        }
        isPlaying = false
        stopAmplitudeMetering()
    }

    /// On-device TTS (AVSpeechSynthesizer) tarafından üretilen PCM buffer'ı doğrudan
    /// shared engine playerNode'una verir. Resampling gerekirse Self.resample kullanır
    /// — böylece AEC referans sinyali bilgili kalır, barge-in çalışmaya devam eder.
    func play(buffer: AVAudioPCMBuffer) async throws {
        try pipeline.prepareIfNeeded()

        #if os(macOS)
        // VPIO modu: playerNode ölü engine'de → enqueueVPIO + drain (yukarıdaki
        // play(data:) ile aynı gerekçe; aksi halde cihaz-içi TTS turu asılır).
        if pipeline.useVPIO {
            pipeline.vpio.flushPlayback()
            await playViaVPIO(buffer)
            return
        }
        #endif

        let scheduled: AVAudioPCMBuffer
        if let target = pipeline.connectedFormat,
           target.sampleRate != buffer.format.sampleRate
            || target.channelCount != buffer.format.channelCount {
            scheduled = try Self.resample(buffer, to: target)
            Log.line("[Player] on-device TTS resampled \(Int(buffer.format.sampleRate))Hz → \(Int(target.sampleRate))Hz, frames=\(scheduled.frameLength)")
        } else {
            scheduled = buffer
        }

        let player = pipeline.playerNode
        isPlaying = true
        startAmplitudeMetering()

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.continuation = cont
                let handler: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
                    DispatchQueue.main.async { self?.handleFinish(success: true) }
                }
                player.scheduleBuffer(
                    scheduled,
                    at: nil,
                    options: [.interrupts],
                    completionCallbackType: .dataPlayedBack,
                    completionHandler: handler
                )
                player.play()
            }
        } catch {
            isPlaying = false
            stopAmplitudeMetering()
            throw error
        }
        isPlaying = false
        stopAmplitudeMetering()
    }

    /// Streaming playback: byte chunk'ları geldikçe büyüyen temp dosyaya yazar,
    /// her N byte'ta bir AVAudioFile'ı yeni yerden okuyup PCM buffer'ını playerNode'a
    /// schedule eder. İlk yeterli byte (≈8KB) gelince çalmaya başlar.
    func playStreaming(stream: AsyncThrowingStream<Data, Error>, contentType: String?) async throws {
        try pipeline.prepareIfNeeded()

        #if os(macOS)
        // NOT: Bu yol şu an ÇAĞRILMIYOR (realtime bridge streamPCM'i kullanıyor).
        // VPIO moduna uyarlanmadı — scheduleNew dosya-tabanlı playerNode schedule
        // eder, VPIO'da sessiz kalır. Yeniden devreye alınırsa VPIO branch'i gerekir.
        if pipeline.useVPIO {
            Log.line("[Player] UYARI: playStreaming VPIO modunda desteklenmiyor (streamPCM kullan)")
        }
        #endif

        let isMP3 = (contentType ?? "").contains("mp")  // audio/mpeg, audio/mp3
        let ext = isMP3 ? "mp3" : "wav"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        let player = pipeline.playerNode
        isPlaying = true
        startAmplitudeMetering()

        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            isPlaying = false
            stopAmplitudeMetering()
        }

        var totalBytes = 0
        var consumedFrames: AVAudioFramePosition = 0
        var startedPlaying = false
        var pendingBuffers = 0
        var streamFinished = false
        let kMinBytesToStart = 1536  // 1.5KB ≈ 3-4 MP3 frame, ~50-80ms ses

        // Tüm scheduled buffer'lar bitince resume eder
        let allDone = AsyncStream<Void> { continuation in
            self.streamCompletionYield = { continuation.yield(()); continuation.finish() }
        }
        var allDoneIterator = allDone.makeAsyncIterator()

        // Bayt-akışını oku, dosyaya yaz, periyodik schedule et
        do {
            for try await chunk in stream {
                try handle.write(contentsOf: chunk)
                totalBytes += chunk.count

                if totalBytes >= kMinBytesToStart {
                    do {
                        let newFrames = try Self.scheduleNew(
                            fileURL: url,
                            from: consumedFrames,
                            pipeline: pipeline,
                            startedPlaying: &startedPlaying
                        )
                        if newFrames.framesScheduled > consumedFrames {
                            pendingBuffers += 1
                            let onDone = { [weak self] in
                                DispatchQueue.main.async {
                                    pendingBuffers -= 1
                                    self?.checkStreamCompletion(
                                        finished: streamFinished,
                                        pending: pendingBuffers
                                    )
                                }
                            }
                            newFrames.completionRegistration(onDone)
                            consumedFrames = newFrames.framesScheduled
                        }
                        if !startedPlaying || pendingBuffers == 0 { /* race guard */ }
                    } catch {
                        Log.line("[Player] stream chunk decode skipped: \(error.localizedDescription)")
                    }
                }
            }
            try? handle.close()

            // Stream bitti — kalan frame'leri schedule et
            let final = try Self.scheduleNew(
                fileURL: url,
                from: consumedFrames,
                pipeline: pipeline,
                startedPlaying: &startedPlaying
            )
            if final.framesScheduled > consumedFrames {
                pendingBuffers += 1
                final.completionRegistration { [weak self] in
                    DispatchQueue.main.async {
                        pendingBuffers -= 1
                        self?.checkStreamCompletion(finished: true, pending: pendingBuffers)
                    }
                }
                consumedFrames = final.framesScheduled
            }
            streamFinished = true
            Log.line("[Player] stream finished, totalBytes=\(totalBytes), pendingBuffers=\(pendingBuffers)")
            checkStreamCompletion(finished: true, pending: pendingBuffers)
        } catch {
            Log.line("[Player] stream error: \(error)")
            throw error
        }

        // Tüm buffer'lar çalana kadar bekle
        if pendingBuffers > 0 || !startedPlaying {
            _ = await allDoneIterator.next()
        }
    }

    private var streamCompletionYield: (() -> Void)?

    private func checkStreamCompletion(finished: Bool, pending: Int) {
        if finished && pending <= 0 {
            streamCompletionYield?()
            streamCompletionYield = nil
        }
    }

    /// Tek seferde en az 1 frame'lik yeni veri varsa schedule eder, yeni
    /// frame pozisyonunu döner.
    private struct ScheduleResult {
        let framesScheduled: AVAudioFramePosition
        let completionRegistration: (@escaping () -> Void) -> Void
    }

    private static func scheduleNew(
        fileURL: URL,
        from: AVAudioFramePosition,
        pipeline: AudioPipeline,
        startedPlaying: inout Bool
    ) throws -> ScheduleResult {
        let file = try AVAudioFile(forReading: fileURL)
        let fileLength = file.length
        guard fileLength > from else {
            return ScheduleResult(framesScheduled: from, completionRegistration: { _ in })
        }
        let toRead = AVAudioFrameCount(fileLength - from)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: toRead) else {
            throw NSError(domain: "AudioPlayer", code: -200,
                          userInfo: [NSLocalizedDescriptionKey: "PCM buffer alloc failed"])
        }
        file.framePosition = from
        try file.read(into: buffer)

        if !startedPlaying {
            pipeline.reconnectPlayer(format: buffer.format)
            startedPlaying = true
            Log.line("[Player] stream first play, sr=\(Int(buffer.format.sampleRate))Hz frames=\(buffer.frameLength)")
        }

        var registration: (@escaping () -> Void) -> Void = { _ in }
        registration = { onDone in
            // .dataPlayedBack: buffer fiziksel olarak duyulana kadar callback gecikir,
            // aksi halde son buffer HW kuyruğundayken playStreaming döner ve sonraki
            // route/recorder reconfig cümlenin son ~200ms'ini keser.
            let handler: AVAudioPlayerNodeCompletionHandler = { _ in onDone() }
            pipeline.playerNode.scheduleBuffer(
                buffer,
                at: nil,
                options: AVAudioPlayerNodeBufferOptions(),
                completionCallbackType: .dataPlayedBack,
                completionHandler: handler
            )
        }
        if !pipeline.playerNode.isPlaying {
            pipeline.playerNode.play()
        }
        return ScheduleResult(framesScheduled: fileLength, completionRegistration: registration)
    }

    // MARK: - Realtime PCM streaming (RealtimeBridgeClient)
    //
    // Bridge'den parça-parça gelen pcm_f32le buffer'ları, mevcut tek-buffer
    // play(data:) yolunu BOZMADAN, sırayla scheduleBuffer ile çalar. Her parça
    // geldikçe schedule edilir (gerçek zamanlı), playerNode kuyruğa alıp
    // kesintisiz çalar. İlk parçada format farklıysa reconnectPlayer ile engine'i
    // gelen sr'e bağlar (AEC reference path korunur).

    private var streamPending = 0
    private var streamFinishedFlag = false
    private var streamDrainYield: (() -> Void)?
    private var streamStarted = false

    /// Yeni bir realtime stream başlat (audio_start). Sayaçları sıfırlar.
    func beginPCMStream() {
        streamPending = 0
        streamFinishedFlag = false
        streamStarted = false
        streamDrainYield = nil
        isPlaying = true
        #if os(macOS)
        if pipeline.useVPIO { pipeline.vpio.flushPlayback() }
        #endif
        // Yazılım AEC yalnız donanım VPIO/AEC yokken. VPIO modunda (macOS) ve
        // iOS'ta donanım AEC var → yazılım AEC kapalı (voiceProcessingActive=true).
        if !pipeline.voiceProcessingActive { EchoCanceller.shared.begin() }
        startAmplitudeMetering()
    }

    /// TTS playback gain. Telefonda .voiceChat ducking'i telafi eder; mac'te 1.0.
    /// Çok kısık/patlıyorsa bu değeri ayarla (1.0 = değişiklik yok).
    #if os(iOS)
    private static let ttsGain: Float = 2.2
    #else
    private static let ttsGain: Float = 1.0
    #endif

    /// Buffer'a yumuşak-limitli (tanh) gain uygula → yüksek ama sert clip'siz.
    private static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) -> AVAudioPCMBuffer {
        guard gain != 1.0, let src = buffer.floatChannelData,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: buffer.frameLength)
        else { return buffer }
        out.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let dst = out.floatChannelData!
        for c in 0..<channels {
            for i in 0..<frames {
                dst[c][i] = tanhf(src[c][i] * gain)  // boost + nazik doygunluk
            }
        }
        return out
    }

    /// Gelen bir PCM parçasını çalmaya ekle. Parçalar engine'in connectedFormat'ına
    /// resample edilip aynı playerNode kuyruğuna sırayla eklenir (reconnect yok).
    func streamPCM(buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        do {
            try pipeline.prepareIfNeeded()
        } catch {
            Log.line("[Player] stream prepare failed: \(error)")
            return
        }

        #if os(macOS)
        if pipeline.useVPIO {
            // TTS'i raw VPIO çıkış kuyruğuna ver (donanım AEC referansı da bu olur).
            streamStarted = true
            enqueueVPIO(buffer)
            if !pipeline.vpio.running { try? pipeline.prepareIfNeeded() }
            return
        }
        #endif

        // Klasik play(data:) yolundaki gibi davran: reconnectPlayer YAPMA. Reconnect,
        // AEC echo-path'ini bozuyor VE voice-processing engine'inde oynatma hızı/oran
        // uyumsuzluğuna yol açıp sesin sonunu (uzunlukla ORANTILI) kesiyordu. Bunun
        // yerine gelen 48kHz buffer'ı engine'in connectedFormat'ına resample edip schedule et.
        let scheduled: AVAudioPCMBuffer
        if let target = pipeline.connectedFormat,
           target.sampleRate != buffer.format.sampleRate
            || target.channelCount != buffer.format.channelCount {
            scheduled = (try? Self.resample(buffer, to: target)) ?? buffer
        } else {
            scheduled = buffer
        }

        if !streamStarted {
            streamStarted = true
            Log.line("[Player] PCM stream first chunk sr=\(Int(scheduled.format.sampleRate))Hz ch=\(scheduled.format.channelCount) frames=\(scheduled.frameLength)")
        }

        // Telefonda .voiceChat (AEC) modu çıkışı ducked tutuyor → TTS kısık
        // duyuluyor. Yumuşak-limitli (tanh) bir gain ile sesi yükselt; sert clip
        // (patlama) yapmaz, sadece tepe noktaları nazikçe sıkışır. mac'te 1.0 → etkisiz.
        let boosted = Self.applyGain(scheduled, Self.ttsGain)

        // Yazılım AEC far-end referansı: hoparlöre giden sinyali ring'e it (mono).
        if EchoCanceller.shared.active, let ch = boosted.floatChannelData {
            EchoCanceller.shared.pushFarEnd(ch[0], count: Int(boosted.frameLength))
        }

        streamPending += 1
        let handler: AVAudioPlayerNodeCompletionHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.streamPending -= 1
                self.checkPCMStreamDrained()
            }
        }
        // .interrupts YOK: parçalar kuyruğa eklenir, kesintisiz çalar.
        pipeline.playerNode.scheduleBuffer(
            boosted,
            at: nil,
            options: AVAudioPlayerNodeBufferOptions(),
            completionCallbackType: .dataPlayedBack,
            completionHandler: handler
        )
        if !pipeline.playerNode.isPlaying {
            pipeline.playerNode.play()
        }
    }

    /// audio_end geldi: yeni parça gelmeyecek. Tüm parçalar çalınınca
    /// waitForPCMStreamDrained resume olur.
    func finishPCMStream() {
        streamFinishedFlag = true
        checkPCMStreamDrained()
    }

    /// VPIO modunda oynatma kuyruğu boşaldı mı (drain). Diğer durumlarda true.
    private var vpioDrained: Bool {
        #if os(macOS)
        if pipeline.useVPIO { return pipeline.vpio.pendingPlayback == 0 }
        #endif
        return true
    }

    #if os(macOS)
    private static let vpioFmt = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: VPIOEngine.sampleRate,
        channels: 1, interleaved: false)!

    /// Tek-buffer (play(data:)/play(buffer:)) VPIO oynatması: kuyruğa ekle,
    /// kuyruk boşalana kadar bekle. `isPlaying=false` (barge-in/stop) erken çıkar.
    private func playViaVPIO(_ buffer: AVAudioPCMBuffer) async {
        isPlaying = true
        startAmplitudeMetering()
        enqueueVPIO(buffer)
        // İlk render callback'i kuyruğu tüketmeye başlayana kadar pendingPlayback>0;
        // tamamen duyulana (kuyruk 0) kadar bekle.
        while isPlaying, pipeline.vpio.pendingPlayback > 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        isPlaying = false
        stopAmplitudeMetering()
    }

    /// Gelen TTS parçasını 48k mono float'a çevirip VPIO çıkış kuyruğuna ekle.
    private func enqueueVPIO(_ buffer: AVAudioPCMBuffer) {
        let target = Self.vpioFmt
        let conv: AVAudioPCMBuffer
        if buffer.format.sampleRate != target.sampleRate
            || buffer.format.channelCount != target.channelCount {
            conv = (try? Self.resample(buffer, to: target)) ?? buffer
        } else {
            conv = buffer
        }
        guard conv.format.channelCount == 1, let ch = conv.floatChannelData else { return }
        pipeline.vpio.enqueuePlayback(ch[0], count: Int(conv.frameLength))
    }
    #endif

    /// Stream tamamen çalınana (audio_end + tüm parçalar duyuldu) kadar bekle.
    /// Güvenlik: yanıt gelmezse (WS koptu / audio_end gelmedi) sonsuza dek
    /// "Konuşuyorum"da asılma — zaman aşımıyla çık.
    /// true döner = zaman aşımıyla bitti (çağıran sunucu turunu iptal etmeli ki
    /// geciken ses açık mikrofona çalmasın).
    @discardableResult
    func waitForPCMStreamDrained() async -> Bool {
        let start = Date()
        var timedOut = false
        while !(streamFinishedFlag && streamPending <= 0 && vpioDrained) {
            if !isPlaying { break }                  // stopPCMStream çağrıldı
            let elapsed = Date().timeIntervalSince(start)
            // STT + LLM + TTS ilk parçası aynı pencerede: dev sunucuda (Mac,
            // Codex + MPS) 6 sn yetmiyordu — tur erken bitip geciken ses açık
            // mikrofona karışıyordu.
            if !streamStarted && elapsed > 30 {
                Log.line("[Player] yanıt gelmedi (30s) — tur bitiriliyor")
                timedOut = true
                break
            }
            if elapsed > 180 {                        // mutlak güvenlik üst sınırı
                Log.line("[Player] drain timeout (180s) — tur bitiriliyor")
                timedOut = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        streamDrainYield = nil
        isPlaying = false
        EchoCanceller.shared.end()
        stopAmplitudeMetering()
        return timedOut
    }

    private func checkPCMStreamDrained() {
        if streamFinishedFlag && streamPending <= 0 {
            let yield = streamDrainYield
            streamDrainYield = nil
            yield?()
        }
    }

    /// Realtime stream'i zorla durdur (barge-in / cancel). Bekleyen continuation'ı
    /// resume eder, kuyruğu temizler.
    func stopPCMStream() {
        #if os(macOS)
        if pipeline.useVPIO { pipeline.vpio.flushPlayback() }
        #endif
        pipeline.playerNode.stop()
        streamPending = 0
        streamFinishedFlag = true
        let yield = streamDrainYield
        streamDrainYield = nil
        isPlaying = false
        EchoCanceller.shared.end()
        stopAmplitudeMetering()
        yield?()
    }

    func stop() {
        #if os(macOS)
        if pipeline.useVPIO { pipeline.vpio.flushPlayback() }
        #endif
        pipeline.playerNode.stop()
        // Realtime stream aktifse onu da çöz.
        if streamDrainYield != nil || streamPending > 0 || streamStarted {
            streamPending = 0
            streamFinishedFlag = true
            let yield = streamDrainYield
            streamDrainYield = nil
            streamStarted = false
            yield?()
        }
        EchoCanceller.shared.end()
        handleFinish(success: true)
    }

    private func handleFinish(success: Bool) {
        let cont = continuation
        continuation = nil
        if success {
            cont?.resume(returning: ())
        } else {
            cont?.resume(throwing: NSError(
                domain: "AudioPlayer", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Playback failed"]
            ))
        }
    }

    private func startAmplitudeMetering() {
        // AVAudioPlayerNode'da doğrudan amplitude metering yok.
        // Player çalarken görsel cue için yumuşak rastgele dalga üret.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            var playing = self.pipeline.playerNode.isPlaying
            #if os(macOS)
            // VPIO modunda playerNode hiç çalmaz → çalma durumunu VPIO kuyruğundan oku.
            if self.pipeline.useVPIO { playing = self.pipeline.vpio.pendingPlayback > 0 }
            #endif
            if playing {
                self.amplitude = 0.30 + 0.25 * Float.random(in: 0...1)
            } else {
                self.amplitude = 0
            }
        }
        timer.resume()
        amplitudeTimer = timer
    }

    private func stopAmplitudeMetering() {
        amplitudeTimer?.cancel()
        amplitudeTimer = nil
        amplitude = 0
    }

    static func detectFileType(_ data: Data) -> String? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data.prefix(4))
        if b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 {
            return AVFileType.wav.rawValue
        }
        if b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
            return AVFileType.mp3.rawValue
        }
        if b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 {
            return AVFileType.mp3.rawValue
        }
        if b[0] == 0x4F, b[1] == 0x67, b[2] == 0x67, b[3] == 0x53 {
            return "org.xiph.ogg-audio"
        }
        return nil
    }

    static func resample(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            throw NSError(domain: "AudioPlayer", code: -300,
                          userInfo: [NSLocalizedDescriptionKey: "Converter init failed"])
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw NSError(domain: "AudioPlayer", code: -301,
                          userInfo: [NSLocalizedDescriptionKey: "Resample buffer alloc failed"])
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error, let convError {
            throw convError
        }
        return out
    }

    static func decode(data: Data, hint: String?) throws -> AVAudioPCMBuffer {
        let ext: String = {
            if let hint, hint.contains("mp3") { return "mp3" }
            if let hint, hint.contains("wav") { return "wav" }
            return "m4a"
        }()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tts-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(
                domain: "AudioPlayer", code: -100,
                userInfo: [NSLocalizedDescriptionKey: "PCM buffer allocation failed"]
            )
        }
        try file.read(into: buffer)
        return buffer
    }
}
