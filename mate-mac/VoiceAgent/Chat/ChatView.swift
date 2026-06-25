import LiveKitComponents
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        ChatScrollView(messageBuilder: message)
            .padding(.horizontal)
            .animation(.default, value: session.messages)
    }

    private func message(_ message: ReceivedMessage) -> some View {
        ZStack {
            switch message.content {
            case let .userTranscript(text), let .userInput(text):
                userTranscript(text)
            case let .agentTranscript(text):
                agentTranscript(text)
            }
        }
    }

    // User messages are aligned to the trailing edge (right) with an accent
    // bubble; agent messages are aligned to the leading edge (left) with a
    // neutral bubble — a standard two-sided chat layout.
    private func userTranscript(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 8 * .grid)
            bubble(text, foreground: .white, background: .bgAccent)
        }
    }

    private func agentTranscript(_ text: String) -> some View {
        HStack {
            bubble(text, foreground: .fg1, background: .bg2)
            Spacer(minLength: 8 * .grid)
        }
    }

    private func bubble(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 17))
            .padding(.horizontal, 4 * .grid)
            .padding(.vertical, 2 * .grid)
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: .cornerRadiusLarge)
                    .fill(background)
            )
    }
}
