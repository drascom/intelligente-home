import LiveKit
import SwiftUI

struct AppView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia
    @EnvironmentObject private var settings: SettingsStore

    /// Wake-word kapısı + geçiş sesleri + `candan.awake` attribute yayını.
    @StateObject private var wakeCoordinator = WakeCoordinator()

    // Show the transcript/chat view by default; the user can still toggle it
    // off with the text-input button in the ControlBar.
    @State private var chat: Bool = true
    @State private var showSettings = false
    @FocusState private var keyboardFocus: Bool
    @Namespace private var namespace

    /// Bağlandığında + brain ayarları değiştiğinde attribute yeniden yayınlansın.
    private var attributeSnapshot: String {
        "\(session.isConnected)|\(settings.sttEngine)|\(settings.voice)|\(settings.language)"
    }

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
        .overlay(alignment: .topTrailing) { settingsButton() }
        .overlay(alignment: .top) {
            if session.isConnected {
                if let msg = wakeCoordinator.unavailableMessage {
                    wakeUnavailableBanner(msg)
                } else {
                    wakeHint()
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        // Brain ayarları + candan.awake TEK sözlükte birlikte gider (WakeCoordinator).
        .task(id: attributeSnapshot) { wakeCoordinator.publishAttributes() }
        .onAppear { wakeCoordinator.attach(session: session, settings: settings) }
        .onChange(of: session.isConnected) { _, connected in
            wakeCoordinator.connectionChanged(connected)
        }
        // session.start() bağlanınca mic'i otomatik publish eder; uyku modundaysak
        // WakeCoordinator istenmeden yayınlanan track'i geri bırakır.
        .onChange(of: localMedia.isMicrophoneEnabled) { _, enabled in
            wakeCoordinator.microphoneStateChanged(enabled)
        }
        .onChange(of: session.agent.agentState) { _, state in
            wakeCoordinator.agentStateChanged(state)
        }
        .onChange(of: settings.wakeWordEnabled) { _, _ in
            wakeCoordinator.wakeWordEnabledChanged()
        }
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

    private func settingsButton() -> some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 17))
                .padding()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.fg2)
        .accessibilityLabel(Text("settings.title"))
    }

    /// Uyku modunda (wake bekliyor) küçük durum ipucu; tetikleyici kelimeyi hatırlatır.
    @ViewBuilder
    private func wakeHint() -> some View {
        if wakeCoordinator.mode == .sleeping {
            Text("“\(settings.wakeWord)” bekleniyor")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.vertical, 2 * .grid)
                .padding(.horizontal, 4 * .grid)
                .background(Capsule().fill(.bg2))
                .shimmering()
                .padding(.top, 2 * .grid)
                .transition(.blurReplace)
        }
    }

    /// Wake başlatılamadığında (SFSpeech yok / Dikte kapalı / izin yok) nedeni öne
    /// çıkar; bu durumda kapı devre dışıdır ve mikrofon SÜREKLİ açıktır.
    private func wakeUnavailableBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2 * .grid) {
            HStack(alignment: .firstTextBaseline, spacing: 2 * .grid) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Wake word başlatılamadı — mikrofon sürekli açık")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.fg1)
                Spacer(minLength: 2 * .grid)
                Button {
                    wakeCoordinator.unavailableMessage = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(3 * .grid)
        .background(RoundedRectangle(cornerRadius: .cornerRadiusLarge).fill(.bg2))
        .padding(.horizontal)
        .padding(.top, 2 * .grid)
        .transition(.move(edge: .top).combined(with: .opacity))
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
