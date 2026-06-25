import LiveKit
import SwiftUI

struct AppView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia

    // Show the transcript/chat view by default; the user can still toggle it
    // off with the text-input button in the ControlBar.
    @State private var chat: Bool = true
    @FocusState private var keyboardFocus: Bool
    @Namespace private var namespace

    var body: some View {
        ZStack(alignment: .top) {
            if session.isConnected {
                interactions()
            } else {
                connecting()
            }

            errors()
        }
        .environment(\.namespace, namespace)
        .task { await autoConnect() }
        #if os(visionOS)
            .ornament(attachmentAnchor: .scene(.bottom)) {
                if session.isConnected {
                    ControlBar(chat: $chat)
                        .glassBackgroundEffect()
                }
            }
            .alert(session.error?.localizedDescription ?? "error.title", isPresented: .constant(session.error != nil)) {
                Button("error.ok") { session.dismissError() }
            }
            .alert(
                session.agent.error?.localizedDescription ?? "error.title",
                isPresented: .constant(session.agent.error != nil)
            ) {
                Button("error.ok") { Task { await session.end() } }
            }
            .alert(
                localMedia.error?.localizedDescription ?? "error.title",
                isPresented: .constant(localMedia.error != nil)
            ) {
                Button("error.ok") { localMedia.dismissError() }
            }
        #else
            .safeAreaInset(edge: .bottom) {
                    if session.isConnected, !keyboardFocus {
                        ControlBar(chat: $chat)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
        #endif
                .background(.bg1)
                .animation(.default, value: chat)
                .animation(.default, value: session.isConnected)
                .animation(.default, value: session.error?.localizedDescription)
                .animation(.default, value: session.agent.error?.localizedDescription)
                .animation(.default, value: localMedia.error?.localizedDescription)
        #if os(iOS)
            .sensoryFeedback(.impact, trigger: session.isConnected)
        #endif
    }

    /// Auto-connect: keep a live connection to the room without a manual Start
    /// button. The SDK heals transient drops itself (`.reconnecting`); this loop
    /// covers the cases it can't — initial connect, and a full disconnect
    /// (room closed / agent gone) — by re-calling `start()` until connected.
    /// `start()` no-ops while already connecting/connected, so the 2s poll is
    /// cheap and self-healing.
    private func autoConnect() async {
        while !Task.isCancelled {
            if !session.isConnected {
                if session.error != nil { session.dismissError() }
                await session.start()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func connecting() -> some View {
        VStack(spacing: 4 * .grid) {
            Spinner()
            Text("Bağlanıyor…")
                .font(.system(size: 13))
                .foregroundStyle(.fg3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func interactions() -> some View {
        if chat {
            TextInteractionView(keyboardFocus: $keyboardFocus)
        } else {
            VoiceInteractionView()
                .overlay(alignment: .bottom) {
                    agentListening()
                        .padding()
                }
        }
    }

    @ViewBuilder
    private func errors() -> some View {
        #if !os(visionOS)
            if let error = session.error {
                ErrorView(error: error) { session.dismissError() }
            }

            if let agentError = session.agent.error {
                ErrorView(error: agentError) { Task { await session.end() }}
            }

            if let mediaError = localMedia.error {
                ErrorView(error: mediaError) { localMedia.dismissError() }
            }
        #endif
    }

    private func agentListening() -> some View {
        ZStack {
            if session.messages.isEmpty {
                Text("agent.listening")
                    .font(.system(size: 15))
                    .shimmering()
                    .transition(.blurReplace)
            }
        }
        .animation(.default, value: session.messages.isEmpty)
    }
}
