import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    // MARK: - Self-hosted server connection (mate / candan assistant)
    //
    // We bypass the LiveKit Cloud sandbox and connect directly to our
    // self-hosted LiveKit server with a manually-minted token.
    //
    // Server URL + participant token must NOT be hardcoded here. Mint a token
    // on the server and supply it locally (e.g. a gitignored Secrets.swift,
    // mirroring mate-livekit-mac):
    //   ssh root@192.168.0.150 '/usr/local/bin/lk token create \
    //     --api-key devkey --api-secret <LIVEKIT_API_SECRET on vox> \
    //     --join --room mate-demo --identity starter-ios --valid-for 24h'
    //
    // To revert to the LiveKit Cloud sandbox, replace the `session`
    // initializer with the original SandboxTokenSource version (see git
    // history / README) and supply LIVEKIT_SANDBOX_ID via .env.xcconfig.

    private static let selfHostedServerURL = URL(string: "ws://192.168.0.150:7880")!

    private static let selfHostedToken = "PASTE_TOKEN_HERE"

    // Voice-only assistant: no screen share / broadcast capture configured.
    private let session = Session(
        tokenSource: LiteralTokenSource(
            serverURL: Self.selfHostedServerURL,
            participantToken: Self.selfHostedToken,
            participantName: "starter-ios",
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
