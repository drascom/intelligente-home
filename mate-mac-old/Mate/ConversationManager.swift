import Foundation
import AVFoundation
import Combine

enum ConversationState: Equatable {
    case idle
    case waitingPermission
    case waitingForWake
    case listening
    case transcribing
    case synthesizing
    case speaking
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Duraklatıldı"
        case .waitingPermission: return "İzinler bekleniyor"
        case .waitingForWake: return "Wake word bekleniyor…"
        case .listening: return "Dinliyorum…"
        case .transcribing: return "Yazıya döküyorum…"
        case .synthesizing: return "Ses üretiliyor…"
        case .speaking: return "Konuşuyorum…"
        case .error(let msg): return "Hata: \(msg)"
        }
    }

    /// State'e uygun temiz, kısa alt başlık (UI'da `label`'ın altında gösterilir).
    /// Ham diagnosticStatus yerine kullanıcı dostu metin. waitingForWake için
    /// metin ContentView'de wake kelimesiyle birleştirilir, burada boş döner.
    var subtitle: String {
        switch self {
        case .idle: return "Başlat'a bas"               // eylem ipucu
        case .listening: return "konuşabilirsin"        // ipucu (label'ı tekrar etmez)
        case .waitingForWake: return ""                 // ContentView wake kelime ipucunu üretir
        case .speaking: return ""                       // ContentView barge-in ipucunu üretir
        case .waitingPermission, .transcribing, .synthesizing, .error:
            return ""
        }
    }
}

/// Sohbet feed'inde gösterilen tek bir konuşma satırı.
struct ChatMessage: Identifiable {
    let id = UUID()
    enum Role { case user, assistant }
    let role: Role
    let text: String
}

@MainActor
final class ConversationManager: ObservableObject {
    @Published private(set) var state: ConversationState = .idle
    @Published private(set) var lastTranscript: String = ""
    /// Sohbet feed'i: user/assistant satırları, en yeni sonda. Son ~20 tutulur.
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var diagnosticStatus: String = ""
    /// Sunucuya (bridge) erişilebilirlik: nil=henüz bilinmiyor, true=bağlı, false=yok.
    /// false iken ana ekranda "Sunucu bağlantısı yok" banner'ı gösterilir.
    @Published private(set) var serverConnected: Bool?
    @Published var isRunning: Bool = false
    // Geçici sessize alma: mic kapatılır (recorder+wake durur) ama bridge/oturum
    // korunur. true iken hiçbir dinleme döngüsü mic'i yeniden açmaz.
    @Published private(set) var muted: Bool = false
    // SwiftUI nested ObservableObject re-render etmiyor; recorder.level ve
    // player.amplitude'ı buradan re-publish edip view'lar conversation'a
    // bağlandığında otomatik güncellensin.
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputAmplitude: Float = 0

    let recorder = AudioRecorder()
    let player = AudioPlayer()
    let wake = WakeWordDetector()
    /// Canlı (streaming) cihaz-içi STT. Segment boyunca mic buffer'ları beslenir;
    /// VAD turu kapanınca transcript hazır. Boş dönerse OnDeviceSTT.transcribe yedek.
    private let liveSTT = LiveSTT()
    /// Canlı STT şu an besleniyor mu? (mükerrer start/cancel'ı önlemek için)
    private var liveSTTActive = false
    private let cues = CueSounds()
    private let bridge = RealtimeBridgeClient()
    private weak var settings: SettingsStore?
    private var routeObserver: NSObjectProtocol?
    private var levelBridges = Set<AnyCancellable>()

    // Realtime bridge: aktif speak isteğinin id'si (barge-in cancel için) ve
    // stream sırasında oluşan hata mesajı.
    private var realtimeActiveId: String?
    private var realtimeError: String?

    private func playCue(_ play: () -> Void) {
        guard settings?.cuesEnabled == true else { return }
        play()
    }

    // VAD
    private var speechStartedAt: Date?
    private var lastVoiceAt: Date?
    private var listeningLoopActive = false
    // macOS: ham mikrofon (VP/AGC yok) iPhone'dan çok daha sessiz — 0.28
    // tabanını konuşma hiç aşamıyordu (log: noise 0.037, konuşma tetiklemedi).
    // Ölçüm (Huawei BT kulaklık): konuşma ~-50dB (~0.09), vurgular -41dB,
    // ortam -67..-71dB (~0.00) → eşik 0.08 ≈ -50.6dB; ortamın 16dB üstü,
    // konuşmanın hemen altı.
    #if os(macOS)
    private let voiceThreshold: Float = 0.08          // baseline — adaptive when filter on
    private let calibrationMargin: Float = 0.05       // floor + margin (BT mic kısık)
    #else
    private let voiceThreshold: Float = 0.28          // baseline — adaptive when filter on
    private let calibrationMargin: Float = 0.13
    #endif
    private let silenceTimeout: TimeInterval = 1.2   // konuşma-sonu sessizlik (dengeli: boşlukta böler, kısa duraksamaya tolerans)
    // 30 → 15: kaçak VAD segmentleri (arka plan TV/müzik) yarıda kesilsin;
    // normal komutlar zaten 15 sn'den kısa.
    private let maxRecordingDuration: TimeInterval = 15.0
    // 0.9 → 0.35: kısa ama GERÇEK yanıtlar ("Ne vardı?" ölçülen sesli süre=0.46s,
    // "Efendim?" ~0.4s) silence-close koşulundaki speechDur>=min eşiğini geçemiyordu
    // → segment kapanmayıp maxRecordingDuration'a (15s) kadar açık kalıyor, yanıt
    // ~9s gecikiyordu (proaktif bildirim regresyonu, log: "close BLOKE speechDur=0.46<0.90").
    // 0.35 < 0.46 → kısa yanıtlar kapanır. Kuş/klik koruması zaten VAD tetiğindeki
    // ardışık-frame şartı (voiceFramesRequired) + isLikelyNoise/boş-transkript filtresiyle.
    private let minSpeechDuration: TimeInterval = 0.35  // gerçek konuşma min süresi (kuş/klik/noise burst'lerine karşı)
    private let postPlaybackDelay: UInt64 = 200_000_000  // AEC aktif, TTS tail az → kısa delay
    private let engineWarmupSeconds: Double = 0.9  // wake sonrası motor/VPIO soğuk başlangıç ısınması
    // "Konuş" bip'i (playWakeDetected ≈0.185s) VPIO çıkış kuyruğundan çalınca, kuyruk
    // boşalana + AEC artığı yatışana kadar girişi yok say. Aksi halde ilk VAD kararı
    // bip'in kuyruğuna/echo'suna kilitlenip segmenti erken açıyor → ilk kelime ("Efendim?")
    // bip artığıyla birleşip Whisper tarafından düşüyor (proaktif bildirim regresyonu).
    private let readyCueSettleSeconds: Double = 0.45
    // 15 → 6: cevaptan sonra sessizlik varsa hızla wake moduna dön (açık
    // mikrofonun gürültü yakalama penceresi daralır).
    private let followUpInactivity: TimeInterval = 6.0
    // Proaktif hatırlatma chime'ı sonrası yanıt penceresi: kullanıcı uzakta olabilir,
    // bu süre içinde konuşmazsa bekleme moduna dön (hatırlatma pending kalır).
    private let reminderResponseTimeout: TimeInterval = 30.0
    private var turnStartedAt: Date?

    // Adaptive noise filter
    private var noiseSamples: [Float] = []
    private let calibrationFrameCount = 6      // cihazda ~100ms/frame → ~600ms ambient calibration
    #if os(macOS)
    private var calibratedThreshold: Float = 0.08
    #else
    private var calibratedThreshold: Float = 0.28
    #endif
    private var voiceFramesAccum: Int = 0
    private var readyCuePending = false
    private var ignoreInputUntil: Date?
    // macOS: BT mikrofonda konuşma eşiğin hemen üstünde gezdiği için 4 ardışık
    // kare şartı tetiklemeyi kaçırıyordu → 2 (~200ms).
    #if os(macOS)
    private let voiceFramesRequired = 2
    #else
    private let voiceFramesRequired = 4        // cihazda ~400ms hysteresis: kısa burst'ler tetiklemesin
    #endif

    // Barge-in (TTS çalarken kullanıcı sözünü kessin)
    private var bargeInEchoSamples: [Float] = []
    private let bargeInCalibFrames = 6
    private var bargeInTotalFrames = 0
    private let bargeInWarmupFrames = 10        // 500ms AEC cold-start convergence
    private let bargeInCalibTimeoutFrames = 16  // 800ms — kalibrasyon mutlaka bu kadar sonra biter
    private var bargeInThreshold: Float = 1.5   // çok yüksek → kalibrasyon olana kadar tetiklemez
    private var bargeInSustained = 0
    private let bargeInSustainedRequired = 4    // ~200ms ardışık eşik üstü (anlık dalgalanma değil)
    private var bargeInTriggered = false
    private var bargeInPeakLevel: Float = 0

    // Whisper'ın sessiz/gürültülü inputta sıkça uydurduğu Türkçe çıktılar.
    // Tek-kelime VE bu listede ise atılır.
    private static let hallucinationWords: Set<String> = [
        "in", "çık", "gel", "git", "sen", "ben", "biz", "siz",
        "evet", "hayır", "hı", "ı", "a", "ah", "aa", "eh", "hm",
        "ya", "yok", "var", "tamam", "ok", "ohh", "oh"
    ]
    private static let hallucinationPhrases: Set<String> = [
        "altyazı m.k.", "altyazı m. k.", "dipnot.com", "türkçe altyazı",
        "iyi seyirler", "teşekkürler", "abone olmayı unutmayın",
        "altyazı: mehmet", "altyazılar: m. k.", "altyazılar: mehmet",
        "izlediğiniz için teşekkür ederim", "beni izlediğiniz için teşekkür ederim",
        "dinlediğiniz için teşekkür ederim", "abone ol", "abone olun",
        "kanalıma abone ol", "kanalıma abone olun", "abone olmayı unutmayın"
    ]

    func attach(settings: SettingsStore) {
        self.settings = settings
        recorder.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                switch self.state {
                case .listening:
                    self.handleLevel(level)
                case .speaking:
                    self.handleBargeInLevel(level)
                default:
                    break
                }
            }
        }
        // NOT: Canlı STT geçici DEVRE DIŞI (VPIO ses oturumunu sarsıp ilk segmenti
        // sessizleştiriyordu). onBuffer beslemesi kaldırıldı; batch STT kullanılıyor.
        wake.onWakeDetected = { [weak self] in
            Task { @MainActor in self?.handleWakeDetected() }
        }
        // macOS: Siri + Dikte kapalıysa SFSpeech (wake word) hiç çalışmaz —
        // sessizce sağır beklemek yerine kullanıcıyı sistem ayarına yönlendir.
        wake.onUnavailable = { [weak self] _ in
            Task { @MainActor in
                self?.state = .error(
                    "Konuşma tanıma kapalı. Wake word için Sistem Ayarları → Klavye → Dikte'yi aç, sonra Yeniden dene."
                )
            }
        }
        // Realtime bridge olayları → AudioPlayer PCM stream yoluna bağla.
        // Sunucu STT sonucu (ses-yukarı modu) → bekleyen turu çözer.
        bridge.onTranscript = { [weak self] _, text in
            self?.resolveTranscript(text)
        }
        // Brain cevap metnini `reply` mesajıyla yollar → asistan satırı feed'e
        // + cihaz TTS modunda bekleyen turu çöz.
        bridge.onReply = { [weak self] _, text in
            self?.appendMessage(.assistant, text)
            self?.resolveReply(text)
        }
        // Ses olayları yalnız AKTİF turun id'siyle işlenir — iptal edilmiş/geç
        // kalmış turun sesi açık mikrofona çalınmasın.
        bridge.onAudioStart = { [weak self] id, _, _ in
            guard let self, id == self.realtimeActiveId else { return }
            // Ses GERÇEKTEN şimdi başlıyor → orb "konuşuyor"a burada geçer
            // (transkriptten hemen sonra değil; arada LLM+TTS düşünme süresi var).
            self.state = .speaking
            self.applyAudioRoute()
        }
        bridge.onAudioChunk = { [weak self] id, buffer in
            guard let self, id == self.realtimeActiveId else { return }
            self.player.streamPCM(buffer: buffer)
        }
        bridge.onAudioEnd = { [weak self] id in
            guard let self, id == self.realtimeActiveId else { return }
            self.player.finishPCMStream()
        }
        bridge.onError = { [weak self] _, message in
            guard let self else { return }
            self.realtimeError = message
            self.resolveTranscript(nil)   // sunucu STT bekliyorsa hata ile çöz
            self.resolveReply(nil)        // cevap bekleyen cihaz-TTS turu varsa çöz
            self.player.finishPCMStream()
        }
        bridge.onReachable = { [weak self] reachable in
            self?.serverConnected = reachable
        }
        // Proaktif hatırlatma chime'ı: bekleyen hatırlatma var → belirgin ton çal,
        // SONRA otomatik dinlemeye geç (kullanıcı "candan" demeden yanıt versin).
        // Kullanıcı "dinliyorum / ne vardı" derse sunucu mesajı söyler; "meşgulüm /
        // sonra" derse erteler. Cue ayarından bağımsız çalar.
        bridge.onChime = { [weak self] in
            guard let self else { return }
            self.cues.playReminderChime()
            guard self.isRunning, !self.muted else { return }  // duraklıysa yalnız ton
            switch self.state {
            case .waitingForWake:
                self.wake.stop()                 // wake motorunu bırak, dinlemeye geç
                self.handleChimeListen()
            case .idle:
                self.handleChimeListen()         // çalışıyor ama wake kapalı → doğrudan dinle
            default:
                // tur/konuşma ortasında dokunma — AMA chime tonu (playReminderChime)
                // bu açık VPIO segmentine sızıp lastVoiceAt'i tazeleyerek segmenti
                // uzatabilir/böremez (yanıt gecikmesi). Teşhis için durumu logla.
                Log.line("[Chime] state=\(self.state) — yeni pencere açılmadı (segment açıksa chime içine sızabilir)")
            }
        }
        bridge.onClose = { [weak self] reason in
            guard let self else { return }
            Log.line("[Bridge] closed: \(reason)")
            // Akış ortasında koptuysa bekleyen continuation resume olsun.
            self.player.finishPCMStream()
        }
        // Nested observable bridge: recorder/player @Published değişiklikleri
        // ConversationManager'ı tetiklesin → SwiftUI view'lar refresh olur.
        // throttle(40ms): ses tap'i ~100Hz seviye üretiyor; her biri tüm view
        // ağacını yeniden çizdirip main thread'i boğuyordu (Settings açıkken
        // donma). UI için ~25Hz yeter — VAD/barge-in yolu (onLevel) tam hızda.
        levelBridges.removeAll()
        recorder.$level
            .throttle(for: .milliseconds(40), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.inputLevel = $0 }
            .store(in: &levelBridges)
        player.$amplitude
            .throttle(for: .milliseconds(40), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.outputAmplitude = $0 }
            .store(in: &levelBridges)

    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await startListeningCycle() }
    }

    private func configureAudioSession() throws {
        #if os(macOS)
        // macOS'ta AVAudioSession yok: engine'ler sistem varsayılanını izler;
        // kullanıcının ana ekranda seçtiği mic/hoparlör varsayılana uygulanır.
        MacAudioDevices.applyStoredSelection()
        Log.line("[Session] macOS — giriş/çıkış: sistem varsayılanı (+kayıtlı seçim)")
        #else
        let session = AVAudioSession.sharedInstance()
        // .defaultToSpeaker KASTEN YOK: bu flag aktifken `.overrideOutputAudioPort(.none)`
        // "sistem default'u kullan" = "speaker'a dön" demek oluyor — BT seçimini iptal ediyor.
        // Bunun yerine applyAudioRoute() içinde manuel olarak speaker'a override ediyoruz.
        // Mode = .voiceChat: AVAudioEngine voice processing (AEC) için gerekli — .default'ta
        // VP IO unit input'u silently bypass edebiliyor.
        // .allowBluetoothA2DP YOK: voiceChat ile çakışıyor — A2DP output-only profil,
        // mic için kullanılmaz, ama session'da bulunması VPIO graph'ını kıllayabiliyor.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP]
        )
        // AEC convergence için: 48kHz input/output uniform sample rate +
        // 10ms IO buffer (echo path estimation hızlanır).
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true, options: [])
        Log.line(String(format: "[Session] sr=%.0fHz  ioBuf=%.3fs  mode=%@",
                     session.sampleRate, session.ioBufferDuration, session.mode.rawValue))
        applyAudioRoute()
        registerRouteObserver()
        #endif
    }


    /// Dışarıdan bir audio cihazı (BT, wired, CarPlay, USB) bağlıysa onu kullan;
    /// yoksa telefon hoparlörünü zorla. Ek olarak BT mic varsa preferred input'a
    /// çevir — aksi halde recorder başlarken iOS HFP route'u düşürebiliyor.
    private func applyAudioRoute() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Input: BT mic / headset mic / USB varsa onu tercih et
        let externalInputs: Set<AVAudioSession.Port> = [
            .bluetoothHFP, .bluetoothLE, .headsetMic, .usbAudio
        ]
        let preferredInput = session.availableInputs?.first(where: {
            externalInputs.contains($0.portType)
        })
        do { try session.setPreferredInput(preferredInput) }
        catch { Log.line("[Route] setPreferredInput failed: \(error)") }
        // Output: external varsa override'ı kaldır, yoksa speaker'a zorla
        let hasExternal = hasExternalAudioRoute()
        do {
            if hasExternal {
                try session.overrideOutputAudioPort(.none)
            } else {
                try session.overrideOutputAudioPort(.speaker)
            }
        } catch {
            Log.line("[Route] override failed: \(error)")
        }
        let outs = session.currentRoute.outputs.map { $0.portName }.joined(separator: ", ")
        let ins = session.currentRoute.inputs.map { $0.portName }.joined(separator: ", ")
        Log.line("[Route] out=\(hasExternal ? "external" : "speaker") (\(outs))  in=(\(ins))  preferredIn=\(preferredInput?.portName ?? "system")")
        #endif
    }

    /// Output route'da BT/wired/AirPlay/USB var mı?
    /// applyAudioRoute ile birebir aynı mantık — barge-in karar tutarlığı için.
    private func hasExternalAudioRoute() -> Bool {
        #if os(iOS)
        let external: Set<AVAudioSession.Port> = [
            .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
            .headphones, .headsetMic, .usbAudio,
            .airPlay, .carAudio, .lineOut
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            external.contains($0.portType)
        }
        #else
        // macOS: rota bilgisine bu API ile erişilemiyor; hoparlör varsay —
        // barge-in eko kalibrasyonu en temkinli (hoparlör) profille çalışır.
        return false
        #endif
    }

    private func registerRouteObserver() {
        #if os(iOS)
        guard routeObserver == nil else { return }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyAudioRoute() }
        }
        #endif
    }

    func stop() {
        isRunning = false
        cancelLiveSTT()
        recorder.stop()
        player.stop()
        wake.stop()
        bridge.disconnect(reason: "stop")
        realtimeActiveId = nil
        state = .idle
        diagnosticStatus = ""
    }

    /// Sohbet feed'ine bir satır ekler; en fazla son 20 mesajı tutar.
    private func appendMessage(_ role: ChatMessage.Role, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: role, text: trimmed))
        if messages.count > 20 {
            messages.removeFirst(messages.count - 20)
        }
    }

    private func mark(_ message: String) {
        let elapsed: String
        if let start = turnStartedAt {
            elapsed = String(format: " +%.1fs", Date().timeIntervalSince(start))
        } else {
            elapsed = ""
        }
        diagnosticStatus = message + elapsed
        Log.line("[Flow]\(elapsed) \(message)")
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    /// Geçici sessize alma: mic'i kapat/aç. Bridge bağlantısı ve oturum korunur
    /// (stop()'tan farkı bu). Sadece uygulama çalışırken anlamlı.
    func toggleMute() {
        guard isRunning else { return }
        if muted {
            muted = false
            Task { await enterIdleOrListen() }   // mic'i geri aç (wake/dinleme)
        } else {
            muted = true
            cancelLiveSTT()
            _ = recorder.stop()
            AudioPipeline.shared.pause()
            wake.stop()
            state = .idle
            diagnosticStatus = "Mikrofon kapalı (sessize alındı)"
        }
    }

    private func startListeningCycle() async {
        guard await checkRequiredServices() else { return }
        state = .waitingPermission
        let micGranted = await recorder.requestPermission()
        guard micGranted else {
            state = .error("Mikrofon izni reddedildi. Ayarlar'dan açın.")
            isRunning = false
            return
        }
        // Cihaz STT her zaman açık olduğu için konuşma tanıma izni her durumda gerekir.
        let speechGranted = await wake.requestPermission()
        guard speechGranted else {
            state = .error("Konuşma tanıma izni reddedildi. Cihaz STT için gerekli.")
            isRunning = false
            return
        }
        do {
            try configureAudioSession()
            // Pre-warm: ilk recording'de VP setup gecikmesini şimdi öde
            try AudioPipeline.shared.prepareIfNeeded()
        } catch {
            state = .error("Audio session: \(error.localizedDescription)")
            isRunning = false
            return
        }
        await enterIdleOrListen()
    }

    private func checkRequiredServices() async -> Bool {
        guard let settings else {
            state = .error("Ayarlar yüklenemedi.")
            isRunning = false
            return false
        }
        turnStartedAt = Date()

        // STT cihazda yapılır. Cihaz TTS yedek olarak açıksa bridge'e hiç bağlanmadan
        // devam et — internet/sunucu gerekmez. Aksi halde WS bağlantısını şimdi kur;
        // başarısız olursa speakViaRealtime cihaz TTS'e düşeceği için yine de devam et.
        mark("STT: cihaz üzerinde (Apple Speech)")
        if settings.useOnDeviceTTS {
            mark("TTS: cihaz üzerinde (AVSpeechSynthesizer)")
            turnStartedAt = nil
            return true
        }

        do {
            try bridge.connect(urlString: settings.bridgeWSURL, token: settings.bridgeApiKey)
            mark("Realtime bridge bağlanıyor: \(settings.bridgeWSURL)")
        } catch {
            // Bağlantı kurulamadı: hata gösterip durma — konuşma anında cihaz TTS'e
            // düşülür. Yine de kullanıcıyı bilgilendir.
            mark("Realtime bridge bağlanamadı, cihaz TTS yedeği kullanılacak: \(error.localizedDescription)")
        }
        turnStartedAt = nil
        return true
    }

    private func enterIdleOrListen() async {
        guard isRunning, !muted else { return }
        if settings?.wakeWordEnabled == true {
            startWakeListening()
        } else {
            await beginListening()
        }
    }

    private func startWakeListening() {
        guard isRunning, !muted, let settings else { return }
        // Wake kendi AVAudioEngine'ini kullanıyor — recorder tap'ını tamamen
        // kaldırıp pipeline engine'i durdur ki iki engine mic donanımını
        // çekiştirmesin. Aksi halde wake sonrası ilk cümlede stale tap / paused
        // engine yüzünden VAD segmenti kapanmayabiliyor.
        _ = recorder.stop()
        cancelLiveSTT()
        // VPIO (raw AUVoiceProcessingIO) default cihazı bırakıyor. CoreAudio HAL
        // teardown'u ASENKRON: dispose döndükten sonra cihaz birkaç yüz ms daha
        // "bad device" (kAudioHardwareBadDeviceError / '!dev' = 560227702)
        // kalabiliyor ve wake'in taze AVAudioEngine.start()'ı bununla patlıyor →
        // wake hiç kurulamıyor, re-arm ölüyordu. VPIO aktifken (ör. wake'i
        // Ayarlar'dan kapat→kullan→aç) teardown penceresi büyüdüğü için her
        // seferinde tekrar üretiliyordu. Çözüm: VPIO'yu durdur, kısa settle ver,
        // sonra başlat; ilk deneme yine patlarsa backoff'lu retry (re-arm
        // gecikmesi kullanıcıya görünmez).
        var vpioWasRunning = false
        #if os(macOS)
        vpioWasRunning = AudioPipeline.shared.vpio.running
        #endif
        AudioPipeline.shared.pause()
        if vpioWasRunning {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms HAL serbest kalsın
                self.startWakeWithRetry(attempt: 0)
            }
        } else {
            startWakeWithRetry(attempt: 0)
        }
    }

    private func startWakeWithRetry(attempt: Int) {
        guard isRunning, !muted, let settings else { return }
        // Yarış güvenliği: bir şekilde VPIO yeniden başladıysa (ör. araya giren
        // oynatma) önce onu bırak — iki birim aynı cihazı çekiştirmesin.
        #if os(macOS)
        if AudioPipeline.shared.vpio.running { AudioPipeline.shared.pause() }
        #endif
        do {
            try wake.start(wakeWord: settings.wakeWord, language: settings.language)
            state = .waitingForWake
        } catch {
            let maxAttempts = 6
            if attempt + 1 < maxAttempts {
                Log.line("[Wake] start başarısız (\(error.localizedDescription)) → \(attempt + 2). deneme (cihaz serbest kalmıyor)")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms HAL serbest kalsın
                    guard self.isRunning, !self.muted,
                          self.state != .waitingForWake else { return }
                    self.startWakeWithRetry(attempt: attempt + 1)
                }
            } else {
                Log.line("[Wake] start kalıcı başarısız (\(maxAttempts) deneme): \(error.localizedDescription)")
                state = .error("Wake başlatılamadı: \(error.localizedDescription)")
            }
        }
    }

    private func handleWakeDetected() {
        guard isRunning, !muted else { return }
        Log.line("[Wake] detected → switching to listening")
        // Tek bip: ısınma bitince "konuş" bip'i (beginListening içinde) çalar.
        // Algılama anında ayrı bip YOK.
        Task {
            // Önce kısa ortam kalibrasyonu yap, sonra bip çal. Böylece kullanıcı
            // bip'i duyunca konuşacağını bilir; kuş/fan gibi sesler de baseline'a girer.
            await beginListening(withInactivityTimeout: true, playReadyCueAfterCalibration: true)
        }
    }

    /// Proaktif hatırlatma chime'ı sonrası: "konuş" bip'i + dinle. Kullanıcı uzakta
    /// olup hemen yanıt vermeyebilir → reminderResponseTimeout (30s) sessizlikte
    /// bekleme moduna döner (hatırlatma pending kalır, sonra teslim edilir).
    private func handleChimeListen() {
        guard isRunning, !muted else { return }
        Log.line("[Chime] → otomatik dinleme (30s yanıt penceresi)")
        Task {
            await beginListening(withInactivityTimeout: true, playReadyCueAfterCalibration: true,
                                 inactivityTimeout: reminderResponseTimeout)
        }
    }

    private func beginListening(
        withInactivityTimeout: Bool = false,
        preserveVAD: Bool = false,
        playReadyCueAfterCalibration: Bool = false,
        echoSettle: Double = 0,
        inactivityTimeout: TimeInterval? = nil
    ) async {
        guard isRunning, !muted else { return }
        if !preserveVAD {
            resetVAD()
            readyCuePending = playReadyCueAfterCalibration
        }
        // TTS sonrası yankı yatışma penceresi: hoparlörden çıkan TTS'in kuyruğu
        // (AEC artığı) bogus/boş segment açmasın diye VAD'i kısa süre sustur.
        if echoSettle > 0 {
            ignoreInputUntil = Date().addingTimeInterval(echoSettle)
        }
        // Wake AVAudioEngine'den AVAudioRecorder'a geçişte iOS BT input'u
        // bazen düşürüyor — recorder başlamadan önce route'u re-affirm et.
        applyAudioRoute()
        do {
            if !recorder.isRecording {
                try recorder.startMonitoring()
            }
            // Wake sonrası motor SOĞUK başlar (VPIO/AEC ~0.9s converge eder); bu sürede
            // mikrofon düzgün yakalamaz. Isınma boyunca girişi yok say — kalibrasyon ve
            // "konuş" bipi ısınma bitince (sıcak motorda) çalışır, kullanıcı bip'ten
            // SONRA konuşunca ilk kelimeler yakalanır.
            if playReadyCueAfterCalibration {
                ignoreInputUntil = Date().addingTimeInterval(engineWarmupSeconds)
                // "Konuş" bipini ısınma SONUNDA çal — kalibrasyondan bağımsız. (Önceden bip
                // kalibrasyona bağlıydı; gürültü filtresi kapalıyken hiç çalmıyordu.)
                readyCuePending = false
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(engineWarmupSeconds * 1_000_000_000))
                    guard let self, self.isRunning, self.state == .listening,
                          self.speechStartedAt == nil else { return }
                    self.playCue { self.cues.playWakeDetected() }
                    // Bip ısınma sonunda çalınca ignoreInputUntil (line ~576) tam o anda
                    // doluyor; bip VPIO kuyruğundan çalınırken mic CANLI kalıyordu. Bip
                    // çaldıysa girişi bip süresi + drain/echo yatışması kadar daha sustur ki
                    // ilk segment bip artığı yerine kullanıcının ilk kelimesiyle açılsın
                    // (preRoll bip'ten sonraki konuşmanın başını yine de geri alır).
                    if self.settings?.cuesEnabled == true {
                        self.ignoreInputUntil = Date().addingTimeInterval(self.readyCueSettleSeconds)
                    }
                }
            }
            state = .listening

            guard !listeningLoopActive else { return }
            listeningLoopActive = true
            let startTime = Date()
            let noSpeechLimit: TimeInterval = inactivityTimeout
                ?? (withInactivityTimeout ? followUpInactivity : .infinity)
            Task { @MainActor [weak self] in
                while let self, self.recorder.isRecording, self.state == .listening {
                    let elapsed = Date().timeIntervalSince(startTime)
                    // No speech within follow-up window → abort silently, back to wake
                    if self.speechStartedAt == nil && elapsed > noSpeechLimit {
                        _ = self.recorder.stop()
                        self.cancelLiveSTT()
                        self.listeningLoopActive = false
                        Log.line("[FollowUp] \(Int(elapsed))s sessizlik → wake'e dön")
                        self.playCue { self.cues.playSleeping() }
                        await self.enterIdleOrListen()
                        return
                    }
                    if elapsed > self.maxRecordingDuration {
                        self.listeningLoopActive = false
                        await self.endRecording()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                self?.listeningLoopActive = false
            }
        } catch {
            state = .error(error.localizedDescription)
            isRunning = false
        }
    }

    private func resetVAD() {
        speechStartedAt = nil
        lastVoiceAt = nil
        noiseSamples.removeAll()
        voiceFramesAccum = 0
        calibratedThreshold = voiceThreshold
        readyCuePending = false
        ignoreInputUntil = nil
    }

    private func startSpeechSegment(now: Date, preRollSeconds: Double = 1.15, triggerLevel: Float = -1) {
        guard speechStartedAt == nil else {
            lastVoiceAt = now
            return
        }
        do {
            // Canlı STT DEVRE DIŞI — batch STT kullanılıyor (VPIO disruption nedeniyle).
            _ = try recorder.beginSegment(includePreRoll: true, preRollSeconds: preRollSeconds)
            Log.line(String(format: "[VAD] trigger level=%.3f thr=%.3f", triggerLevel, calibratedThreshold))
            speechStartedAt = now
            lastVoiceAt = now
            Log.line("[VAD] speech started")
        } catch {
            state = .error("Kayıt başlatılamadı: \(error.localizedDescription)")
            isRunning = false
        }
    }

    /// Canlı STT oturumunu başlat (idempotent). Zaten aktifse no-op.
    private func startLiveSTT() {
        guard !liveSTTActive else { return }
        liveSTT.start(language: settings?.language ?? "tr-TR")
        liveSTTActive = true
    }

    /// Canlı STT oturumunu iptal et — sızıntı olmasın (barge-in / discard / no-speech).
    private func cancelLiveSTT() {
        guard liveSTTActive else { return }
        liveSTT.cancel()
        liveSTTActive = false
    }

    private func resetBargeIn() {
        bargeInEchoSamples.removeAll()
        bargeInTotalFrames = 0
        bargeInThreshold = 1.5
        bargeInSustained = 0
        bargeInTriggered = false
        bargeInPeakLevel = 0
    }

    private func handleBargeInLevel(_ level: Float) {
        guard state == .speaking, settings?.bargeInEnabled == true else { return }
        bargeInTotalFrames += 1
        bargeInPeakLevel = max(bargeInPeakLevel, level)

        // AEC cold-start convergence süresi: ilk 500ms boyunca echo path
        // estimation henüz oturmadığı için sızıntı yüksek olabilir — bu
        // pencerede hiçbir karar verme, immediate-speech path'i de aktif değil.
        if bargeInTotalFrames <= bargeInWarmupFrames {
            return
        }

        // Enerji-kapılı double-talk (macOS): coupling kalibre olana kadar karar
        // verme. iOS'ta AEC.active=false (donanım VPIO) → bu kapı atlanır.
        if EchoCanceller.shared.active && !EchoCanceller.shared.ready {
            return
        }

        // Kalibrasyon: warm-up sonrası ~400ms içinde echo baseline'ı topla
        if bargeInThreshold > 1.0 {
            // Kullanıcı TTS başlar başlamaz araya girebilir. AEC artık warm —
            // 0.50+ level büyük ihtimal gerçek konuşma. Kalibrasyon beklemeden
            // hassas threshold'a geç.
            if level >= 0.50 {
                bargeInThreshold = 0.36
                Log.line(String(format: "[BargeIn] immediate speech level=%.3f → threshold=%.3f", level, bargeInThreshold))
            } else {
                bargeInEchoSamples.append(level)
                let calibrationDone = bargeInEchoSamples.count >= bargeInCalibFrames
                    || bargeInTotalFrames >= bargeInCalibTimeoutFrames
                if calibrationDone {
                    let baseline: Float = bargeInEchoSamples.isEmpty
                        ? 0.20
                        : bargeInEchoSamples.reduce(0, +) / Float(bargeInEchoSamples.count)
                    bargeInThreshold = max(baseline + 0.12, 0.30)
                    Log.line(String(format: "[BargeIn] echo=%.3f → threshold=%.3f", baseline, bargeInThreshold))
                } else {
                    return
                }
            }
        }

        if level > bargeInThreshold {
            bargeInSustained += 1
            if bargeInSustained >= bargeInSustainedRequired && !bargeInTriggered {
                bargeInTriggered = true
                Log.line("[BargeIn] kullanıcı sözünü kesti → TTS durduruluyor")
                // Realtime bridge aktifse sunucuya cancel gönder (kalan parçalar
                // üretilmesin), playerNode kuyruğunu boşalt.
                if let id = realtimeActiveId {
                    let activeId = id
                    realtimeActiveId = nil
                    player.stopPCMStream()
                    Task { try? await bridge.cancel(id: activeId) }
                } else {
                    player.stop()  // play() continuation resume olur, akış devam eder
                }
                resetVAD()
                cancelLiveSTT()  // TTS-dönemi tanımayı at, yeni segment için temiz başla
                startSpeechSegment(now: Date(), preRollSeconds: 0.55)
                Task { await beginListening(withInactivityTimeout: true, preserveVAD: true) }
            }
        } else {
            bargeInSustained = 0
        }
    }

    private func handleLevel(_ level: Float) {
        guard recorder.isRecording, isRunning else { return }
        let useFilter = settings?.noiseFilterEnabled ?? true
        let now = Date()
        if let until = ignoreInputUntil, now < until {
            return
        }

        // Adaptive calibration: dinleme başında ortam sesini ölç, eşiği uyarla.
        // Wake sonrası ready cue bekleniyorsa bu pencere boyunca konuşma başlatma;
        // kullanıcı bip'ten sonra konuşmalı.
        if useFilter && noiseSamples.count < calibrationFrameCount {
            if !readyCuePending && level > voiceThreshold {
                calibratedThreshold = voiceThreshold
                startSpeechSegment(now: now)
                return
            }
            // Çok yüksek transient'leri clamp et; aksi halde yoğun kuş sesi gibi
            // ortamlar kalibrasyonu hiç bitirmeyebilir.
            noiseSamples.append(min(level, 0.55))
            if noiseSamples.count == calibrationFrameCount {
                let avg = noiseSamples.reduce(0, +) / Float(noiseSamples.count)
                calibratedThreshold = max(avg + calibrationMargin, voiceThreshold)
                Log.line(String(format: "[VAD] noise floor=%.3f → threshold=%.3f", avg, calibratedThreshold))
                if readyCuePending {
                    readyCuePending = false
                    ignoreInputUntil = Date().addingTimeInterval(0.14)
                    playCue { cues.playWakeDetected() }
                }
            }
            return  // kalibrasyon sırasında VAD karar vermesin
        }

        let threshold = useFilter ? calibratedThreshold : voiceThreshold
        if level > threshold {
            if useFilter {
                voiceFramesAccum += 1
                if voiceFramesAccum < voiceFramesRequired { return }
            }
            startSpeechSegment(now: now, triggerLevel: level)
        } else {
            voiceFramesAccum = 0
            if let last = lastVoiceAt, let spoke = speechStartedAt {
                let silence = now.timeIntervalSince(last)
                let speechDur = last.timeIntervalSince(spoke)
                if silence >= silenceTimeout && speechDur >= minSpeechDuration {
                    Log.line(String(format: "[VAD] close: silence=%.2f speechDur=%.2f", silence, speechDur))
                    Task { await endRecording() }
                } else if silence >= silenceTimeout && silence < silenceTimeout + 0.22
                            && speechDur < minSpeechDuration {
                    // Sessizlik doldu ama konuşma minSpeechDuration'ı geçmediği için segment
                    // KAPANMIYOR — kısa "Ne vardı?" burada takılıp uzun segmente birleşiyor olabilir.
                    // (sadece eşik geçişinde 1-2 kez logla, ~100Hz spam olmasın)
                    Log.line(String(format: "[VAD] close BLOKE: silence=%.2f speechDur=%.2f < min=%.2f", silence, speechDur, minSpeechDuration))
                }
            }
        }
    }

    private func endRecording() async {
        guard recorder.isRecording else { return }
        if let spoke = speechStartedAt {
            let span = Date().timeIntervalSince(spoke)
            let voiced = lastVoiceAt.map { $0.timeIntervalSince(spoke) } ?? 0
            Log.line(String(format: "[VAD] segment kapanıyor: açık=%.2fs sesli=%.2fs", span, voiced))
        }
        listeningLoopActive = false
        guard let url = recorder.finishSegment() else {
            cancelLiveSTT()
            return
        }
        guard speechStartedAt != nil else {
            // No speech detected — canlı STT'yi iptal et, dinlemeye dön.
            cancelLiveSTT()
            if isRunning { await beginListening() }
            return
        }
        playCue { cues.playListenEnded() }
        await transcribeAndRespond(audio: url)
    }

    private func transcribeAndRespond(audio: URL) async {
        guard let settings else { return }
        turnStartedAt = Date()
        state = .transcribing

        // BİRİNCİL: sunucu STT — kayıt PCM'i brain'e gider, Whisper sunucuda
        // çözer, transcript + cevap + TTS sesi aynı turda döner. Bağlantı
        // düştüyse burada YENİDEN KURULUR (kopma kalıcı local moda hapsetmesin).
        if await ensureBridgeConnection(settings: settings) {
            let handled = await serverTranscribeAndRespond(audio: audio, settings: settings)
            if handled {
                try? FileManager.default.removeItem(at: audio)
                return
            }
            mark("Sunucu STT olmadı → cihaz (SFSpeech) yedeğine düşülüyor")
        } else {
            mark("Sunucuya ulaşılamadı → cihaz (SFSpeech) yedeği")
        }

        // YEDEK: Apple SFSpeech (cihazda) + eski metin-yukarı akış.
        mark("STT cihaz üzerinde çalışıyor (SFSpeech yedek)")
        let trimmed: String
        do {
            let text = try await OnDeviceSTT.transcribe(
                audioURL: audio,
                language: settings.language
            )
            trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            try? FileManager.default.removeItem(at: audio)
            mark("STT hatası: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await postResponseListen()
            return
        }

        try? FileManager.default.removeItem(at: audio)
        Log.line("[STT] '\(trimmed)' (\(trimmed.count) chars)")
        lastTranscript = trimmed
        mark("STT tamamlandı: \(trimmed.count) karakter")
        if Self.isLikelyNoise(transcript: trimmed) {
            Log.line("[STT] discarded (noise/hallucination)")
            mark("STT çıktısı gürültü sayıldı, bridge'e gönderilmedi")
            await postResponseListen()
            return
        }
        // Metni WS ile bridge'e gönder, dönen pcm_f32le parçalarını gerçek
        // zamanlı çal. Bridge erişilemezse cihaz TTS'e düşülür (speakViaRealtime).
        await speakViaRealtime(text: trimmed, settings: settings)
    }

    /// Whisper hallucination + noise filter:
    /// - boş veya 4 harften az → noise
    /// - tek-kelime üretildiyse: hallucinationWords'te varsa veya ≤3 harf → noise
    /// - tüm transkript hallucinationPhrases'te ise → noise
    private static func isLikelyNoise(transcript: String) -> Bool {
        if transcript.isEmpty { return true }
        let lower = transcript.lowercased().trimmingCharacters(in: .punctuationCharacters)
        // Harf + RAKAM say (yalnız harf değil): "1,2,3,4,5" gibi sayısal konuşmalar
        // da geçerli olmalı — yoksa gürültü sanılıp atılıyordu.
        let alphanumCount = lower.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        if alphanumCount < 4 { return true }
        if hallucinationPhrases.contains(lower) { return true }
        // Whisper'ın sessiz/gürültülü seste uydurduğu altyazı/video artefaktları —
        // metnin İÇİNDE geçiyorsa gürültü say (tam eşleşme "Altyazı M.K." gibi
        // varyasyonları kaçırıyordu).
        for marker in ["altyazı", "m.k.", "dipnot.com", "iyi seyirler"] where lower.contains(marker) {
            return true
        }
        if lower.contains("izlediğiniz için teşekkür") { return true }
        if lower.contains("dinlediğiniz için teşekkür") { return true }
        if lower.contains("abone ol") || lower.contains("abone olun") { return true }
        let words = lower
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        if words.count == 1, let w = words.first {
            if hallucinationWords.contains(w) { return true }
            if w.count <= 3 { return true }
        }
        return false
    }

    /// After a successful (or failed) interaction, give the user a follow-up
    /// window to speak again without re-saying the wake word. If wake word is
    /// disabled (continuous mode), just keep listening as before.
    private func postResponseListen(echoSettle: Double = 0) async {
        guard isRunning else { return }
        if settings?.wakeWordEnabled == true {
            await beginListening(withInactivityTimeout: true, echoSettle: echoSettle)
        } else {
            await beginListening(echoSettle: echoSettle)
        }
    }

    /// Realtime bridge yolu: metni WS ile gönder, gelen pcm_f32le parçalarını
    /// AudioPlayer.streamPCM üzerinden gerçek zamanlı çal. Barge-in / VAD / AEC
    /// davranışı cihaz TTS yoluyla birebir aynı tutulur.
    /// Cihaz TTS override açıksa ya da bridge bağlantı/speak başarısız olursa
    /// synthesizeAndPlayOnDevice ile cihaz-içi TTS'e düşülür (yedek).
    // MARK: - Sunucu STT (ses-yukarı)

    private var transcriptWaiter: CheckedContinuation<String?, Never>?
    private var transcriptTurn = 0

    /// Bridge bağlantısını garanti et: kopmuşsa yeniden kur ve erişilebilirlik
    /// onayını (ilk pong) kısa süre bekle. true = sunucu yolu kullanılabilir.
    private func ensureBridgeConnection(settings: SettingsStore) async -> Bool {
        if bridge.isConnected, serverConnected == true { return true }
        if !bridge.isConnected {
            do {
                try bridge.connect(urlString: settings.bridgeWSURL, token: settings.bridgeApiKey)
                mark("Bridge yeniden bağlanıyor…")
            } catch {
                return false
            }
        }
        // İlk pong ~anında gelir; 2 sn içinde gelmezse bu tur için yedeğe düş
        // (arka plandaki otomatik yeniden bağlanma denemeye devam eder).
        for _ in 0..<20 {
            if serverConnected == true { return true }
            if !bridge.isConnected { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Kayıt dosyasını 16k mono s16 PCM'e çevirip brain'e yollar; sunucu
    /// transcript + cevap + TTS sesini aynı turda döndürür. true = tur ele
    /// alındı (başarı veya boş transkript); false = gönderilemedi, cihaz
    /// STT yedeğine düşülmeli.
    private func serverTranscribeAndRespond(audio: URL, settings: SettingsStore) async -> Bool {
        guard let pcm = Self.pcm16kMono(from: audio), !pcm.isEmpty else {
            mark("PCM dönüşümü başarısız — cihaz STT yedeği")
            return false
        }
        mark("Sunucu STT: \(pcm.count / 32) ms ses yollanıyor")
        player.beginPCMStream()
        let voice = settings.voice.isEmpty ? nil : settings.voice
        let sttEngine = settings.sttEngine.isEmpty ? nil : settings.sttEngine
        do {
            realtimeActiveId = try await bridge.sendUtterance(pcm: pcm, voice: voice,
                                                              sttEngine: sttEngine)
        } catch {
            player.stopPCMStream()
            mark("Sunucuya ses gönderilemedi: \(error.localizedDescription)")
            return false
        }

        guard let transcript = await waitForTranscript(timeout: 30),
              !transcript.isEmpty else {
            player.stopPCMStream()
            realtimeActiveId = nil
            mark("Sunucu transkripti boş / zaman aşımı")
            await postResponseListen()
            return true
        }
        // Whisper'ın sessiz/echo segmentte uydurduğu hayalet ifadeler (YouTube
        // altyazı artefaktları: "abone ol", "izlediğiniz için teşekkür ederim" vb.)
        // sunucu STT yolunda da filtrelensin. Aksi halde TTS/hatırlatma sonrası açılan
        // mikrofon penceresi sessizlik/eko yakalıyor, sunucu Whisper'ı hayalet bir cümle
        // üretiyor, LLM ona cevap verip kullanıcının GERÇEK ilk turunu yiyordu
        // (kullanıcı ikinci kez konuşunca düzeliyordu). Cihaz (SFSpeech) yolundaki
        // isLikelyNoise filtresiyle birebir aynı — sadece burada da uygulanıyor.
        if Self.isLikelyNoise(transcript: transcript) {
            Log.line("[STT] sunucu transkripti gürültü/halüsinasyon sayıldı: '\(transcript)'")
            // Sunucu bu id için cevap+TTS üretmesin (henüz reply gelmediyse engeller).
            if let id = realtimeActiveId {
                try? await bridge.cancel(id: id)
            }
            player.stopPCMStream()
            realtimeActiveId = nil
            mark("Sunucu STT halüsinasyon sayıldı — atlandı, tekrar dinleniyor")
            await postResponseListen(echoSettle: 0.6)
            return true
        }
        lastTranscript = transcript
        appendMessage(.user, transcript)
        mark("Sunucu STT tamamlandı: \(transcript.count) karakter")

        // Cevap + TTS üretilirken "düşünüyor"; ses başlayınca onAudioStart
        // handler'ı .speaking'e geçirir.
        state = .synthesizing
        let bargeInActive = settings.bargeInEnabled
        if bargeInActive {
            resetBargeIn()
            do { try recorder.startMonitoring() }
            catch { Log.line("[BargeIn] mic başlatılamadı: \(error)") }
        }

        // reply + audio_start → parçalar → audio_end bitene kadar bekle.
        let timedOut = await player.waitForPCMStreamDrained()
        if timedOut, let id = realtimeActiveId {
            try? await bridge.cancel(id: id)   // geciken üretimi sunucuda durdur
            player.stopPCMStream()
        }
        realtimeActiveId = nil

        if bargeInActive {
            if bargeInTriggered { return true }
            recorder.discardSegment()
        }
        if let err = realtimeError {
            realtimeError = nil
            mark("Bridge hatası: \(err)")
        }
        try? await Task.sleep(nanoseconds: postPlaybackDelay)
        mark("Tur tamamlandı (sunucu STT)")
        await postResponseListen(echoSettle: 0.6)
        return true
    }

    private func waitForTranscript(timeout: TimeInterval) async -> String? {
        transcriptTurn += 1
        let turn = transcriptTurn
        return await withCheckedContinuation { cont in
            transcriptWaiter = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.transcriptTurn == turn else { return }
                self.resolveTranscript(nil)   // zaman aşımı
            }
        }
    }

    func resolveTranscript(_ text: String?) {
        transcriptWaiter?.resume(returning: text)
        transcriptWaiter = nil
    }

    // MARK: - Cevap bekleme (cihaz TTS modu) + sunucu-yok bildirimi

    private var replyWaiter: CheckedContinuation<String?, Never>?
    private var replyTurn = 0

    private func waitForReply(timeout: TimeInterval) async -> String? {
        replyTurn += 1
        let turn = replyTurn
        return await withCheckedContinuation { cont in
            replyWaiter = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, self.replyTurn == turn else { return }
                self.resolveReply(nil)
            }
        }
    }

    func resolveReply(_ text: String?) {
        replyWaiter?.resume(returning: text)
        replyWaiter = nil
    }

    /// Sunucuya ulaşılamadığında KULLANICININ SÖZÜNÜ TEKRARLAMA (eski echo
    /// kalıntısı) — kısa bir bilgilendirme oku.
    private func speakServerUnreachable(settings: SettingsStore) async {
        await synthesizeAndPlayOnDevice(
            text: "Sunucuya şu an ulaşamıyorum.", settings: settings
        )
    }

    /// Kayıt wav'ını 16 kHz mono s16le ham PCM'e çevirir (sunucu Whisper formatı).
    private static func pcm16kMono(from url: URL) -> Data? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let src = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: frames),
              (try? file.read(into: inBuf)) != nil,
              let dstFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16, sampleRate: 16000,
                  channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: src, to: dstFormat)
        else { return nil }

        let ratio = 16000.0 / src.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outCapacity)
        else { return nil }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard convError == nil, outBuf.frameLength > 0,
              let ch = outBuf.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2)
    }

    private func speakViaRealtime(text: String, settings: SettingsStore) async {
        // Tanınan (gönderilen) metni sohbet feed'ine kullanıcı satırı olarak ekle.
        appendMessage(.user, text)

        // Bağlantı düşmüşse yeniden kur — başarısız olursa bilgilendir.
        if !bridge.isConnected {
            do { try bridge.connect(urlString: settings.bridgeWSURL, token: settings.bridgeApiKey) }
            catch {
                mark("Realtime bridge bağlanamadı: \(error.localizedDescription)")
                await speakServerUnreachable(settings: settings)
                return
            }
        }

        // Cihaz TTS modu: cevabı METİN olarak iste (want_audio=false), telefonda
        // AVSpeech ile oku. Ses dosyası inmez — hızlı ve düşük bant genişliği.
        if settings.useOnDeviceTTS {
            state = .synthesizing
            do {
                _ = try await bridge.speak(text: text, voice: nil, wantAudio: false)
            } catch {
                mark("Bridge'e gönderilemedi: \(error.localizedDescription)")
                await speakServerUnreachable(settings: settings)
                return
            }
            guard let reply = await waitForReply(timeout: 90), !reply.isEmpty else {
                mark("Cevap zaman aşımı (cihaz TTS modu)")
                await postResponseListen()
                return
            }
            await synthesizeAndPlayOnDevice(text: reply, settings: settings)
            return
        }

        state = .synthesizing
        realtimeError = nil
        mark("Realtime bridge'e gönderiliyor: \(text.count) karakter")

        // PCM stream durumunu speak'ten ÖNCE (senkron) sıfırla. Aksi halde önceki turdan
        // kalan streamFinishedFlag=true yüzünden waitForPCMStreamDrained anında döner ve
        // tur, ses hiç çalmadan "tamamlanır" (mic erken açılır, ses kesilir).
        player.beginPCMStream()

        let voice = settings.voice.isEmpty ? nil : settings.voice
        do {
            realtimeActiveId = try await bridge.speak(text: text, voice: voice)
        } catch {
            player.stopPCMStream()
            mark("Realtime speak hatası: \(error.localizedDescription)")
            await speakServerUnreachable(settings: settings)
            return
        }

        state = .speaking
        applyAudioRoute()

        let bargeInActive = settings.bargeInEnabled
        if bargeInActive {
            resetBargeIn()
            do { try recorder.startMonitoring() }
            catch { Log.line("[BargeIn] mic başlatılamadı: \(error)") }
        }

        // audio_start → parçalar → audio_end (veya error/close) bitene kadar bekle.
        let timedOut = await player.waitForPCMStreamDrained()
        if timedOut, let id = realtimeActiveId {
            try? await bridge.cancel(id: id)   // geciken üretimi sunucuda durdur
            player.stopPCMStream()
        }
        realtimeActiveId = nil

        if bargeInActive {
            if bargeInTriggered { return }
            recorder.discardSegment()
        }

        if let err = realtimeError {
            realtimeError = nil
            mark("Realtime bridge hatası: \(err)")
            await speakServerUnreachable(settings: settings)
            return
        }

        try? await Task.sleep(nanoseconds: postPlaybackDelay)
        mark("Tur tamamlandı (realtime bridge)")
        // Asistan satırı bridge.onReply üzerinden ekleniyor (brain `reply` mesajı).
        // TTS sonrası ~0.6 sn yankı yatışması: kendi sesinin kuyruğu boş segment açmasın.
        await postResponseListen(echoSettle: 0.6)
    }

    private func synthesizeAndPlayOnDevice(text: String, settings: SettingsStore) async {
        state = .synthesizing
        mark("Cihaz TTS sentezleniyor (\(text.count) karakter)")
        do {
            let buffer = try await OnDeviceTTS.shared.synthesize(
                text: text,
                language: settings.language,
                voiceId: settings.onDeviceVoiceId
            )
            mark("Cihaz TTS hazır, frames=\(buffer.frameLength)")
            state = .speaking
            applyAudioRoute()

            let bargeInActive = settings.bargeInEnabled
            if bargeInActive {
                resetBargeIn()
                do { try recorder.startMonitoring() }
                catch { Log.line("[BargeIn] mic başlatılamadı: \(error)") }
            }

            do {
                try await player.play(buffer: buffer)
            } catch {
                state = .error("Çalma hatası: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await postResponseListen()
                return
            }

            if bargeInActive {
                if bargeInTriggered { return }
                recorder.discardSegment()
            }

            try? await Task.sleep(nanoseconds: postPlaybackDelay)
            mark("Tur tamamlandı (cihaz TTS)")
            // Feed yalnız kullanıcı satırlarını gösterir (echo'da asistan tekrar olurdu).
            // TODO: LLM eklenince cevap metniyle appendMessage(.assistant, reply).
            await postResponseListen()
        } catch {
            mark("Cihaz TTS hatası: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await postResponseListen()
        }
    }
}
