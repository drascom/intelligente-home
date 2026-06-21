import AVFoundation
import LiveKit
import SwiftUI

/// Wake-word kapısı + geçiş sesleri — **TEK ses motoru** tasarımı.
///
/// Eski tasarım mikrofonu iki ayrı `AVAudioEngine` arasında devrediyordu (Apple
/// wake dinleyici ↔ LiveKit WebRTC). macOS CoreAudio bu devri temiz yapamıyor →
/// `StartIO error 35`, aggregate device hataları, sessiz mic. Yeni tasarım:
/// **LiveKit mikrofonu sürekli yakalar; SFSpeech yalnız PCM'i gözlemler.**
///
/// Durum makinesi (wakeWordEnabled açıkken):
///   • Bağlanınca → `startLocalRecording()` + PCM renderer ekle (mic yakalanır ama
///     YAYINLANMAZ → brain duymaz). Uyku moduna gir.
///   • UYKU → tanıma isteği aktif, track yayınlanmamış. Konuşulan ses brain'e
///     gitmez; yalnız yerel wake tanıma görür.
///   • Wake duyulunca → tanıma isteğini durdur, MEVCUT yakalamayı YAYINLA
///     (`setMicrophone(true)`). Motor yeniden başlamaz, cihaz devri yok, yarış yok.
///   • UYANIK → track yayında; ses brain'e akar.
///   • Re-arm (hareketsizlik) → track'i unpublish et, taze tanıma isteği başlat.
///     Yerel kayıt (capture) DOKUNULMAZ → wake dinleme sürer.
///   • Disconnect → `stopLocalRecording()` + renderer'ı kaldır.
///
/// wakeWordEnabled kapalıyken kapı devre dışı: sürekli mod — track yayında kalır.
///
/// NOT (gizlilik): Yerel kayıt uyku sırasında da sürdüğü için macOS mikrofon
/// gizlilik göstergesi (turuncu nokta) açık kalır. Bu DOĞRU — uygulama gerçekten
/// wake kelimesini dinliyor. UI'da "… bekleniyor" ipucu bunu açıkça belirtir.
@MainActor
final class WakeCoordinator: ObservableObject {
    enum Mode { case inactive, sleeping, awake }

    @Published private(set) var mode: Mode = .inactive
    @Published var unavailableMessage: String?

    /// Ajan boştayken yeniden uykuya geçmeden önce beklenen takip süresi.
    private let inactivityWindowSeconds: UInt64 = 10
    /// Wake duyulduktan sonra mikrofonu YAYINLAMADAN önce beklenen kısa süre.
    /// Bu artık SADECE konuşulan "candan"ın kuyruğunun brain'e gitmesini önlemek
    /// içindir — CİHAZ DEVRİ İÇİN DEĞİL (mic zaten canlı yakalıyor, motor devri yok).
    private let readyCueSettleSeconds: Double = 0.5

    private let wake = WakeWordDetector()
    private let cues = CueSounds()
    /// PCM renderer — bağlantı ömrü boyunca güçlü tutulur, disconnect'te kaldırılır.
    private var wakeRenderer: WakePCMRenderer?

    private var session: Session?
    private var settings: SettingsStore?

    private var connected = false
    private var inactivityTask: Task<Void, Never>?
    private var cueHandlerRegistered = false
    /// LiveKit yerel kaydı (startLocalRecording) aktif mi? Renderer'a PCM akar.
    private var localRecordingActive = false
    /// Mikrofon brain'e canlı mı (track yayında)? `candan.awake` attribute'unun kaynağı.
    private var isAwake = false
    /// Track'in YAYINDA olması istenen niyet. `setMicrophone` ile güncellenir; reaktif
    /// guard (`microphoneStateChanged`) istenmeden yayınlanan track'i buna göre kapatır.
    private var micShouldBeLive = false
    /// "Hazır" (knock-knock) cue'su bu bağlantıda çalındı mı. Disconnect'te sıfırlanır.
    private var playedReady = false

    func attach(session: Session, settings: SettingsStore) {
        guard self.session == nil else { return }
        self.session = session
        self.settings = settings
        wake.onWakeDetected = { [weak self] in self?.handleWakeDetected() }
        wake.onUnavailable = { [weak self] msg in
            self?.unavailableMessage = msg
            // Wake istendi ama kullanılamıyor: track yayında kalır ama
            // candan.awake = "0" → brain sızıntıyı yok sayar.
            self?.disableGate(continuous: false)
        }
    }

    /// Brain proaktif teslimden önce `candan.cue` topic'ine "reminder" yollar →
    /// belirgin hatırlatma çanı çal (cuesEnabled açıksa).
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

    // MARK: - Yerel yakalama (tek motor: LiveKit) — renderer + startLocalRecording

    /// LiveKit ses motorunu yerel kayda al ve PCM renderer'ı bağla. Böylece track
    /// YAYINLANMASA bile (uyku) mic PCM'i wake tanıyıcıya akar. Idempotent.
    private func startLocalCapture() {
        guard localRecordingActive == false else { return }
        if wakeRenderer == nil {
            let renderer = WakePCMRenderer { [wake] buffer in wake.appendPCM(buffer) }
            wakeRenderer = renderer
            AudioManager.shared.add(localAudioRenderer: renderer)
        }
        do {
            try AudioManager.shared.startLocalRecording()
            localRecordingActive = true
            Log.line("[Audio] startLocalRecording aktif — PCM renderer bağlı (tek motor)")
        } catch {
            Log.error("[Audio] startLocalRecording HATA: \(error.localizedDescription)")
        }
    }

    private func stopLocalCapture() {
        if localRecordingActive {
            do { try AudioManager.shared.stopLocalRecording() }
            catch { Log.error("[Audio] stopLocalRecording HATA: \(error.localizedDescription)") }
            localRecordingActive = false
        }
        if let renderer = wakeRenderer {
            AudioManager.shared.remove(localAudioRenderer: renderer)
            wakeRenderer = nil
        }
        Log.line("[Audio] local recording durdu + renderer kaldırıldı")
    }

    // MARK: - Dış olaylar (AppView'dan sürülür)

    func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        if isConnected {
            registerCueHandler()
            // TEK motor: bağlanır bağlanmaz yerel yakalamayı başlat (track henüz
            // yayınlanmaz — mod uyku/sürekliye göre setMicrophone'u ayarlar).
            startLocalCapture()
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
    ///   brain dinlesin (`candan.awake = "1"`). Wake kullanılamıyorsa `false` → `"0"`.
    private func disableGate(continuous: Bool) {
        cancelInactivityTimer()
        wake.stop()
        mode = .inactive
        setMicrophone(enabled: true)
        setAwake(continuous)
        if continuous { playReadyOnce() }
    }

    private func enterSleeping(playCue: Bool = true) {
        // Idempotent: zaten uykudaysak tekrar girme (re-arm'da çift tetik önlenir).
        guard mode != .sleeping else {
            Log.line("[Coord] enterSleeping atlandı (zaten uykuda)")
            return
        }
        Log.line("[Coord] → UYKU (mic unpublish; brain duymaz; wake PCM startLocalRecording'den akar)")
        cancelInactivityTimer()
        mode = .sleeping
        // Temiz yeniden başlatma: stale tanıma isteğini temizle.
        wake.stop()
        // TEK yakalama yolu: ÖNCE startLocalRecording'i garanti et (renderer → wake PCM),
        // SONRA published mic track'i UNPUBLISH et. Böylece uyku sırasında yalnız tek
        // capture döner; brain'e giden ikinci (RED-encode'lu) yayın yolu kapanır →
        // CoreAudio IO overload + ~28sn full-reconnect döngüsü biter. Capture sürdüğü
        // için wake dinleme çalışır VE brain uyku sırasındaki sesi görmez.
        startLocalCapture() // idempotent: renderer + startLocalRecording
        setMicrophone(enabled: false) // MUTE değil UNPUBLISH (aşağıda)
        setAwake(false)
        if playCue, settings?.cuesEnabled == true { cues.playSleeping() }
        startWakeListening()
    }

    private func enterAwake() {
        Log.line("[Coord] → UYANIK (wake tanıma stop, mevcut yakalamayı publish)")
        mode = .awake
        // Tanımayı durdur (artık wake aramaya gerek yok). Renderer bağlı kalır;
        // aktif istek olmadığı için appendPCM sessiz no-op olur.
        wake.stop()
        if settings?.cuesEnabled == true { cues.playWakeDetected() }
        // Mic ZATEN yakalıyor (startLocalRecording). Publish etmeden önce KISA
        // settle: konuşulan "candan"ın kuyruğu brain'e gitmesin. VPIO açık olduğundan
        // chime echo-cancel edilir. Bu bekleme CİHAZ DEVRİ İÇİN DEĞİL — motor devri
        // yok; sadece söz kuyruğu için. Bekleme sırasında mod değiştiyse publish etme.
        let settle = readyCueSettleSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard let self, self.mode == .awake else { return }
            // Track YAYINLANDIĞI an awake='1': settle'dan önce gönderirsek konuşulan
            // "candan" hâlâ açık pencerede sayılabilirdi.
            self.setMicrophone(enabled: true)
            self.setAwake(true)
        }
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
        stopLocalCapture()
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

    // MARK: - Track mute/unmute — yakalama bundan BAĞIMSIZ

    /// Mic'i brain'e YAYINLA (publish) ya da yayından TAMAMEN KALDIR (unpublish).
    /// enabled=true → setMicrophone(true): track oluşturup yayınlar (brain duyar).
    /// enabled=false → MUTE DEĞİL UNPUBLISH: published mic track(ler)i tamamen kaldırır.
    /// Böylece startLocalRecording capture'ı (renderer → wake PCM) TEK yakalama yolu
    /// olarak kalır; brain'e giden ikinci (RED-encode'lu) yayın yolu kapanır →
    /// CoreAudio IO overload + ~28sn full-reconnect döngüsü biter.
    private func setMicrophone(enabled: Bool) {
        micShouldBeLive = enabled
        guard let session else { return }
        let lp = session.room.localParticipant
        Task {
            do {
                if enabled {
                    try await lp.setMicrophone(enabled: true)
                    Log.line("[Mic] published — brain duyar")
                } else {
                    // Mute değil unpublish: brain'e giden yayın/encode yolunu kapat.
                    for pub in lp.localAudioTracks {
                        try? await lp.unpublish(publication: pub)
                    }
                    Log.line("[Mic] unpublished — brain duymaz, wake PCM startLocalRecording'den akar")
                }
            } catch {
                Log.error("[Mic] setMicrophone(\(enabled)) HATA: \(error.localizedDescription)")
            }
        }
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

    /// Tüm participant attribute'larını (brain ayarları + `candan.awake`) TEK sözlük
    /// olarak yayınlar. Brain `candan.awake == "0"` iken başlayan sözleri yok sayar.
    func publishAttributes() {
        guard let session, session.isConnected else {
            Log.line("[Attr] publishAttributes atlandı — bağlı değil")
            return
        }
        var attrs = settings?.brainAttributes ?? [:]
        attrs["candan.awake"] = isAwake ? "1" : "0"
        Log.line("[Attr] → candan.awake=\(isAwake ? "1" : "0") attrs=\(attrs)")
        Task {
            do {
                try await session.room.localParticipant.set(attributes: attrs)
                Log.line("[Attr] set OK")
            } catch {
                Log.error("[Attr] set FAILED (canUpdateOwnMetadata izni yok?): \(error.localizedDescription)")
            }
        }
    }
}
