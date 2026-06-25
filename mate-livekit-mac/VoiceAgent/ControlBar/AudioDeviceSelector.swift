import LiveKit
import SwiftUI

#if os(macOS)
    /// A platform-specific view that shows a list of available audio devices.
    struct AudioDeviceSelector: View {
        @EnvironmentObject private var localMedia: LocalMedia

        // Cihaz listesini SDK'nın `localMedia.audioDevices`'ından OKUMUYORUZ: o liste
        // LocalMedia kurulurken (ses motoru/ADM tam başlamadan ÖNCE) bir kez okunup
        // donuyor → o anda yalnız aktif/varsayılan cihaz (örn. headset) dönüyor; sonra
        // sadece donanım tak/çıkarda (onDeviceUpdate) yenileniyor, motor başlayınca DEĞİL
        // → menüde tek cihaz takılı kalıyor. Bunun yerine `AudioManager.shared.inputDevices`'ı
        // menü her açıldığında CANLI okuyoruz (Menu içerik closure'ı açılışta yeniden
        // değerlenir) → o an HAL'in bildirdiği tüm giriş cihazları görünür.
        // Aynı kulaklık bazen iki kez geliyor (örn. USB cihazın iki profili / varsayılan
        // takma-kaydı → aynı AD, farklı deviceId). İsme göre dedupe ediyoruz; aynı addan
        // birden çoksa o an SEÇİLİ olanı, yoksa varsayılanı, o da yoksa ilkini tutuyoruz
        // ki checkmark/seçim doğru cihaza otursun.
        private var inputDevices: [AudioDevice] {
            let raw = AudioManager.shared.inputDevices
            let selectedID = localMedia.selectedAudioDeviceID
            var byName: [String: AudioDevice] = [:]
            var order: [String] = []
            for device in raw {
                let key = device.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let existing = byName[key] {
                    // Çakışma: seçili > varsayılan > mevcut önceliğiyle değiştir.
                    if device.deviceId == selectedID || (device.isDefault && existing.deviceId != selectedID) {
                        byName[key] = device
                    }
                } else {
                    byName[key] = device
                    order.append(key)
                }
            }
            return order.compactMap { byName[$0] }
        }

        var body: some View {
            Menu {
                ForEach(inputDevices, id: \.deviceId) { device in
                    Button {
                        localMedia.select(audioDevice: device)
                    } label: {
                        HStack {
                            Text(device.name)
                            if device.deviceId == localMedia.selectedAudioDeviceID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(height: 11 * .grid)
                    .font(.system(size: 12, weight: .semibold))
                    .contentShape(Rectangle())
            }
        }
    }
#endif
