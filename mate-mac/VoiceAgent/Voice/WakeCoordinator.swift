import AVFoundation
import LiveKit
import SwiftUI

/// Wake-word kapısı + geçiş sesleri — **TEK ses motoru + sunucu kapısı** tasarımı.
///
/// Eski tasarım mikrofonu iki ayrı `AVAudioEngine` arasında devrediyordu (Apple
/// wake dinleyici ↔ LiveKit WebRTC). macOS CoreAudio bu devri temiz yapamıyor →
/// `StartIO error 35`, aggregate device hataları, sessiz mic. Yeni tasarım:
/// **LiveKit mikrofonu sürekli yakalar VE sürekli yayınlar; SFSpeech yalnız PCM'i
/// gözlemler; uyku/uyanık ayrımı SUNUCUDA `mate.awake` ile yapılır.**
///
/// Neden publish/unpublish DEĞİL (deneyle doğrulandı):
///   • PCM (localAudioRenderer) yalnız mic track YAYINDAYKEN akıyor; unpublish edince
///     ilk tampondan sonra duruyor → wake sağır kalıyor.
///   • `startLocalRecording()` + published track BİRLİKTE CoreAudio'yu overload edip
///     (`skipping cycle due to overload`, -10877) ~28sn'de bir full-reconnect'e
///     (CLIENT_REQUEST_LEAVE) yol açıyordu.
///   • Çözüm: TEK yol — track'i sürekli yayında tut (startLocalRecording YOK).
///     Agent, `mate.awake=="0"` iken sesi/transkripti yok sayar (sunucu kapısı).
///
/// Durum makinesi (wakeWordEnabled açıkken):
///   • Bağlanınca → PCM renderer ekle + mic track'i YAYINLA (sürekli). Uyku moduna gir.
///   • UYKU → `mate.awake="0"`; mic yayında ama agent yok sayar; wake tanıma aktif.
///   • Wake duyulunca → tanımayı durdur, `mate.awake="1"` (publish/settle YOK).
///   • UYANIK → agent sesi işler.
///   • Re-arm (hareketsizlik) → `mate.awake="0"`, taze tanıma isteği başlat.
///   • Disconnect → renderer'ı kaldır (mic disconnect ile zaten düşer).
///
/// wakeWordEnabled kapalıyken kapı devre dışı: sürekli mod — `mate.awake="1"`.
///
/// NOT (gizlilik): Mic uyku sırasında da yayında olduğundan ses sunucuya gider ama
/// agent `awake="0"` iken yok sayar; macOS mikrofon göstergesi (turuncu nokta) açık
/// kalır — uygulama gerçekten wake kelimesini dinliyor.
@MainActor
final class WakeCoordinator: ObservableObject {
    enum Mode { case inactive, sleeping, awake }

    @Published private(set) var mode: Mode = .inactive
    @Published var unavailableMessage: String?

    /// Ajan boştayken yeniden uykuya geçmeden önce beklenen takip süresi.
    private let inactivityWindowSeconds: UInt64 = 10

    private let wake = WakeWordDetector()
    private let cues = CueSounds()
    /// Optimistic lokal transkript (yalnız awake/continuous modda aktif).
    private weak var echo: LocalEchoTranscriber?
    /// PCM renderer — bağlantı ömrü boyunca güçlü tutulur, disconnect'te kaldırılır.
    private var wakeRenderer: WakePCMRenderer?

    private var session: Session?
    private var settings: SettingsStore?

    private var connected = false
    private var inactivityTask: Task<Void, Never>?
    private var cueHandlerRegistered = false
    /// Mikrofon agent'e canlı mı (track yayında)? `mate.awake` attribute'unun kaynağı.
    private var isAwake = false
    /// Track'in YAYINDA olması istenen niyet. `setMicrophone` ile güncellenir; reaktif
    /// guard (`microphoneStateChanged`) istenmeden yayınlanan track'i buna göre kapatır.
    private var micShouldBeLive = false
    /// "Hazır" (knock-knock) cue'su bu bağlantıda çalındı mı. Disconnect'te sıfırlanır.
    private var playedReady = false

    func attach(session: Session, settings: SettingsStore, echo: LocalEchoTranscriber) {
        guard self.session == nil else { return }
        self.session = session
        self.settings = settings
        self.echo = echo
        wake.onWakeDetected = { [weak self] in self?.handleWakeDetected() }
        wake.onUnavailable = { [weak self] msg in
            self?.unavailableMessage = msg
            // Wake istendi ama kullanılamıyor: track yayında kalır ama
            // mate.awake = "0" → agent sızıntıyı yok sayar.
            self?.disableGate(continuous: false)
        }
    }

    /// Agent proaktif teslimden önce `mate.cue` topic'ine "reminder" yollar →
    /// belirgin hatırlatma çanı çal (cuesEnabled açıksa).
    private func registerCueHandler() {
        guard !cueHandlerRegistered, let session else { return }
        cueHandlerRegistered = true
        Task {
            try? await session.room.registerTextStreamHandler(for: "mate.cue") { [weak self] reader, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let value = (try? await reader.readAll()) ?? ""
                    if value.localizedCaseInsensitiveContains("reminder"),
                       self.settings?.cuesEnabled == true {
                        self.cues.playReminder()
                    }
                }
            }
        }
    }

    private func unregisterCueHandler() {
        guard cueHandlerRegistered, let session else { return }
        cueHandlerRegistered = false
        Task { await session.room.unregisterTextStreamHandler(for: "mate.cue") }
    }

    // MARK: - Wake yakalama (tek yol: sürekli yayınlanan mic track + PCM renderer)

    /// PCM renderer'ı bağla + mic track'i SÜREKLI yayınla. Track yayındayken LiveKit
    /// ses motoru capture eder → localAudioRenderer wake tanıyıcıya PCM verir.
    /// `startLocalRecording` YOK: published track + startLocalRecording BİRLİKTE
    /// CoreAudio'yu overload edip full-reconnect'e yol açıyordu (deneyle doğrulandı);
    /// ayrıca PCM zaten yalnız track YAYINDAYKEN akıyor. Idempotent.
    private func startWakeCapture() {
        if wakeRenderer == nil {
            // TEK renderer iki tüketiciye besler; aktif olmayanın request'i nil →
            // no-op. wake=sleeping, echo=awake/continuous (asla aynı anda).
            let renderer = WakePCMRenderer { [wake, weak echo] buffer in
                wake.appendPCM(buffer)
                echo?.appendPCM(buffer)
            }
            wakeRenderer = renderer
            AudioManager.shared.add(localAudioRenderer: renderer)
        }
        setMicrophone(enabled: true) // sürekli yayın → engine capture → renderer PCM
    }

    private func stopWakeCapture() {
        if let renderer = wakeRenderer {
            AudioManager.shared.remove(localAudioRenderer: renderer)
            wakeRenderer = nil
        }
        Log.line("[Audio] wake capture durdu + renderer kaldırıldı")
    }

    // MARK: - Dış olaylar (AppView'dan sürülür)

    func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        if isConnected {
            registerCueHandler()
            // TEK yol: bağlanır bağlanmaz renderer'ı bağla + mic'i sürekli yayınla.
            // Uyku/uyanık ayrımı setAwake (mate.awake) ile sunucuda yapılır.
            startWakeCapture()
            evaluate()
        } else {
            teardown()
        }
    }

    func wakeWordEnabledChanged() {
        guard connected else { return }
        evaluate()
    }

    /// ControlBar "mic" butonu için manuel uyku/uyanık geçişi.
    /// LiveKit-mute YAPILMAZ — mic her zaman yayında/capture'da kalır ki wake PCM
    /// aksın. Gürültülü ortamda otomatik re-arm (inaktivite) tetiklenmediğinde
    /// kullanıcı buradan elle uykuya alır (agent awake=0 ile duymaz); "candan" ile
    /// (veya tekrar basarak) uyandırır.
    func toggleSleep() {
        guard connected, settings?.wakeWordEnabled == true else { return }
        if mode == .sleeping {
            enterAwake()        // manuel uyandırma ("candan" demeden)
        } else {
            enterSleeping()     // manuel uyku: mic yayında kalır, wake dinler
        }
    }

    func agentStateChanged(_ state: AgentState?) {
        guard mode == .awake else { return }
        switch state {
        case .listening, .thinking, .speaking:
            cancelInactivityTimer()
        case .idle:
            armInactivityTimer()
        default:
            break
        }
    }

    // MARK: - Geçişler

    private func evaluate() {
        guard let settings else { return }
        if settings.wakeWordEnabled {
            if mode != .sleeping { enterSleeping(playCue: false) }
        } else {
            unavailableMessage = nil
            disableGate(continuous: true)
        }
    }

    /// Wake kapısını devre dışı bırak: tanımayı durdur, track'i yayınla.
    /// - Parameter continuous: Kullanıcı wake'i bilerek kapattıysa `true` →
    ///   agent dinlesin (`mate.awake = "1"`). Wake kullanılamıyorsa `false` → `"0"`.
    private func disableGate(continuous: Bool) {
        cancelInactivityTimer()
        wake.stop()
        mode = .inactive
        setMicrophone(enabled: true)
        setAwake(continuous)
        // Agent dinliyorsa (continuous) optimistic lokal transkript aktif; aksi halde kapalı.
        if continuous { echo?.start(language: settings?.language ?? "tr") } else { echo?.stop() }
        if continuous { playReadyOnce() }
    }

    private func enterSleeping(playCue: Bool = true) {
        // Idempotent: zaten uykudaysak tekrar girme (re-arm'da çift tetik önlenir).
        guard mode != .sleeping else {
            Log.line("[Coord] enterSleeping atlandı (zaten uykuda)")
            return
        }
        Log.line("[Coord] → UYKU (mic yayında kalır; sunucu awake=0 ile yok sayar)")
        cancelInactivityTimer()
        mode = .sleeping
        // Temiz yeniden başlatma: stale tanıma isteğini temizle.
        wake.stop()
        // Mic UNPUBLISH EDİLMEZ — sürekli yayında (tek yol; PCM akmaya devam eder →
        // wake dinler). Uyku yalnızca SUNUCU kapısı: mate.awake=0 → agent uyku
        // sesini/transkriptini yok sayar.
        setAwake(false)
        // Uykuda agent yok sayıyor → optimistic gösterme; SFSpeech'i wake'e bırak.
        echo?.stop()
        if playCue, settings?.cuesEnabled == true { cues.playSleeping() }
        startWakeListening()
    }

    private func enterAwake() {
        Log.line("[Coord] → UYANIK (sunucu kapısını aç: awake=1; mic zaten yayında)")
        mode = .awake
        // Tanımayı durdur (artık wake aramaya gerek yok). Renderer bağlı kalır;
        // aktif istek olmadığı için appendPCM sessiz no-op olur.
        wake.stop()
        // Agent artık işliyor → optimistic lokal transkripti başlat.
        echo?.start(language: settings?.language ?? "tr")
        if settings?.cuesEnabled == true { cues.playWakeDetected() }
        // Mic ZATEN sürekli yayında → publish YOK demek = setMicrophone/setAwake
        // sırasızlık yarışı YOK. Settle de YOK (ilk komut sözcükleri kesilmesin):
        // agent, awake=0 iken başlayan "candan" sözünü zaten yok sayar; awake=1
        // sonrası konuşma işlenir.
        setAwake(true)
        armInactivityTimer()
    }

    private func handleWakeDetected() {
        guard mode == .sleeping else {
            Log.line("[Coord] wake algılandı ama mode=\(mode) → atla")
            return
        }
        enterAwake()
    }

    private func teardown() {
        cancelInactivityTimer()
        unregisterCueHandler()
        wake.stop()
        echo?.stop()
        stopWakeCapture()
        mode = .inactive
        playedReady = false
    }

    private func playReadyOnce() {
        guard !playedReady else { return }
        playedReady = true
        if settings?.cuesEnabled == true { cues.playReady() }
    }

    // MARK: - Hareketsizlik zamanlayıcısı

    private func armInactivityTimer() {
        inactivityTask?.cancel()
        let seconds = inactivityWindowSeconds
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard let self, !Task.isCancelled, self.mode == .awake else { return }
            Log.line("[Coord] inaktivite doldu → re-arm (uykuya)")
            self.enterSleeping()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    // MARK: - Wake dinleme başlatma (artık cihaz settle/retry YOK)

    private func startWakeListening() {
        guard settings != nil else { return }
        Log.line("[Coord] startWakeListening (mode=\(mode))")
        Task { [weak self] in
            guard let self else { return }
            // Hem konuşma tanıma HEM mikrofon izni gerekli (sandbox kapalı macOS'ta
            // mic TCC izni de şart; eskiden yalnız speech kontrol ediliyordu).
            let speechOK = await self.wake.requestPermission()
            guard speechOK else {
                Log.error("[Wake] konuşma tanıma izni YOK → disableGate")
                self.unavailableMessage = "Konuşma tanıma izni verilmedi."
                self.disableGate(continuous: false)
                return
            }
            let micOK = await Self.requestMicrophonePermission()
            guard micOK else {
                Log.error("[Wake] mikrofon izni YOK → disableGate")
                self.unavailableMessage = "Mikrofon izni verilmedi."
                self.disableGate(continuous: false)
                return
            }
            guard self.mode == .sleeping, let settings = self.settings else { return }
            do {
                try self.wake.start(wakeWord: settings.wakeWord, language: settings.language)
                self.unavailableMessage = nil
                // Bağlandı + wake'e hazır = "her şey hazır" → bir kez knock-knock.
                self.playReadyOnce()
            } catch {
                Log.error("[Wake] tanıma başlatılamadı: \(error.localizedDescription)")
                self.unavailableMessage = error.localizedDescription
                self.disableGate(continuous: false)
            }
        }
    }

    /// Mikrofon (TCC) izni iste — macOS + iOS ortak yol.
    private nonisolated static func requestMicrophonePermission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { return true }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    // MARK: - Track publish/unpublish

    /// Mic track'ini YAYINLA (publish) ya da yayından TAMAMEN KALDIR (unpublish).
    /// Normal akışta yalnız `startWakeCapture` tarafından enabled=true ile çağrılır
    /// (mic sürekli yayında kalır; uyku/uyanık ayrımı sunucuda mate.awake ile).
    /// enabled=false yalnız reaktif guard (`microphoneStateChanged`) içindir:
    /// istenmeden yayına giren stray track'i kaldırır.
    private func setMicrophone(enabled: Bool) {
        micShouldBeLive = enabled
        guard let session else { return }
        let lp = session.room.localParticipant
        Task {
            if enabled {
                await publishMicWithRetry(lp)
            } else {
                // Mute değil unpublish: agent'e giden yayın/encode yolunu kapat.
                for pub in lp.localAudioTracks {
                    try? await lp.unpublish(publication: pub)
                }
                Log.line("[Mic] unpublished — stray track kaldırıldı")
            }
        }
    }

    /// Mic track'ini yayınla — izin yarışı + geçici "Cancelled" transient'ine dayanıklı.
    ///
    /// İKİ transient çözülür:
    ///  1. İZİN YARIŞI: connectionChanged(true) → publish, sunucunun JoinResponse'u
    ///     permissions'ı doldurmadan ateşlenebiliyor → permissions.canPublish=false
    ///     (SDK default) → "does not have permission to publish". waitForPublishPermission
    ///     izin gelene kadar bekler.
    ///  2. "Cancelled" (LiveKitError Code=100): USB headset gibi cihazlarda CoreAudio
    ///     HAL ilk açılırken (AQMEIO/-10877) bağlantı tam oturmadan publish atılıyor →
    ///     SDK publish task'ını iptal ediyor. Bağlantı oturunca retry başarılı.
    ///
    /// Bağlı + niyet "live" kaldığı sürece kısa backoff'la birkaç kez dener; bağlantı
    /// gerçekten düşerse (connected=false) vazgeçer — reconnect yolu yeniden tetikler.
    private func publishMicWithRetry(_ lp: LocalParticipant) async {
        let maxAttempts = 5
        for attempt in 1 ... maxAttempts {
            do {
                try await waitForPublishPermission(lp)
                guard connected, micShouldBeLive else { return } // uyku/kapanma/disconnect → vazgeç
                try await lp.setMicrophone(enabled: true)
                Log.line("[Mic] published — agent duyar")
                return
            } catch {
                guard connected, micShouldBeLive else { return }
                if attempt == maxAttempts {
                    Log.error("[Mic] publish \(maxAttempts) denemede başarısız: \(error.localizedDescription)")
                    return
                }
                Log.line("[Mic] publish geçici hata (\(error.localizedDescription)) — yeniden deniyorum (\(attempt)/\(maxAttempts))")
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms backoff
            }
        }
    }

    /// Sunucu JoinResponse'u local participant izinlerini doldurana kadar
    /// (`permissions.canPublish == true`) bekle. Bağlantı düşerse ya da publish
    /// niyeti kalkarsa erken çıkar. ~5sn üst sınır (50 × 100ms) — izin normalde
    /// bağlantıdan hemen sonra gelir; gelmiyorsa publish denenip gerçek hatayı loglar.
    private func waitForPublishPermission(_ lp: LocalParticipant) async throws {
        guard !lp.permissions.canPublish else { return }
        for _ in 0 ..< 50 {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard connected, micShouldBeLive else { return }
            if lp.permissions.canPublish { return }
        }
        Log.line("[Mic] canPublish izni ~5sn'de gelmedi — yine de publish deneniyor")
    }

    /// Track beklenmedik şekilde yayına girerse (örn. `session.start()` bağlanınca
    /// mic'i otomatik publish eder) ve biz uyku/kapı-kapalı moddaysak geri al.
    /// SADECE istenmeden yayınlananı kapatır; canlı modu/manuel mute'u EZMEZ.
    func microphoneStateChanged(_ enabled: Bool) {
        guard connected else { return }
        if enabled, !micShouldBeLive {
            setMicrophone(enabled: false)
        }
    }

    private func setAwake(_ value: Bool) {
        isAwake = value
        publishAttributes()
    }

    /// Tüm participant attribute'larını (agent ayarları + `mate.awake`) TEK sözlük
    /// olarak yayınlar. Agent `mate.awake == "0"` iken başlayan sözleri yok sayar.
    func publishAttributes() {
        guard let session, session.isConnected else {
            Log.line("[Attr] publishAttributes atlandı — bağlı değil")
            return
        }
        var attrs = settings?.agentAttributes ?? [:]
        attrs["mate.awake"] = isAwake ? "1" : "0"
        Log.line("[Attr] → mate.awake=\(isAwake ? "1" : "0") attrs=\(attrs)")
        // RETRY: session.isConnected, gerçek oda bağlanmadan ÖNCE true olabiliyor →
        // ilk set() "connectionState is .disconnected" ile patlıyor ve isConnected
        // bir daha değişmediği için snapshot-republish tetiklenmiyordu → sunucu
        // mate.awake'i HİÇ almıyor → wake-gate devre dışı (her sözü işliyor). Oda
        // oturana kadar birkaç kez dene; biri başarınca dur.
        Task {
            for attempt in 1 ... 6 {
                do {
                    try await session.room.localParticipant.set(attributes: attrs)
                    Log.line("[Attr] set OK (deneme \(attempt))")
                    return
                } catch {
                    Log.error("[Attr] set FAILED (deneme \(attempt)/6): \(error.localizedDescription)")
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            Log.error("[Attr] set 6 denemede başarısız — sunucu mate.awake'i almadı (wake-gate çalışmaz)")
        }
    }
}
