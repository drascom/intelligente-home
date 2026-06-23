import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    // MARK: - Self-hosted server connection (mate / candan assistant)
    //
    // We bypass the LiveKit Cloud sandbox and connect directly to our
    // self-hosted LiveKit server with a manually-minted token.
    //
    // Server URL + participant token live in `Secrets.swift` (gitignored,
    // never committed). See that file for how to mint a fresh token.
    //
    // To revert to the LiveKit Cloud sandbox, replace the `session`
    // initializer with the original SandboxTokenSource version (see git
    // history / README) and supply LIVEKIT_SANDBOX_ID via .env.xcconfig.

    private static let selfHostedServerURL = URL(string: Secrets.livekitServerURL)!

    private static let selfHostedToken = Secrets.livekitToken

    private let session: Session
    private let settings = SettingsStore()

    init() {
        // VPIO (voice-processing I/O / donanım AEC) AÇIK.
        //
        // NEDEN AÇIK: mic SÜREKLI yayında (sunucu awake kapısı) olduğundan asistanın
        // TTS cevabı hoparlörden çalarken mic onu yakalıyordu → brain kendi sesini
        // "kullanıcı konuşması" sanıp barge-in ile cevabını kesiyordu; ayrıca full-duplex
        // (aynı anda capture+playback) VPIO'suz CoreAudio'yu zorluyordu (HALC overload).
        // VPIO donanım AEC + gürültü bastırma (NS) + AGC yapar: asistanın KENDİ sesini
        // mic girişinden iptal eder (brain yalnız DIŞ sesi/kullanıcıyı duyar), gürültüyü
        // bastırır, full-duplex'i verimli yürütür. Wake renderer de temizlenmiş PCM alır.
        // Motor başlamadan (bağlanmadan) ÖNCE ayarlanmalı (motor yeniden başlatma ister).
        //
        // ⚠️ USB KULAKLIK CAVEAT: VPIO input+output'u birleştiren CoreAudio AGGREGATE
        // DEVICE kurar; USB tek-cihaz kulaklıkta bu kurulamıyor → StartIO `error 35` →
        // mic hiç başlamaz → wake duyulmaz. Dahili mic+hoparlörde sorun YOK. Bu yüzden
        // VPIO'yu cihaz tipine göre KOŞULLU açıyoruz (yalnız dahili) — başlangıçta
        // mevcut giriş cihazına göre, sonradan cihaz değişiminde AudioDeviceSelector'da.
        // Bkz. VoiceProcessingPolicy. Motor başlamadan ÖNCE ayarlanmalı (burası init).
        VoiceProcessingPolicy.applyForCurrentInputDevice()

        // Kendi Room'umuzu kurup Session'a veriyoruz ki transcript'leri özel
        // alıcıyla (CandanTranscriptionReceiver) tüketebilelim: brain hem kullanıcı
        // hem asistan satırını "assistant" kimliğinden yollar; SDK'nın varsayılan
        // receiver'ı gönderene göre atfettiği için kullanıcı sözünü yanlış işaretler.
        // Bu yüzden varsayılan transcription receiver'ı bizimkiyle DEĞİŞTİRİYORUZ
        // (aynı topic'e iki kayıt çakışır). Metin gönderme (senders) varsayılan kalır.
        let room = Room()
        session = Session(
            tokenSource: LiteralTokenSource(
                serverURL: Self.selfHostedServerURL,
                participantToken: Self.selfHostedToken,
                participantName: "mac-client",
                roomName: "mate-demo"
            ),
            // preConnectAudio KAPALI: açıkken Session bağlanmadan ÖNCE mic'i açıp bir
            // preconnect track yayınlar; sonradan setMicrophone AYRI track üzerinde
            // çalışır → İKİ mic track (biri hep canlı, brain'e sızar + wake dinleyiciyle
            // mic çakışır). Kapalı = tek deterministik track (WakeCoordinator yönetir).
            options: SessionOptions(room: room, preConnectAudio: false),
            receivers: [CandanTranscriptionReceiver(room: room)]
        )
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(LocalMedia(session: session))
                .environmentObject(settings)
                .environment(\.voiceEnabled, true)
                .environment(\.textEnabled, true)
        }
        #if os(macOS)
        .defaultSize(width: 900, height: 900)
        #endif
        #if os(visionOS)
        .windowStyle(.plain)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1500, height: 500)
        #endif
    }
}
