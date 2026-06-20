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
    // Kullanıcı "kapat" butonuna bastıysa true → ConnectingView otomatik yeniden
    // bağlanmaz, manuel "Bağlan" gösterir. Açılışta false → otomatik bağlanır.
    @State private var userDisconnected = false
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
        .overlay(alignment: .topTrailing) {
            settingsButton()
        }
        .overlay(alignment: .top) {
            if session.isConnected {
                // Wake başlatılamadıysa (SFSpeech yok / Dikte kapalı / izin yok)
                // nedeni öne çıkar; aksi halde küçük "bekleniyor" ipucu.
                if let msg = wakeCoordinator.unavailableMessage {
                    wakeUnavailableBanner(msg)
                } else {
                    wakeHint()
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // Bağlıyken ve ilgili ayarlar değiştikçe brain'e attribute olarak gönder.
        // Yayını WakeCoordinator yapar: brain ayarları (stt_engine/voice/language)
        // + candan.awake TEK sözlükte birlikte gider (biri diğerini ezmesin).
        .task(id: attributeSnapshot) {
            wakeCoordinator.publishAttributes()
        }
        // Wake-word kapısı + geçiş sesleri.
        .onAppear { wakeCoordinator.attach(session: session, settings: settings) }
        .onChange(of: session.isConnected) { _, connected in
            wakeCoordinator.connectionChanged(connected)
        }
        // session.start() bağlanınca mic'i otomatik publish eder; uyku modundaysak
        // WakeCoordinator bunu geri bırakır (mic yalnız awake/sürekli modda canlı).
        .onChange(of: localMedia.isMicrophoneEnabled) { _, enabled in
            wakeCoordinator.microphoneStateChanged(enabled)
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
                    ControlBar(chat: $chat, userDisconnected: $userDisconnected)
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
                        ControlBar(chat: $chat, userDisconnected: $userDisconnected)
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
                .animation(.default, value: wakeCoordinator.unavailableMessage)
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

    private func connecting() -> some View {
        ConnectingView(userDisconnected: $userDisconnected)
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

    /// Wake word başlatılamadığında (SFSpeech kullanılamıyor / macOS Dikte kapalı
    /// / konuşma tanıma izni yok) nedeni öne çıkaran uyarı. Bu durumda kapı
    /// devre dışıdır ve mikrofon SÜREKLİ açıktır — kullanıcı nedenini ve nasıl
    /// düzelteceğini görmeli.
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
            #if os(macOS)
                Text("“\(settings.wakeWord)” ile uyandırmak için: Sistem Ayarları › Klavye › Dikte'yi açın (dil: Türkçe — Dikte/Siri dili sistem diliyle uyuşmalı), sonra yeniden bağlanın. O zamana kadar mikrofon açık kalır.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            #else
                Text("“\(settings.wakeWord)” ile uyandırmak için Ayarlar'dan Konuşma Tanıma/Dikte ve mikrofon iznini açın. O zamana kadar mikrofon açık kalır.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .padding(3 * .grid)
        .background(
            RoundedRectangle(cornerRadius: .cornerRadiusLarge)
                .fill(.bg2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .cornerRadiusLarge)
                .stroke(.orange.opacity(0.4), lineWidth: 1)
        )
        .frame(maxWidth: 120 * .grid)
        .padding(.horizontal, 4 * .grid)
        // Sağ üstteki dişli butonun altına in (dar ekranda çakışmasın).
        .padding(.top, 15 * .grid)
        .transition(.move(edge: .top).combined(with: .opacity))
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
