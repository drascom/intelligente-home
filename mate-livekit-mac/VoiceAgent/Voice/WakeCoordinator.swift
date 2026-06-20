import LiveKit
import SwiftUI

/// Wake-word kapısı + geçiş sesleri.
///
/// Wake dinleyici ile LiveKit mikrofonu KARŞILIKLI DIŞLAMALIDIR (ikisi de
/// mikrofonu ister; aynı anda açık olursa çakışır). Bu yüzden:
///
/// Akış (wakeWordEnabled açıkken):
///   • Oturum bağlanınca → LiveKit mikrofonu KAPAT, wake dinleyiciyi başlat
///     ("uyku" modu).
///   • Wake kelimesi duyulunca → wake dinleyiciyi durdur (mikrofonu serbest
///     bırak), cue çal, LiveKit mikrofonunu AÇ ("uyanık" modu). Ses brain'e
///     akar.
///   • Yeniden silahlanma (re-arm): Burada yerel VAD yok — uç-nokta tespitini
///     (endpointing) brain yapıyor. Bu yüzden basit bir HAREKETSİZLİK
///     ZAMANLAYICISI kullanıyoruz: ajan boştayken (`.idle`) ~10 sn yeni
///     etkinlik gelmezse mikrofonu kapatıp tekrar wake dinlemeye geçeriz.
///     Ajan aktifken (listening/thinking/speaking) sayaç iptal edilir, böylece
///     uzun yanıtlar/art arda turlar kesilmez ve kullanıcı yeniden wake demeden
///     takip sorusu sorabilir. Sayaç ayrıca "uyandı ama hiç konuşulmadı"
///     durumunu da kapatır (yanlış wake'te sonsuza dek açık kalmaz).
///
/// wakeWordEnabled kapalıyken kapı devre dışıdır: sürekli mod — mikrofon açık
/// kalır, wake dinleyici çalışmaz (ControlBar'dan normal yönetim).
@MainActor
final class WakeCoordinator: ObservableObject {
    enum Mode { case inactive, sleeping, awake }

    @Published private(set) var mode: Mode = .inactive
    @Published var unavailableMessage: String?

    /// Ajan boştayken yeniden uykuya geçmeden önce beklenen takip süresi.
    private let inactivityWindowSeconds: UInt64 = 10
    /// Wake duyulduktan sonra mikrofonu açmadan önce beklenen "yerleşme" süresi.
    /// Konuşulan "candan" (+ chime) sesinin mikrofona sızıp brain'e bir söz
    /// olarak gitmesini önler (mate-mac readyCueSettle'ın karşılığı).
    private let readyCueSettleSeconds: Double = 0.5

    private let wake = WakeWordDetector()
    private let cues = CueSounds()

    private var session: Session?
    private var settings: SettingsStore?

    private var connected = false
    private var inactivityTask: Task<Void, Never>?
    private var cueHandlerRegistered = false
    /// Mikrofon brain'e canlı mı? `candan.awake` attribute'unun kaynağı.
    private var isAwake = false
    /// Wake durumunun mikrofonu CANLI tutmak istediği niyet (awake veya wake-kapalı
    /// sürekli mod = true; uyku/kapı-kapalı = false). `setMicrophone` ile güncellenir;
    /// reaktif guard (`microphoneStateChanged`) istenmeden açılan mic'i buna göre kapatır.
    private var micShouldBeLive = false
    /// "Hazır" (knock-knock) cue'su bu bağlantıda çalındı mı (bir kez, başlangıçta;
    /// re-arm/uykuda değil). Disconnect'te sıfırlanır.
    private var playedReady = false

    func attach(session: Session, settings: SettingsStore) {
        guard self.session == nil else { return }
        self.session = session
        self.settings = settings
        wake.onWakeDetected = { [weak self] in self?.handleWakeDetected() }
        wake.onUnavailable = { [weak self] msg in
            self?.unavailableMessage = msg
            // Wake istendi ama kullanılamıyor (disabled-but-gated): mikrofon açık
            // kalır ama candan.awake = "0" → brain sızıntıyı yok sayar.
            self?.disableGate(continuous: false)
        }
    }

    /// Brain proaktif teslimden önce `candan.cue` topic'ine "reminder" yollar →
    /// belirgin hatırlatma çanı çal (cuesEnabled açıksa). Bağlanınca kaydedilir,
    /// teardown'da kaldırılır. lk.transcription özel receiver'ıyla çakışmaz.
    private func registerCueHandler() {
        guard !cueHandlerRegistered, let session else { return }
        cueHandlerRegistered = true
        Task {
            try? await session.room.registerTextStreamHandler(for: "candan.cue") { [weak self] reader, _ in
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
        Task { await session.room.unregisterTextStreamHandler(for: "candan.cue") }
    }

    // MARK: - Dış olaylar (AppView'dan sürülür)

    func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        if isConnected {
            registerCueHandler()
            evaluate()
        } else {
            teardown()
        }
    }

    func wakeWordEnabledChanged() {
        guard connected else { return }
        evaluate()
    }

    func agentStateChanged(_ state: AgentState?) {
        guard mode == .awake else { return }
        switch state {
        case .listening, .thinking, .speaking:
            // Aktif konuşma turu → yeniden uyku sayacını iptal et.
            cancelInactivityTimer()
        case .idle:
            // Tur bitti (ya da henüz başlamadı) → takip için zaman tanı.
            armInactivityTimer()
        default:
            break // initializing / nil
        }
    }

    // MARK: - Geçişler

    private func evaluate() {
        guard let settings else { return }
        if settings.wakeWordEnabled {
            // Kapı aktif: uyku modunda başla (mikrofon kapalı, wake dinler).
            if mode != .sleeping { enterSleeping(playCue: false) }
        } else {
            // Kullanıcı wake'i bilerek kapattı → varsa eski "kullanılamıyor"
            // uyarısını temizle (artık mikrofonun açık olması beklenen durum).
            unavailableMessage = nil
            disableGate(continuous: true)
        }
    }

    /// Wake kapısını devre dışı bırak: dinleyiciyi durdur, mikrofonu aç.
    /// - Parameter continuous: Kullanıcı wake'i bilerek kapattıysa (sürekli mod)
    ///   `true` → brain dinlesin (`candan.awake = "1"`). Wake istenip de
    ///   kullanılamadığında (disabled-but-gated) `false` → `"0"` (brain sızıntıyı
    ///   yok sayar; kullanıcıya banner Dikte'yi açmasını söyler).
    private func disableGate(continuous: Bool) {
        cancelInactivityTimer()
        wake.stop()
        mode = .inactive
        // Sürekli/canlı mod → LiveKit ses motoru girişi açık olmalı (uykuda kapatmış
        // olabiliriz); mikrofonu publish etmeden önce girişi geri aç.
        setLiveKitMicInput(enabled: true)
        setMicrophone(enabled: true)
        setAwake(continuous)
        // Sürekli mod (kullanıcı wake'i kapattı) → bağlandı + dinliyor = "hazır".
        if continuous { playReadyOnce() }
    }

    private func enterSleeping(playCue: Bool = true) {
        cancelInactivityTimer()
        mode = .sleeping
        setMicrophone(enabled: false)
        // KRİTİK (mate-mac deseni): mic track'ini unpublish etmek YETMEZ — LiveKit'in
        // ses motoru donanım mic'ini hâlâ tutar (menü çubuğunda turuncu) ve yerel Apple
        // wake dinleyici (kendi AVAudioEngine'i) mic'i alamaz. Bu yüzden ses motorunun
        // GİRİŞİNİ kapatıyoruz → LiveKit mic'i bırakır, Apple wake alır. ÇIKIŞ açık kalır
        // → brain'in proaktif hatırlatma sesi uyku sırasında bile duyulur.
        setLiveKitMicInput(enabled: false)
        // Uyku: brain bu andan itibaren başlayan sözleri yok saysın.
        setAwake(false)
        if playCue, settings?.cuesEnabled == true { cues.playSleeping() }
        startWakeListening()
    }

    private func enterAwake() {
        mode = .awake
        wake.stop()
        // Apple wake motoru mic'i bıraktı → LiveKit ses motorunun girişini geri aç
        // (settle sonrası mikrofon publish edilecek).
        setLiveKitMicInput(enabled: true)
        if settings?.cuesEnabled == true { cues.playWakeDetected() }
        // Chime'ı çal, KISA SÜRE BEKLE, sonra mikrofonu aç. Böylece konuşulan
        // "candan" (+ chime kuyruğu) mikrofona sızıp brain'e bir söz olarak
        // gitmez. Bekleme sırasında durum değiştiyse (uyku/kapanma) açma.
        let settle = readyCueSettleSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard let self, self.mode == .awake else { return }
            // Mikrofon AÇILDIĞI an awake='1' yayınla: settle'dan önce gönderirsek
            // konuşulan "candan" hâlâ açık pencerede sayılabilirdi.
            self.setMicrophone(enabled: true)
            self.setAwake(true)
        }
        // "Uyandı ama hiç konuşulmadı" durumunu kapat: ajan etkinliği gelmezse
        // sayaç dolunca tekrar uykuya döner.
        armInactivityTimer()
    }

    private func handleWakeDetected() {
        guard mode == .sleeping else { return }
        enterAwake()
    }

    private func teardown() {
        cancelInactivityTimer()
        unregisterCueHandler()
        wake.stop()
        mode = .inactive
        playedReady = false   // sonraki bağlantıda tekrar "hazır" çalsın
    }

    /// "Hazır" (knock-knock) cue'sunu bu bağlantıda yalnız bir kez çal.
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
            self.enterSleeping()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    // MARK: - Yardımcılar

    private func startWakeListening() {
        guard settings != nil else { return }
        Task {
            let ok = await wake.requestPermission()
            guard ok else {
                self.unavailableMessage = "Konuşma tanıma izni verilmedi."
                self.disableGate(continuous: false)
                return
            }
            // LiveKit ses motoru girişi henüz kapandıysa CoreAudio cihazı ASENKRON
            // bırakıyor; taze AVAudioEngine.start() çok erken denenirse '!dev'
            // (kAudioHardwareBadDeviceError) ile patlar (mate-mac'teki aynı yarış).
            // Kısa settle ver, sonra başlat; patlarsa backoff'lu retry.
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.startWakeWithRetry(attempt: 0)
        }
    }

    /// `wake.start()`'ı backoff'lu retry ile dener: LiveKit mic girişi yeni kapandığı
    /// için ilk denemeler '!dev' ile patlayabilir (CoreAudio HAL geç serbest kalıyor).
    private func startWakeWithRetry(attempt: Int) {
        guard mode == .sleeping, let settings else { return }
        do {
            try wake.start(wakeWord: settings.wakeWord, language: settings.language)
            self.unavailableMessage = nil
            // Bağlandı + wake'e hazır = "her şey hazır" → bir kez knock-knock.
            self.playReadyOnce()
        } catch {
            let maxAttempts = 6
            if attempt + 1 < maxAttempts {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, self.mode == .sleeping else { return }
                    self.startWakeWithRetry(attempt: attempt + 1)
                }
            } else {
                self.unavailableMessage = error.localizedDescription
                self.disableGate(continuous: false)
            }
        }
    }

    /// LiveKit ses motorunun mikrofon GİRİŞİNİ aç/kapat — ÇIKIŞ (oynatma) HEP açık.
    /// Uyku sırasında giriş kapatılır → LiveKit donanım mic'ini bırakır, yerel Apple
    /// wake dinleyici alır (iki ses motoru mic'i çekiştirmez; turuncu mic söner). Çıkış
    /// açık kaldığı için brain'in proaktif hatırlatma sesi uyku sırasında bile duyulur
    /// (mate-mac'teki "ayrı sinyal kanalı + ses motoru pause" deseninin LiveKit karşılığı).
    /// Best-effort: hata olursa wake yine de denenecek (settle+retry yutar).
    private func setLiveKitMicInput(enabled: Bool) {
        do {
            try AudioManager.shared.setEngineAvailability(
                AudioEngineAvailability(isInputAvailable: enabled, isOutputAvailable: true)
            )
        } catch {
            // best-effort — kritik değil; wake start retry'ı toparlar.
        }
    }

    /// LiveKit mic'ini canlıya al (publish) ya da TAMAMEN bırak (unpublish).
    ///
    /// Model B: uykudayken odadan ÇIKMIYORUZ (brain proaktif hatırlatmayı hâlâ
    /// itebilsin) ama mic track'ini sadece "mute" etmek yetmez — `setMicrophone(false)`
    /// SDK'da track'i mute eder, donanım capture'ı sürer ve yerel Apple wake
    /// dinleyici (kendi AVAudioEngine'i) mikrofonu ALAMAZ. Bu yüzden uykuda track'i
    /// UNPUBLISH ediyoruz → LiveKit capture'ı bırakır, Apple wake mic'i alır. Oynatma
    /// (brain sesi/chime) açık kalır. Wake'te `setMicrophone(true)` yeni track yayınlar.
    private func setMicrophone(enabled: Bool) {
        micShouldBeLive = enabled
        guard let session else { return }
        let lp = session.room.localParticipant
        Task {
            if enabled {
                try? await lp.setMicrophone(enabled: true)
            } else {
                // Mute değil unpublish: donanım mikrofonunu serbest bırak.
                for pub in lp.localAudioTracks {
                    try? await lp.unpublish(publication: pub)
                }
            }
        }
    }

    /// LiveKit mic durumu beklenmedik şekilde "canlı" olursa (örn. `session.start()`
    /// bağlanınca mic'i otomatik publish eder) ve biz uyku/kapı-kapalı moddaysak
    /// (`micShouldBeLive == false`) geri bırak. SADECE istenmeden açılanı kapatır;
    /// canlı modu ya da kullanıcının manuel mute'unu (ControlBar) EZMEZ.
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

    /// Tüm participant attribute'larını (brain ayarları + `candan.awake`) TEK
    /// sözlük olarak yayınlar. `set(attributes:)` verilen sözlüğü AYNEN yazdığı
    /// için her zaman TAM seti gönderiyoruz → stt_engine/voice/language ezilmez.
    /// Brain `candan.awake == "0"` iken başlayan sözleri yok sayar.
    func publishAttributes() {
        guard let session, session.isConnected else { return }
        var attrs = settings?.brainAttributes ?? [:]
        attrs["candan.awake"] = isAwake ? "1" : "0"
        Task {
            try? await session.room.localParticipant.set(attributes: attrs)
        }
    }
}
