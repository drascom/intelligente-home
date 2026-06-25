import LiveKitComponents
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var echo: LocalEchoTranscriber

    var body: some View {
        VStack(spacing: 2 * .grid) {
            ChatScrollView(messageBuilder: message)
            // Optimistic: kullanıcının kendi sözü ANINDA (soluk) — brain kesin
            // transkripti gelince WakeCoordinator/AppView reconcile ile temizler.
            if !echo.provisional.isEmpty {
                provisionalBubble(echo.provisional)
            }
        }
        .padding(.horizontal)
        .animation(.default, value: session.messages)
        .animation(.default, value: echo.provisional)
    }

    private func provisionalBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 8 * .grid)
            accentBubble(text)
        }
        .opacity(0.5)
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
            accentBubble(text)
        }
    }

    private func agentTranscript(_ text: String) -> some View {
        HStack {
            agentBubble(text)
            Spacer(minLength: 8 * .grid)
        }
    }

    /// Kullanıcı balonu — accent (mavi) cam-tarzı, parlak highlight.
    private func accentBubble(_ text: String) -> some View {
        bubbleText(text)
            .foregroundStyle(.white)
            .background(
                LinearGradient(colors: [Color(red: 0.23, green: 0.63, blue: 1), .bgAccent],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: .cornerRadiusLarge, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .cornerRadiusLarge, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .bgAccent.opacity(0.4), radius: 8, y: 4)
    }

    /// Agent balonu — frosted #3 cam.
    private func agentBubble(_ text: String) -> some View {
        bubbleText(text)
            .foregroundStyle(.fg1)
            .glass3(cornerRadius: .cornerRadiusLarge)
    }

    private func bubbleText(_ text: String) -> some View {
        Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
            .font(.system(size: 17))
            .padding(.horizontal, 4 * .grid)
            .padding(.vertical, 2 * .grid)
    }
}
