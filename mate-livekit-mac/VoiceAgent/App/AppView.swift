import LiveKit
import SwiftUI

struct AppView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia
    @EnvironmentObject private var settings: SettingsStore

    @StateObject private var wakeCoordinator = WakeCoordinator()

    // Sohbet/transkript ekranını öne çıkar: bağlanınca konuşma metni (kullanıcı
    // + asistan satırları) doğrudan görünür. ControlBar'daki buton ile saf ses
    // (görselleştirici) görünümüne geçilebilir.
    @State private var chat: Bool = true
    @State private var showSettings = false
    @FocusState private var keyboardFocus: Bool
    @Namespace private var namespace

    var body: some View {
        ZStack(alignment: .top) {
            if session.isConnected {
                interactions()
            } else {
                start()
            }

            errors()
        }
        .overlay(alignment: .topTrailing) {
            settingsButton()
        }
        .overlay(alignment: .top) {
            if session.isConnected { wakeHint() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Bağlıyken ve ilgili ayarlar değiştikçe brain'e attribute olarak gönder.
        // İstemci-yerel davranışlar (wake/cue/barge-in) gönderilmez.
        .task(id: attributeSnapshot) {
            await pushAttributesIfConnected()
        }
        // Wake-word kapısı + geçiş sesleri.
        .onAppear { wakeCoordinator.attach(session: session, settings: settings) }
        .onChange(of: session.isConnected) { _, connected in
            wakeCoordinator.connectionChanged(connected)
        }
        .onChange(of: session.agent.agentState) { _, state in
            wakeCoordinator.agentStateChanged(state)
        }
        .onChange(of: settings.wakeWordEnabled) { _, _ in
            wakeCoordinator.wakeWordEnabledChanged()
        }
        .environment(\.namespace, namespace)
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
                .animation(.default, value: wakeCoordinator.mode)
                .animation(.default, value: session.isConnected)
                .animation(.default, value: session.error?.localizedDescription)
                .animation(.default, value: session.agent.error?.localizedDescription)
                .animation(.default, value: localMedia.error?.localizedDescription)
        #if os(iOS)
            .sensoryFeedback(.impact, trigger: session.isConnected)
        #endif
    }

    /// `.task(id:)` bunun her değişiminde yeniden çalışır: bağlantı kurulunca
    /// (isConnected false→true) ve üç brain ayarından biri değişince attribute
    /// gönderir. Böylece "bağlı değilken değiştir → bağlanınca uygula" da çalışır.
    private var attributeSnapshot: String {
        "\(session.isConnected)|\(settings.sttEngine)|\(settings.voice)|\(settings.language)"
    }

    private func pushAttributesIfConnected() async {
        guard session.isConnected else { return }
        do {
            try await session.room.localParticipant.set(attributes: settings.brainAttributes)
        } catch {
            // Geçici hata: bir sonraki ayar değişimi / yeniden bağlanmada tekrar denenir.
        }
    }

    private func settingsButton() -> some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.fg1)
                .frame(width: 11 * .grid, height: 11 * .grid)
                .background(
                    RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform)
                        .fill(.bg2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .cornerRadiusPerPlatform)
                        .stroke(.separator1, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding()
    }

    private func start() -> some View {
        StartView()
            .onAppear {
                // Bağlantı kurulunca transkript görünümüyle başla.
                chat = true
            }
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

    /// Uyku modunda (wake bekliyor) küçük bir durum ipucu. Mikrofon butonu da
    /// zaten kapalı (slash) görünür; bu metin tetikleyici kelimeyi hatırlatır.
    /// Hem ses hem sohbet görünümünde üstte gösterilir.
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
