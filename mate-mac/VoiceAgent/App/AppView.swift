import LiveKit
import SwiftUI

struct AppView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var localMedia: LocalMedia
    @EnvironmentObject private var settings: SettingsStore

    /// Wake-word kapısı + geçiş sesleri + `mate.awake` attribute yayını.
    @StateObject private var wakeCoordinator = WakeCoordinator()

    /// Sunucunun canlı durum satırı (`mate.debug`) — en altta gösterilir.
    @StateObject private var debugMonitor = DebugStatusMonitor()

    /// Kullanıcının kendi sözünü anında gösteren optimistic lokal transkript.
    @StateObject private var echo = LocalEchoTranscriber()

    /// Brain'in gönderdiği zengin içerik (`mate.content`) → sağ panel.
    @StateObject private var contentChannel = ContentChannelReceiver()
    @State private var showContent = false

    /// O an tanınan/aktif konuşmacı (`mate.speaker`) → üstte küçük gösterge.
    @StateObject private var speaker = SpeakerReceiver()

    // Show the transcript/chat view by default; the user can still toggle it
    // off with the text-input button in the ControlBar.
    @State private var chat: Bool = true
    /// Mesaj yazma alanı varsayılan GİZLİ; ControlBar'daki text düğmesiyle açılır.
    @State private var showInput = false
    @State private var showSettings = false
    /// Sıfır-konfig: token endpoint boşsa onboarding sihirbazını göster (ErrorView
    /// yerine). "Başla" ile URL kaydedilince kapanır → autoConnect devreye girer.
    @State private var onboarding = SettingsStore.resolvedTokenEndpointURL.isEmpty
    @FocusState private var keyboardFocus: Bool
    @Namespace private var namespace

    /// Bağlandığında + brain ayarları değiştiğinde attribute yeniden yayınlansın.
    private var attributeSnapshot: String {
        "\(session.isConnected)|\(settings.sttEngine)|\(settings.voice)|\(settings.language)|\(settings.bargeInEnabled)"
    }

    /// Brain'den gelen kesin kullanıcı transkripti sayısı — arttığında optimistic
    /// satırı reconcile et (temizle + taze başlat → duplicate olmaz).
    private var brainUserTranscriptCount: Int {
        session.messages.reduce(0) { count, message in
            if case .userTranscript = message.content { return count + 1 }
            return count
        }
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
        .environmentObject(echo)
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
        // Brain ayarları + mate.awake TEK sözlükte birlikte gider (WakeCoordinator).
        .task(id: attributeSnapshot) { wakeCoordinator.publishAttributes() }
        .onAppear { wakeCoordinator.attach(session: session, settings: settings, echo: echo) }
        .onChange(of: brainUserTranscriptCount) { _, _ in echo.commitCurrent() }
        .onChange(of: session.isConnected) { _, connected in
            wakeCoordinator.connectionChanged(connected)
            debugMonitor.connectionChanged(connected, room: session.room)
            contentChannel.connectionChanged(connected, room: session.room)
            speaker.connectionChanged(connected, room: session.room)
        }
        .onChange(of: contentChannel.latest) { _, item in
            if item != nil { showContent = true } // yeni içerik gelince otomatik aç
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
                    ControlBar(chat: $chat, showInput: $showInput)
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
                        ControlBar(chat: $chat, showInput: $showInput)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
        #endif
                .safeAreaInset(edge: .bottom) { debugStrip() }
                .background { GlassBackdrop() }
                // İçerik katmanı ve üst düğmeler EN DIŞTA: ControlBar/input dahil her
                // şeyin üstünü kaplar; toggle/Settings ise katmanın da üstünde kalır.
                .overlay { contentPanel() }
                // Panel açıkken üst düğmeleri gizle (kapatma panelin kendi (x)'iyle).
                .overlay(alignment: .topTrailing) { if !showContent { topButtons() } }
                .overlay(alignment: .topLeading) {
                    if !showContent, let name = speaker.current?.label { speakerBadge(name) }
                }
                // Sıfır-konfig onboarding — her şeyin ÜSTÜNDE tam ekran.
                .overlay {
                    if onboarding {
                        OnboardingView(onDone: { onboarding = false })
                            .transition(.opacity)
                    }
                }
                .animation(.default, value: chat)
                .animation(.default, value: showContent)
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
            // Onboarding sürerken bağlanma (URL henüz onaylanmadı).
            if !onboarding, !session.isConnected {
                if session.error != nil { session.dismissError() }
                await session.start()
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// Sağ üst köşedeki cam yuvarlak düğmeler: içerik panelini aç/kapa + Settings.
    private func topButtons() -> some View {
        HStack(spacing: 2 * .grid) {
            circleButton("sidebar.trailing") {
                showContent.toggle()
            }
            circleButton("gearshape") {
                showSettings = true
            }
        }
        .padding(3 * .grid)
    }

    /// Üst solda o anki konuşmacı göstergesi (sade glass3 kapsül).
    private func speakerBadge(_ name: String) -> some View {
        HStack(spacing: 1.5 * .grid) {
            Image(systemName: "person.fill")
                .font(.system(size: 12))
            Text(name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(.fg1)
        .padding(.horizontal, 3 * .grid)
        .padding(.vertical, 2 * .grid)
        .glass3(cornerRadius: 5 * .grid)
        .padding(3 * .grid)
        .transition(.opacity)
    }

    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.fg1)
                .frame(width: 10 * .grid, height: 10 * .grid)
                .glass3(cornerRadius: 5 * .grid)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    /// Açılır-kapanır içerik katmanı (frosted #3) — TAM GENİŞLİK + TAM BOY,
    /// sohbeti/kontrolleri kaplar. Yeni içerik gelince otomatik açılır; toggle
    /// düğmesi veya içindeki (x) ile kapanır. İSKELE (render sonraki tur).
    @ViewBuilder
    private func contentPanel() -> some View {
        if showContent {
            ContentPanelView(items: contentChannel.items) { showContent = false }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .glass3(cornerRadius: 0, strong: true)
                .ignoresSafeArea()
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
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

    /// Sunucunun canlı durum satırı — en altta soluk, monospace, tek satır.
    /// Boşken hiç yer kaplamaz.
    @ViewBuilder
    private func debugStrip() -> some View {
        if !debugMonitor.lastLine.isEmpty {
            Text(debugMonitor.lastLine)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2 * .grid)
                .padding(.vertical, .grid)
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
            TextInteractionView(keyboardFocus: $keyboardFocus, showInput: $showInput)
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
