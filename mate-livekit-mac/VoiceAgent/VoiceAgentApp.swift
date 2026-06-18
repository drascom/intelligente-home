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

    // Voice-only assistant: no screen share / broadcast capture configured.
    private let session = Session(
        tokenSource: LiteralTokenSource(
            serverURL: Self.selfHostedServerURL,
            participantToken: Self.selfHostedToken,
            participantName: "mac-client",
            roomName: "mate-demo"
        )
    )

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(session)
                .environmentObject(LocalMedia(session: session))
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
