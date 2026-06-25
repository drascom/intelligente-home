import LiveKit
import SwiftUI

/// A multiplatform view that shows text-specific interaction controls.
///
/// Shows the agent participant view plus a complete chat view with text input.
struct TextInteractionView: View {
    @EnvironmentObject private var session: Session

    @FocusState.Binding var keyboardFocus: Bool

    var body: some View {
        VStack {
            VStack {
                participants()
                ChatView()
                #if os(macOS)
                    .frame(maxWidth: 128 * .grid)
                #endif
                    .blurredTop()
            }
            #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                keyboardFocus = false
            }
            #endif
            ChatInputView(keyboardFocus: _keyboardFocus)
        }
    }

    private func participants() -> some View {
        HStack {
            Spacer()
            AgentView()
                .frame(maxWidth: session.agent.avatarVideoTrack != nil ? 50 * .grid : 25 * .grid)
            Spacer()
        }
        .frame(height: session.agent.avatarVideoTrack != nil ? 50 * .grid : 25 * .grid)
        .safeAreaPadding()
    }
}
