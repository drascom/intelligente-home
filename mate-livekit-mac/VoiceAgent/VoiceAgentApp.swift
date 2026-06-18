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
    //     --join --room mate-demo --identity mac-client --valid-for 24h'
    //
    // Paste the "Access token" value into `selfHostedToken` below.
    //
    // LAN (home): direct to vox over plain ws. Off-LAN, switch back to the
    // Tailscale URL `wss://vox.tailfe7e95.ts.net`.
    //
    // To revert to the LiveKit Cloud sandbox, replace the `session`
    // initializer with the original SandboxTokenSource version (see git
    // history / README) and supply LIVEKIT_SANDBOX_ID via .env.xcconfig.

    private static let selfHostedServerURL = URL(string: "ws://192.168.0.150:7880")!

    private static let selfHostedToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJkZXZrZXkiLCJzdWIiOiJtYWMtY2xpZW50IiwiZXhwIjoxNzgxOTAxMDg4LCJuYmYiOjE3ODE4MTQ2ODgsImlhdCI6MTc4MTgxNDY4OCwiaWRlbnRpdHkiOiJtYWMtY2xpZW50IiwibmFtZSI6Im1hYy1jbGllbnQiLCJ2aWRlbyI6eyJyb29tSm9pbiI6dHJ1ZSwicm9vbSI6Im1hdGUtZGVtbyJ9fQ.Ae5sfmLgCzQsoSdKe0_ZzL6FZFY-tLl6NkWUkNvKl0Y"

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
