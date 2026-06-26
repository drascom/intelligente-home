import LiveKit
import SwiftUI

/// A multiplatform view that shows text-specific interaction controls.
///
/// Shows the agent participant view plus a complete chat view with text input.
struct TextInteractionView: View {
    @EnvironmentObject private var session: Session

    @FocusState.Binding var keyboardFocus: Bool
    /// Mesaj yazma alanı görünür mü (varsayılan gizli; ControlBar text düğmesi açar).
    @Binding var showInput: Bool

    var body: some View {
        VStack {
            VStack {
                participants()
                // Sohbet alanı en fazla pencere yüksekliğinin %60'ı; en yeni mesaj
                // (alt) net, yukarı doğru üst kenarda yumuşak fade (blurredTop mask).
                GeometryReader { geo in
                    ChatView()
                    #if os(macOS)
                        .frame(maxWidth: 128 * .grid)
                    #endif
                        .frame(maxWidth: .infinity, maxHeight: geo.size.height * 0.6, alignment: .bottom)
                        .blurredTop()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                keyboardFocus = false
            }
            #endif
            if showInput {
                ChatInputView(keyboardFocus: _keyboardFocus) { showInput = false }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: showInput)
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
