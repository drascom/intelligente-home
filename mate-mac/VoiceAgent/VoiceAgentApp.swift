import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    // MARK: - Self-hosted server connection (mate / candan assistant)
    //
    // We bypass the LiveKit Cloud sandbox and connect directly to our
    // self-hosted LiveKit server (oracle-stage) with a manually-minted token.
    //
    // Server URL + participant token live in a gitignored `Secrets.swift`.
    // See that file for how to mint a fresh token on oracle-stage.
    //
    // To revert to the LiveKit Cloud sandbox, replace the `session`
    // initializer with the original SandboxTokenSource version (see git
    // history / README) and supply LIVEKIT_SANDBOX_ID via .env.xcconfig.

    // Voice-only assistant: no screen share / broadcast capture configured.
    private let session: Session
    private let localMedia: LocalMedia

    // Pins the app's audio input/output to the user's chosen device,
    // independently of the macOS system default, and remembers the choice.
    @StateObject private var deviceStore = AudioDeviceStore()

    // User settings (wake word, brain attributes, cues…), persisted to UserDefaults.
    @StateObject private var settings = SettingsStore()

    init() {
        // Mute the harmless macOS 26 VPIO/CoreAudio stderr firehose so real logs
        // stay readable. Install before anything touches the audio engine.
        #if os(macOS)
        AudioLogNoiseFilter.install()
        #endif

        // Kendi Room'umuzu kurup Session'a veriyoruz ki transcript'leri özel
        // alıcıyla (CandanTranscriptionReceiver) tüketebilelim: brain hem kullanıcı
        // hem asistan satırını "assistant" kimliğinden yollar; SDK'nın varsayılan
        // receiver'ı gönderene göre atfettiği için kullanıcı sözünü yanlış işaretler.
        // Varsayılan transcription receiver'ı bizimkiyle DEĞİŞTİRİYORUZ (aynı topic'e
        // iki kayıt çakışır). Metin gönderme (senders) varsayılan kalır.
        let room = Room()
        let session = Session(
            tokenSource: LiteralTokenSource(
                serverURL: URL(string: Secrets.livekitServerURL)!,
                participantToken: Secrets.livekitToken,
                participantName: "mac-client",
                roomName: "mate-demo"
            ),
            options: SessionOptions(room: room),
            receivers: [CandanTranscriptionReceiver(room: room)]
        )
        self.session = session
        localMedia = LocalMedia(session: session)
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(localMedia)
                .environmentObject(deviceStore)
                .environmentObject(settings)
                .environment(\.voiceEnabled, true)
                .environment(\.textEnabled, true)
                // Cam/koyu tema: tüm semantik renkler (fg1/fg2/secondary…) açık
                // (beyaz/açık-gri) varyantına çözülsün → koyu zeminde okunur.
                .preferredColorScheme(.dark)
                .task { deviceStore.start(localMedia: localMedia) }
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
