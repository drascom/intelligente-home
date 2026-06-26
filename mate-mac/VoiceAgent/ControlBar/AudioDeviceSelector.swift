import LiveKit
import SwiftUI

#if os(macOS)
    /// A dropdown that lets the user pick a single audio **device** (microphone +
    /// speaker together) at runtime.
    ///
    /// Why one device, not separate mic/speaker: with Apple Voice-Processing I/O on
    /// (echo cancellation, and our only stable option on macOS 26), VPIO needs the
    /// mic and speaker to be the **same** physical device — different devices make
    /// its aggregate fault with an endless error flood. So we only offer devices
    /// that are both an input and an output (AirPods, headsets…). Built-in mic +
    /// built-in speakers is covered by "Sistem varsayılanı (otomatik)". Output-only
    /// devices (external monitor / BT speakers) can't work with VPIO and are not
    /// listed.
    ///
    /// Everything uses the SDK's native device APIs: lists come from
    /// `AudioManager.shared.inputDevices` / `outputDevices`, read live each time the
    /// menu opens. Switching goes through ``AudioDeviceStore``, which routes both
    /// macOS system defaults (and the WebRTC capture device) to the chosen device
    /// and remembers it; the audio engine restarts internally so the room stays
    /// connected — no manual reconnect.
    struct AudioDeviceSelector: View {
        @EnvironmentObject private var localMedia: LocalMedia
        @EnvironmentObject private var deviceStore: AudioDeviceStore

        var body: some View {
            Menu {
                // Read devices live (this closure re-evaluates on every open) so the
                // menu reflects the current hardware, not a stale snapshot.
                let devices = combinedDevices()

                Section("Ses cihazı (mikrofon + hoparlör)") {
                    Button { deviceStore.resetDevice() } label: {
                        row("Sistem varsayılanı (otomatik)", selected: deviceStore.preferredDeviceName == nil)
                    }
                    ForEach(devices, id: \.self) { name in
                        Button {
                            deviceStore.selectDevice(name)
                        } label: {
                            row(name, selected: deviceStore.preferredDeviceName == name)
                        }
                    }
                }
            } label: {
                // Dropdown tetikleyici: cihaz adı yerine sade bir hoparlör ikonu
                // (ses çıkış cihazı seçimi). Soldaki mic-seviye göstergesinden ayrı.
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 17, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("Ses cihazı seç"))
        }

        /// Names present in BOTH the input and output device lists = devices that
        /// can serve as the single mic+speaker device VPIO requires. Matched
        /// case-insensitively, de-duped (CoreAudio lists a device several times),
        /// in input-list order; the original (cased) name is kept for display and
        /// for ``AudioDeviceStore`` to resolve/persist by.
        private func combinedDevices() -> [String] {
            let outputKeys = Set(AudioManager.shared.outputDevices.map(key))
            var seen = Set<String>()
            var result: [String] = []
            for device in AudioManager.shared.inputDevices {
                let k = key(device)
                guard outputKeys.contains(k), !seen.contains(k) else { continue }
                seen.insert(k)
                result.append(device.name)
            }
            return result
        }

        private func key(_ device: AudioDevice) -> String {
            device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        @ViewBuilder
        private func row(_ name: String, selected: Bool) -> some View {
            HStack {
                Text(name)
                if selected { Image(systemName: "checkmark") }
            }
        }
    }
#endif
