import LiveKit
import SwiftUI

@main
struct VoiceAgentApp: App {
    // MARK: - Self-hosted server connection (mate / candan assistant)
    //
    // We bypass the LiveKit Cloud sandbox and connect directly to our
    // self-hosted LiveKit server with a manually-minted token.
    //
    // Mint a fresh token on the server (tokens expire — default 24h):
    //   ssh root@192.168.0.150 '/usr/local/bin/lk token create \
    //     --api-key devkey \
    //     --api-secret 27f2320ab1a3f90a8d783671e970bec192e5add006345d5a \
    //     --join --room mate-demo --identity starter-ios --valid-for 24h'
    //
    // Paste the "Access token" value into `selfHostedToken` below.
    //
    // To revert to the LiveKit Cloud sandbox, replace the `session`
    // initializer with the original SandboxTokenSource version (see git
    // history / README) and supply LIVEKIT_SANDBOX_ID via .env.xcconfig.

    private static let selfHostedServerURL = URL(string: "wss://vox.tailfe7e95.ts.net")!

    private static let selfHostedToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJkZXZrZXkiLCJzdWIiOiJzdGFydGVyLWlvcyIsImV4cCI6MTc4MTg3MTE1MywibmJmIjoxNzgxNzg0NzUzLCJpYXQiOjE3ODE3ODQ3NTMsImlkZW50aXR5Ijoic3RhcnRlci1pb3MiLCJuYW1lIjoic3RhcnRlci1pb3MiLCJ2aWRlbyI6eyJyb29tSm9pbiI6dHJ1ZSwicm9vbSI6Im1hdGUtZGVtbyJ9fQ.w4uJfUnrsTvrDQKKBKWj6nvJPoRqbl07Ear4WFyFW1w"

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
