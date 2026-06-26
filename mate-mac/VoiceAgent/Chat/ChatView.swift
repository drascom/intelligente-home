import LiveKit
import LiveKitComponents
import SwiftUI

/// Agent "düşünüyor" göstergesi: yumuşak yanıp sönen 3 nokta.
private struct TypingDots: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 1.5 * .grid) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .frame(width: 1.75 * .grid, height: 1.75 * .grid)
                    .foregroundStyle(.fg1)
                    .opacity(animating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

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
            // Agent "düşünüyor" → sol agent balonu içinde yazıyor göstergesi.
            // Yanıt gelmeye başlayınca state thinking'den çıkar → balon kaybolur.
            if session.agent.agentState == .thinking {
                thinkingBubble()
            }
        }
        .padding(.horizontal)
        .animation(.default, value: session.messages)
        .animation(.default, value: echo.provisional)
        .animation(.default, value: session.agent.agentState)
    }

    private func thinkingBubble() -> some View {
        HStack {
            TypingDots()
                .padding(.horizontal, 4 * .grid)
                .padding(.vertical, 3 * .grid)
                .glass3(cornerRadius: .cornerRadiusLarge)
            Spacer(minLength: 8 * .grid)
        }
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
