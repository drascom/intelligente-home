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

    private let wake = WakeWordDetector()
    private let cues = CueSounds()

    private var session: Session?
    private var settings: SettingsStore?

    private var connected = false
    private var inactivityTask: Task<Void, Never>?

    func attach(session: Session, settings: SettingsStore) {
        guard self.session == nil else { return }
        self.session = session
        self.settings = settings
        wake.onWakeDetected = { [weak self] in self?.handleWakeDetected() }
        wake.onUnavailable = { [weak self] msg in
            self?.unavailableMessage = msg
            // Wake kullanılamıyorsa kapıyı aç: mikrofon normal kullanılabilsin.
            self?.disableGate()
        }
    }

    // MARK: - Dış olaylar (AppView'dan sürülür)

    func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        if isConnected {
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
            disableGate()
        }
    }

    /// Wake kapısını devre dışı bırak: dinleyiciyi durdur, mikrofonu aç.
    private func disableGate() {
        cancelInactivityTimer()
        wake.stop()
        mode = .inactive
        setMicrophone(enabled: true)
    }

    private func enterSleeping(playCue: Bool = true) {
        cancelInactivityTimer()
        mode = .sleeping
        setMicrophone(enabled: false)
        if playCue, settings?.cuesEnabled == true { cues.playSleeping() }
        startWakeListening()
    }

    private func enterAwake() {
        mode = .awake
        wake.stop()
        if settings?.cuesEnabled == true { cues.playWakeDetected() }
        setMicrophone(enabled: true)
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
                self.disableGate()
                return
            }
            do {
                try wake.start(wakeWord: settings.wakeWord, language: settings.language)
                // Başarıyla dinlemeye başladık → eski uyarıyı temizle.
                self.unavailableMessage = nil
            } catch {
                self.unavailableMessage = error.localizedDescription
                self.disableGate()
            }
        }
    }

    private func setMicrophone(enabled: Bool) {
        guard let session else { return }
        Task {
            try? await session.room.localParticipant.setMicrophone(enabled: enabled)
        }
    }
}
