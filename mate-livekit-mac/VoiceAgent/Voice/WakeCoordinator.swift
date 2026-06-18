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
        setMicrophone(enabled: true)
        setAwake(continuous)
    }

    private func enterSleeping(playCue: Bool = true) {
        cancelInactivityTimer()
        mode = .sleeping
        setMicrophone(enabled: false)
        // Uyku: brain bu andan itibaren başlayan sözleri yok saysın.
        setAwake(false)
        if playCue, settings?.cuesEnabled == true { cues.playSleeping() }
        startWakeListening()
    }

    private func enterAwake() {
        mode = .awake
        wake.stop()
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
        guard let settings else { return }
        Task {
            let ok = await wake.requestPermission()
            guard ok else {
                self.unavailableMessage = "Konuşma tanıma izni verilmedi."
                self.disableGate(continuous: false)
                return
            }
            do {
                try wake.start(wakeWord: settings.wakeWord, language: settings.language)
                // Başarıyla dinlemeye başladık → eski uyarıyı temizle.
                self.unavailableMessage = nil
            } catch {
                self.unavailableMessage = error.localizedDescription
                self.disableGate(continuous: false)
            }
        }
    }

    private func setMicrophone(enabled: Bool) {
        guard let session else { return }
        Task {
            try? await session.room.localParticipant.setMicrophone(enabled: enabled)
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
