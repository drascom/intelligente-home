import LiveKit
import SwiftUI

#if os(macOS)
    /// A platform-specific view that shows a list of available audio input
    /// (microphone) and output (speaker) devices.
    struct AudioDeviceSelector: View {
        @EnvironmentObject private var localMedia: LocalMedia

        // MARK: - Mikrofon (giriş)

        /// Dedup'lanmış giriş cihazları (bkz. `deduped`).
        private var uniqueInputDevices: [AudioDevice] {
            deduped(localMedia.audioDevices)
        }

        /// Seçili giriş cihazının adı (seçili id dedup'ta elenmiş bir kopya
        /// olabileceğinden görünen satırları isimle eşleştiriyoruz).
        private var selectedInputName: String? {
            localMedia.audioDevices.first { $0.deviceId == localMedia.selectedAudioDeviceID }?.name
        }

        // MARK: - Hoparlör (çıkış)

        /// Dedup'lanmış çıkış cihazları. LiveKit `LocalMedia` çıkışı @Published
        /// tutmadığından doğrudan AudioManager'dan okuyoruz; menü her açılışta
        /// yeniden değerlendiği için güncel kalır.
        private var uniqueOutputDevices: [AudioDevice] {
            deduped(AudioManager.shared.outputDevices)
        }

        /// Seçili çıkış cihazının adı (CoreAudio sistem varsayılan çıkışından).
        private var selectedOutputName: String? {
            AudioTransport.defaultOutputDeviceName()
        }

        // MARK: - Body

        var body: some View {
            Menu {
                Section("Mikrofon") {
                    ForEach(uniqueInputDevices, id: \.deviceId) { device in
                        Button {
                            // VPIO'yu hedef cihaza göre güvenli sırayla aç/kapat,
                            // ardından cihazı seç (bkz. VoiceProcessingPolicy).
                            VoiceProcessingPolicy.selectInputDevice(device) {
                                localMedia.select(audioDevice: $0)
                            }
                        } label: {
                            deviceLabel(device.name, selected: device.name == selectedInputName)
                        }
                    }
                }

                Section("Hoparlör") {
                    ForEach(uniqueOutputDevices, id: \.deviceId) { device in
                        Button {
                            selectOutput(device)
                        } label: {
                            deviceLabel(device.name, selected: device.name == selectedOutputName)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(height: 11 * .grid)
                    .font(.system(size: 12, weight: .semibold))
                    .contentShape(Rectangle())
            }
            .onAppear { logDevices() }
            .onChange(of: localMedia.audioDevices.map(\.deviceId)) { _, _ in logDevices() }
        }

        @ViewBuilder
        private func deviceLabel(_ name: String, selected: Bool) -> some View {
            HStack {
                Text(name)
                if selected {
                    Image(systemName: "checkmark")
                }
            }
        }

        // MARK: - Seçim

        private func selectOutput(_ device: AudioDevice) {
            // Doğrudan AudioManager.outputDevice swap'ı VPIO downlink'i çökertiyor;
            // bunun yerine CoreAudio sistem varsayılan çıkışını set ediyoruz (VPIO
            // nazikçe yeniden kurulur). Bkz. VoiceProcessingPolicy.setSystemDefaultOutput.
            let ok = AudioTransport.setSystemDefaultOutput(deviceId: device.deviceId, name: device.name)
            Log.line("[Audio] Hoparlör → sistem varsayılanı: '\(device.name)' (\(ok ? "OK" : "BAŞARISIZ"))")
        }

        // MARK: - Yardımcılar

        /// CoreAudio aynı kulaklığı her Bluetooth profili/endpoint'i için bir kez
        /// (+ sistem varsayılanını izleyen `"default"` alias'ı için bir kez daha)
        /// listeler. İsim başına tek satıra indirir; aynı isimde `"default"` yerine
        /// gerçek deviceId'yi tercih eder ki seçim cihazı gerçekten pinlesin.
        private func deduped(_ devices: [AudioDevice]) -> [AudioDevice] {
            var byName: [String: AudioDevice] = [:]
            var order: [String] = []
            for device in devices {
                if let existing = byName[device.name] {
                    if existing.deviceId == "default", device.deviceId != "default" {
                        byName[device.name] = device
                    }
                } else {
                    byName[device.name] = device
                    order.append(device.name)
                }
            }
            return order.compactMap { byName[$0] }
        }

        /// TANI: LiveKit'in raporladığı giriş/çıkış cihazlarını, VPIO durumunu ve
        /// CoreAudio'nun gördüğü ham girişleri log'a basar.
        private func logDevices() {
            let inputs = localMedia.audioDevices
                .map { "\($0.name)#\($0.deviceId.prefix(8))" }
                .joined(separator: ", ")
            let outputs = AudioManager.shared.outputDevices
                .map { "\($0.name)#\($0.deviceId.prefix(8))" }
                .joined(separator: ", ")
            Log.line("[Audio] VPIO=\(AudioManager.shared.isVoiceProcessingEnabled ? "AÇIK" : "KAPALI") · inputDevices(\(localMedia.audioDevices.count)): \(inputs)")
            Log.line("[Audio] outputDevices(\(AudioManager.shared.outputDevices.count)): \(outputs)")
            Log.line("[Audio] CoreAudio inputs: \(AudioTransport.inputDevicesDiagnostics())")
        }
    }
#endif
