import SwiftUI

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var conversation: ConversationManager
    @State private var showSettings = false
    @State private var serverAlertMessage: String?
    // Settings açıkken oturum askıda: mikrofon/wake/bridge tamamen durur
    // (arkada dönen ses hattı sayfayı donduruyordu). Kapanınca, açılmadan
    // önce çalışıyorduysa YENİ ayarlarla sıfırdan kurulur.
    @State private var resumeAfterSettings = false
    #if os(macOS)
    @State private var inputDevices: [MacAudioDevice] = []
    @State private var outputDevices: [MacAudioDevice] = []
    // iOS'taki route picker ikonunun macOS karşılığı: ikon + popover.
    @State private var showDevicePicker = false
    #endif

    /// Sohbet doluyken orb arka plana çekilir (küçük + soluk); boşken hero görünüm.
    private var chatActive: Bool { !conversation.messages.isEmpty }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            // Ambiyans katmanı: orb/bars SOHBETİN ARKASINDA yaşar. Sohbet boşken
            // ekranın merkezinde büyük; mesaj gelince küçülüp yukarı çekilir ve
            // soluklaşır — baloncukların material arka planı onu blur'lar.
            centerVisual
                .scaleEffect(chatActive ? 0.55 : 1.0)
                .blur(radius: chatActive ? 2 : 0)
                .opacity(chatActive ? 0.7 : 1.0)
                .offset(y: chatActive ? -150 : -40)
                .animation(.easeInOut(duration: 0.45), value: chatActive)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar

                chatFeed            // tüm kalan yükseklik sohbetin

                statusCapsule
                    .padding(.vertical, 10)

                // Başlat/Duraklat YOK: uygulama açılışta otomatik başlar (wake
                // word bekler). Buton yalnız hata durumunda "Yeniden dene".
                if case .error = conversation.state {
                    retryButton
                        .padding(.bottom, 20)
                } else {
                    Spacer().frame(height: 20)
                }
            }
            .padding(.top, 8)
        }
        .overlay(alignment: .top) {
            if conversation.serverConnected == false && conversation.isRunning && !settings.useOnDeviceTTS {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("Sunucu bağlantısı yok")
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.red.opacity(0.85), in: Capsule())
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: conversation.serverConnected)
        .sheet(isPresented: $showSettings, onDismiss: {
            if resumeAfterSettings {
                resumeAfterSettings = false
                conversation.start()
            }
        }) {
            SettingsView()
                .environmentObject(settings)
        }
        .onChange(of: showSettings) { open in
            if open && conversation.isRunning {
                conversation.stop()
                resumeAfterSettings = true
            }
        }
        .onChange(of: conversation.state) { newState in
            if case .error(let message) = newState, message.hasPrefix("Bağlantı yok:") {
                serverAlertMessage = message
            }
        }
        .alert("Sunucu bağlantısı yok", isPresented: Binding(
            get: { serverAlertMessage != nil },
            set: { if !$0 { serverAlertMessage = nil } }
        )) {
            Button("Ayarlar") {
                serverAlertMessage = nil
                showSettings = true
            }
            Button("Tamam", role: .cancel) {
                serverAlertMessage = nil
            }
        } message: {
            Text(serverAlertMessage ?? "")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.10),
                Color(red: 0.10, green: 0.06, blue: 0.18),
                Color(red: 0.02, green: 0.04, blue: 0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("Mate.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
            sttBadge
            Spacer()
            #if os(iOS)
            RoutePickerView()
                .frame(width: 28, height: 28)
                .padding(8)
                .background(.ultraThinMaterial, in: Circle())
            #else
            // iOS route picker'ın macOS karşılığı: ikon → mic/hoparlör popover'ı.
            Button {
                showDevicePicker.toggle()
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) {
                devicePopover
            }
            #endif
            // Geçici sessize alma: mic'i kapat/aç (oturum/bridge korunur).
            Button {
                conversation.toggleMute()
            } label: {
                Image(systemName: conversation.muted ? "mic.slash.fill" : "mic.fill")
                    .font(.title2)
                    .foregroundStyle(conversation.muted ? .red : .white.opacity(0.7))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!conversation.isRunning)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 20)
    }

    /// Aktif STT rozeti: sunucu bağlıysa brain Whisper'ı, değilse Apple yedeği.
    private var sttBadge: some View {
        let isServer = conversation.serverConnected == true
        return HStack(spacing: 4) {
            Image(systemName: isServer ? "waveform" : "apple.logo")
                .font(.system(size: 10, weight: .semibold))
            Text(isServer ? "Sunucu" : "Apple")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var centerVisual: some View {
        switch conversation.state {
        case .listening:
            BarsView(level: conversation.inputLevel)
                .transition(.opacity)
        case .speaking:
            OrbView(amplitude: conversation.outputAmplitude, hue: 0.78, pulsing: true)
                .transition(.opacity)
        case .transcribing, .synthesizing:
            OrbView(amplitude: 0.15, hue: 0.55, pulsing: true)
                .transition(.opacity)
        case .waitingForWake:
            OrbView(amplitude: 0, hue: 0.42, pulsing: true)
                .opacity(0.55)
                .transition(.opacity)
        case .idle, .waitingPermission, .error:
            OrbView(amplitude: 0, hue: 0.62, pulsing: conversation.state != .idle)
                .opacity(conversation.state == .idle ? 0.4 : 0.85)
                .transition(.opacity)
        }
    }

    /// Durum + ipucu tek kompakt kapsülde, kontrol çubuğunun hemen üstünde.
    /// Satır yükseklikleri sabit → state değişince yerleşim zıplamaz.
    private var statusCapsule: some View {
        VStack(spacing: 2) {
            Text(conversation.state.label)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .frame(height: 18)
            Text(stateSubtitle)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .frame(height: 15)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut, value: conversation.state)
    }

    /// State'e uygun temiz alt başlık. waitingForWake'te wake kelime ipucu üretir.
    private var stateSubtitle: String {
        switch conversation.state {
        case .waitingForWake:
            return settings.wakeWord.isEmpty ? "Wake kelimesini söyle" : "\"\(settings.wakeWord)\" de"
        case .speaking:
            return settings.bargeInEnabled ? "araya girip durdurabilirsin" : ""
        default:
            return conversation.state.subtitle
        }
    }

    /// Sohbet akışı: tüm boş yüksekliği kaplar, en yeni satır ALTTA sabitlenir,
    /// eskiler yukarı kayıp top bar'ın altında yumuşakça kaybolur (fade mask).
    private var chatFeed: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(conversation.messages) { message in
                            chatRow(message)
                                .id(message.id)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geo.size.height, alignment: .bottom)
                }
                .animation(.easeOut(duration: 0.25), value: conversation.messages.count)
                .onChange(of: conversation.messages.last?.id) { lastId in
                    guard let lastId else { return }
                    // scrollTo, satır layout'a girmeden çağrılırsa yeni mesaj görünür
                    // alana gelmiyordu ("cevap bir sonraki turda görünüyor" hatası)
                    // → bir runloop sonraya ertele.
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func chatRow(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 48) }
            Text(message.text)
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(isUser ? Color.white.opacity(0.92) : Color(hue: 0.62, saturation: 0.35, brightness: 1.0))
                .multilineTextAlignment(isUser ? .trailing : .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    .thinMaterial,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(isUser ? 0.10 : 0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
            if !isUser { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// Yalnız hata durumunda görünür: oturumu sıfırdan kurmayı dener.
    private var retryButton: some View {
        Button {
            conversation.stop()
            conversation.start()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise")
                Text("Yeniden dene")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    #if os(macOS)
    /// Mikrofon + hoparlör seçimi (route picker popover'ı). Seçim sistem
    /// varsayılanına uygulanır (engine'ler varsayılanı izler) ve oturum yeni
    /// cihazla yeniden kurulur. "" = sistem varsayılanına dokunma.
    private var devicePopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ses Cihazları")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Picker(selection: $settings.macInputDeviceUID) {
                Text("Sistem varsayılanı").tag("")
                ForEach(inputDevices) { d in
                    Text(d.name).tag(d.id)
                }
            } label: {
                Label("Mikrofon", systemImage: "mic.fill")
            }
            Picker(selection: $settings.macOutputDeviceUID) {
                Text("Sistem varsayılanı").tag("")
                ForEach(outputDevices) { d in
                    Text(d.name).tag(d.id)
                }
            } label: {
                Label("Hoparlör", systemImage: "speaker.wave.2.fill")
            }
        }
        .pickerStyle(.menu)
        .padding(16)
        .frame(width: 340)
        .onAppear {
            // Her açılışta taze liste — sonradan takılan cihazlar görünsün.
            inputDevices = MacAudioDevices.inputDevices()
            outputDevices = MacAudioDevices.outputDevices()
        }
        .onChange(of: settings.macInputDeviceUID) { _ in applyDeviceSelection() }
        .onChange(of: settings.macOutputDeviceUID) { _ in applyDeviceSelection() }
    }

    private func applyDeviceSelection() {
        MacAudioDevices.applyStoredSelection()
        // Engine'ler cihazı start anında bağlar → oturumu yeni cihazla kur.
        if conversation.isRunning {
            conversation.stop()
            conversation.start()
        }
    }
    #endif
}

#Preview {
    ContentView()
        .environmentObject(SettingsStore())
        .environmentObject(ConversationManager())
}
