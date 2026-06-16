import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftVoice = ""
    @State private var draftLanguage = ""
    @State private var draftBridgeKey = ""
    @State private var draftWakeEnabled = true
    @State private var draftWakeWord = "candan"
    @State private var draftCuesEnabled = true
    @State private var draftNoiseFilter = true
    @State private var draftBargeIn = true
    @State private var draftUseOnDeviceTTS = false
    @State private var draftOnDeviceVoice = ""
    @State private var draftBridgeWSURL = ""
    @State private var draftShowToken = false

    @State private var onDeviceVoices: [OnDeviceTTS.VoiceOption] = []
    @State private var bridgeVoices: [Voice] = []
    @State private var bridgeVoicesLoading = false
    @State private var bridgeVoicesError: String?
    // Tek uçuşta tek istek: yenisi başlarken öncekini iptal eder (URL yazarken
    // her tuş vuruşu ayrı istek başlatıp picker'ı titretiyordu).
    @State private var voicesTask: Task<Void, Never>?

    private let api = APIClient()

    var body: some View {
        NavigationStack {
            Form {
                Section("Ses Motoru") {
                    Picker("Dil", selection: $draftLanguage) {
                        Text("Türkçe").tag("tr")
                        Text("İngilizce").tag("en-US")
                        Text("Almanca").tag("de-DE")
                        Text("Fransızca").tag("fr-FR")
                        Text("İspanyolca").tag("es-ES")
                    }
                    .pickerStyle(.menu)


                    Toggle("Cihaz TTS (AVSpeechSynthesizer)", isOn: $draftUseOnDeviceTTS)
                    if draftUseOnDeviceTTS {
                        Picker("Cihaz sesi", selection: $draftOnDeviceVoice) {
                            Text("Varsayılan (\(draftLanguage))").tag("")
                            ForEach(onDeviceVoices) { v in
                                Text(v.displayName).tag(v.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Text("Açıkken ses sentezi cihazda yapılır; kapalıyken bridge kullanılır, erişilemezse cihaza düşülür.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Realtime Bridge (WebSocket TTS)") {
                    TextField("wss://mate.drascom.uk/ws", text: $draftBridgeWSURL)
                        .technicalField()
                        .urlKeyboard()
                        .onChange(of: draftBridgeWSURL) { _ in
                            scheduleVoicesReload(debounceMs: 600)
                        }

                    bridgeVoicePickerRow

                    if let err = bridgeVoicesError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }

                    HStack {
                        Text("Token")
                            .foregroundStyle(.secondary)
                        Group {
                            if draftShowToken {
                                TextField("token", text: $draftBridgeKey)
                            } else {
                                SecureField("token", text: $draftBridgeKey)
                            }
                        }
                        .technicalField()
                        .multilineTextAlignment(.trailing)
                        Button {
                            draftShowToken.toggle()
                        } label: {
                            Image(systemName: draftShowToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Tanınan metin bridge'e gönderilir, dönen ses gerçek zamanlı çalınır (token boş bırakılabilir).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Kişi Tanıma (Voice-ID)") {
                    NavigationLink {
                        EnrollmentView()
                    } label: {
                        Label("Konuşmacılar", systemImage: "person.wave.2.fill")
                    }
                    Text("Ev halkını sesinden tanır; her kişiyi bir kez kaydedin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Wake Word") {
                    Toggle("Wake word kullan", isOn: $draftWakeEnabled)
                    TextField("Tetikleyici kelime (örn: candan)", text: $draftWakeWord)
                        .technicalField()
                        .disabled(!draftWakeEnabled)
                    Text("Açıkken \"\(draftWakeWord.isEmpty ? "—" : draftWakeWord)\" duyulana kadar bekler; kapalıyken sürekli dinler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Geçiş Sesleri") {
                    Toggle("Bip sesleri", isOn: $draftCuesEnabled)
                    Text("Wake, konuşma sonu ve uyku geçişlerinde kısa yumuşak tonlar çalar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Gürültü Filtresi") {
                    Toggle("Adaptif gürültü filtresi", isOn: $draftNoiseFilter)
                    Text("Açıkken ortam sesine göre eşiği uyarlar; kapalıyken sabit eşik kullanır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sözünü Kes (Barge-in)") {
                    Toggle("Konuşurken müdahaleye izin ver", isOn: $draftBargeIn)
                    Text("Açıkken konuşmaya başladığında ajan susup sana döner; kapalıyken sözünü bitirir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .groupedFormCompat()
            .navigationTitle("Ayarlar")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                draftVoice = settings.voice
                draftLanguage = settings.language
                draftBridgeKey = settings.bridgeApiKey
                draftWakeEnabled = settings.wakeWordEnabled
                draftWakeWord = settings.wakeWord
                draftCuesEnabled = settings.cuesEnabled
                draftNoiseFilter = settings.noiseFilterEnabled
                draftBargeIn = settings.bargeInEnabled
                draftUseOnDeviceTTS = settings.useOnDeviceTTS
                draftOnDeviceVoice = settings.onDeviceVoiceId
                draftBridgeWSURL = settings.bridgeWSURL
                reloadOnDeviceVoices(language: settings.language)
                // Bridge ses listesi draftBridgeWSURL'in onChange'i üzerinden
                // yüklenir (yukarıdaki atama tetikler) — burada ikinci bir
                // istek başlatma: eskiden çift istek picker'ı titretiyordu.
            }
            .onChange(of: draftLanguage) { newLang in
                reloadOnDeviceVoices(language: newLang)
            }
            .onDisappear {
                voicesTask?.cancel()
            }
        }
        .settingsSheetFrame()
    }

    /// Picker yükleme sırasında HİYERARŞİDEN ÇIKARILMAZ (eskiden spinner ile yer
    /// değiştiriyordu → menü açıkken reload gelince takılma/donma). Spinner,
    /// yenile butonunun yerinde döner; picker hep tıklanabilir kalır.
    @ViewBuilder
    private var bridgeVoicePickerRow: some View {
        HStack {
            Picker("Ses", selection: $draftVoice) {
                if !draftVoice.isEmpty &&
                    !bridgeVoices.contains(where: { $0.filename == draftVoice }) {
                    Text("\(draftVoice) (kayıtlı)").tag(draftVoice)
                }
                ForEach(bridgeVoices) { v in
                    Text(v.displayName).tag(v.filename)
                }
                if bridgeVoices.isEmpty && draftVoice.isEmpty {
                    Text("—").tag("")
                }
            }
            .pickerStyle(.menu)
            if bridgeVoicesLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    scheduleVoicesReload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// Sistem ses kataloğu taraması (speechVoices) ilk çağrıda yavaş olabiliyor
    /// → arka planda taranır (OnDeviceTTS içinde GCD), sonuç MainActor'da
    /// yazılır (açılışta ve dil değişiminde sayfa donmasın).
    private func reloadOnDeviceVoices(language: String) {
        Task {
            let voices = await OnDeviceTTS.availableVoices(language: language)
            await MainActor.run { onDeviceVoices = voices }
        }
    }

    /// `ws://host:port/ws` gibi bir WebSocket URL'inden HTTP base türetir:
    /// şema ws→http / wss→https'e çevrilir, path ve query atılır.
    /// Örn: `ws://192.168.0.150:8808/ws` → `http://192.168.0.150:8808`
    private func httpBase(fromWS wsURL: String) -> String? {
        let trimmed = wsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty
        else { return nil }

        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "http"
        case "wss", "https": components.scheme = "https"
        case .none: components.scheme = "http"
        default: components.scheme = "http"
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    /// Tek aktif yükleme: öncekini iptal eder; debounce ile URL yazımı bitene
    /// kadar bekler. İptal edilen isteğin sonucu state'e YAZILMAZ (geç gelen
    /// eski cevap güncel listeyi ezmesin).
    private func scheduleVoicesReload(debounceMs: UInt64 = 0) {
        voicesTask?.cancel()
        voicesTask = Task {
            if debounceMs > 0 {
                try? await Task.sleep(nanoseconds: debounceMs * 1_000_000)
            }
            guard !Task.isCancelled else { return }
            await loadBridgeVoices()
        }
    }

    private func loadBridgeVoices() async {
        guard let base = httpBase(fromWS: draftBridgeWSURL) else {
            bridgeVoices = []
            bridgeVoicesError = "Geçersiz bridge WS URL'i"
            bridgeVoicesLoading = false
            return
        }
        bridgeVoicesLoading = true
        bridgeVoicesError = nil
        do {
            let fetched = try await api.fetchVoices(
                baseURL: base,
                apiKey: draftBridgeKey
            )
            guard !Task.isCancelled else { return }
            // Aynı içerikle yeniden atama yapma: açık picker menüsü her atamada
            // yeniden kuruluyor (UIContextMenuInteraction uyarısı + takılma).
            if fetched != bridgeVoices {
                bridgeVoices = fetched
            }
        } catch is CancellationError {
            return
        } catch let e as URLError where e.code == .cancelled {
            return
        } catch {
            guard !Task.isCancelled else { return }
            bridgeVoices = []
            bridgeVoicesError = "Sesler alınamadı: \(error.localizedDescription)"
        }
        bridgeVoicesLoading = false
    }

    private func save() {
        settings.voice = draftVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.language = draftLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bridgeApiKey = draftBridgeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.wakeWordEnabled = draftWakeEnabled
        settings.wakeWord = draftWakeWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        settings.cuesEnabled = draftCuesEnabled
        settings.noiseFilterEnabled = draftNoiseFilter
        settings.bargeInEnabled = draftBargeIn
        settings.useOnDeviceTTS = draftUseOnDeviceTTS
        settings.onDeviceVoiceId = draftOnDeviceVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.bridgeWSURL = draftBridgeWSURL.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsStore())
}
