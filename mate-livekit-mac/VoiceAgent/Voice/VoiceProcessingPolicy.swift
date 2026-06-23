#if os(macOS)
    import CoreAudio
    import Foundation
    import LiveKit

    /// Koşullu VPIO (donanım AEC) politikası.
    ///
    /// VPIO, mic girişi + hoparlör çıkışını birleştiren bir CoreAudio **aggregate
    /// device** kurar. Bu **dahili (built-in)** mic+hoparlörde ve **Bluetooth**
    /// (ör. XM4 — çift-yönlü HFP) cihazlarda sorunsuz çalışır; ama tek-yönlü bir
    /// **USB** kulaklıkta aggregate kurulamaz → `StartIO error 35` → mic hiç
    /// başlamaz, wake duyulmaz.
    ///
    /// Kanıt: dahili VE XM4 ile VPIO-açık test edildi, ikisi de geçti; `error 35`
    /// yalnız USB tek-yönlü kulaklıkta görüldü. Asimetri: VPIO'yu uyumsuz cihazda
    /// AÇMAK sert kırılma (mic ölür); KAPATMAK yumuşak (yalnız yazılım AEC yok).
    /// Bu yüzden VPIO'yu **bilinen-iyi transport'larda (dahili + Bluetooth) AÇIK**
    /// tutuyoruz, **USB ve bilinmeyen transport'larda KAPATIYORUZ** (sunucu
    /// half-duplex + varsa cihazın kendi AEC'sine düşeriz).
    enum VoiceProcessingPolicy {
        /// Başlangıçta (motor başlamadan ÖNCE) mevcut giriş cihazına göre VPIO'yu
        /// ayarlar. `VoiceAgentApp.init()` içinden, bağlanmadan önce çağrılır.
        static func applyForCurrentInputDevice() {
            let device = AudioManager.shared.inputDevice
            set(enabled: AudioTransport.shouldEnableVoiceProcessing(deviceId: device.deviceId, name: device.name),
                deviceName: device.name)
        }

        /// Bir giriş cihazına geçerken VPIO'yu güvenli SIRAYLA ayarlar.
        ///
        /// VPIO'yu **etkin bir uyumsuz cihaz üzerinde açmak** `error 35` üretir; o yüzden:
        /// - Hedef VPIO-uyumlu ise: önce cihaza geç, SONRA VPIO'yu aç (uyumlu üstünde güvenli).
        /// - Hedef uyumsuz ise: önce VPIO'yu kapat (kapatma asla aggregate kurmaz),
        ///   SONRA cihaza geç (VPIO zaten kapalı → aggregate denenmez → error 35 yok).
        ///
        /// `select` kapanışı asıl cihaz değişimini yapar (`LocalMedia.select(audioDevice:)`).
        static func selectInputDevice(_ device: AudioDevice, via select: (AudioDevice) -> Void) {
            let supported = AudioTransport.shouldEnableVoiceProcessing(deviceId: device.deviceId, name: device.name)
            if supported {
                select(device)
                set(enabled: true, deviceName: device.name)
            } else {
                set(enabled: false, deviceName: device.name)
                select(device)
            }
        }

        /// VPIO'yu istenen duruma getirir (idempotent — gereksiz motor yeniden
        /// başlatmasından kaçınmak için yalnız fark varsa değiştirir).
        private static func set(enabled: Bool, deviceName: String) {
            guard AudioManager.shared.isVoiceProcessingEnabled != enabled else {
                Log.line("[Audio] VPIO zaten \(enabled ? "AÇIK" : "KAPALI") — '\(deviceName)' (değişiklik yok)")
                return
            }
            do {
                try AudioManager.shared.setVoiceProcessingEnabled(enabled)
                Log.line("[Audio] VPIO \(enabled ? "AÇILDI" : "KAPATILDI") — '\(deviceName)' (builtIn=\(enabled))")
            } catch {
                Log.error("[Audio] VPIO set(\(enabled)) BAŞARISIZ — '\(deviceName)': \(error.localizedDescription)")
            }
        }
    }

    /// CoreAudio donanım transport tespiti (built-in / USB / Bluetooth …).
    enum AudioTransport {
        /// Bu cihazda VPIO açık olsun mu? **Varsayılan AÇIK**; yalnız POZİTİF olarak
        /// **USB** tespit edersek KAPAT (USB tek-yönlü cihazda VPIO aggregate
        /// kurulamıyor → `error 35`). Built-in/Bluetooth VE bilinmeyen/`nil` →
        /// AÇIK: VPIO'yu kapatmak echo iptalini, overload önlemeyi ve tam cihaz
        /// listesini bozuyordu; bunlar çalışan davranışın parçasıydı. Asimetri:
        /// USB'de yanlış-AÇIK = mic ölür (sert); başka yerde yanlış-KAPALI = echo
        /// (kötü). O yüzden yalnız kesin USB'de kapatıyoruz.
        static func shouldEnableVoiceProcessing(deviceId: String, name: String) -> Bool {
            transportType(deviceId: deviceId, name: name) != kAudioDeviceTransportTypeUSB
        }

        /// Cihazın CoreAudio transport tipini (`kAudioDeviceTransportType*`) döndürür.
        ///
        /// LiveKit `deviceId` çoğu zaman gerçek bir CoreAudio UID DEĞİL — sistem
        /// varsayılanı için literal `"default"` (ve isim bazen boş) döner. Bu durumda
        /// CoreAudio **sistem varsayılan giriş cihazını** çözüp onun transport'unu
        /// kullanırız. Aksi halde UID veya isimle eşleştiririz. Bulunamazsa `nil`.
        static func transportType(deviceId: String, name: String) -> UInt32? {
            if deviceId == "default" || deviceId.isEmpty || name.isEmpty {
                return defaultInputDeviceID().flatMap {
                    uint32Property($0, kAudioDevicePropertyTransportType)
                }
            }
            for device in allDeviceIDs() {
                let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
                let devName = stringProperty(device, kAudioObjectPropertyName)
                if uid == deviceId || (devName != nil && devName == name) {
                    return uint32Property(device, kAudioDevicePropertyTransportType)
                }
            }
            return nil
        }

        /// CoreAudio sistem varsayılan giriş cihazının ID'si.
        private static func defaultInputDeviceID() -> AudioDeviceID? {
            defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
        }

        private static func defaultDeviceID(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
            guard status == noErr, deviceID != 0 else { return nil }
            return deviceID
        }

        // MARK: - Çıkış (hoparlör) seçimi

        /// Çıkış cihazını **CoreAudio sistem varsayılanı** olarak ayarlar (System
        /// Settings'in yaptığının aynısı). Doğrudan `AudioManager.outputDevice =`
        /// swap'ı VPIO downlink DSP'sini canlı bozup çökertiyor (`render err -10874`);
        /// sistem-varsayılan yolu ise VPIO'nun nazikçe yeniden kurulmasını tetikler.
        @discardableResult
        static func setSystemDefaultOutput(deviceId: String, name: String) -> Bool {
            guard let id = resolveDeviceID(deviceId: deviceId, name: name, scope: kAudioObjectPropertyScopeOutput) else {
                return false
            }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devID = id
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &devID)
            return status == noErr
        }

        /// Sistem varsayılan çıkış cihazının adı (checkmark için).
        static func defaultOutputDeviceName() -> String? {
            defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
                .flatMap { stringProperty($0, kAudioObjectPropertyName) }
        }

        /// LiveKit `deviceId` (UID) veya isimle eşleşen CoreAudio cihaz ID'si.
        /// İsimle eşleşirken, yanlış yöndeki cihazı (ör. aynı isimli mic) seçmemek
        /// için verilen `scope`'ta (giriş/çıkış) stream'i olanı şart koşar.
        private static func resolveDeviceID(deviceId: String, name: String,
                                            scope: AudioObjectPropertyScope) -> AudioDeviceID? {
            for device in allDeviceIDs() {
                if stringProperty(device, kAudioDevicePropertyDeviceUID) == deviceId {
                    return device
                }
            }
            for device in allDeviceIDs() where hasStreams(device, scope: scope) {
                if stringProperty(device, kAudioObjectPropertyName) == name {
                    return device
                }
            }
            return nil
        }

        private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else { return false }
            return dataSize > 0
        }

        // MARK: - Tanılama

        /// CoreAudio'nun gördüğü TÜM giriş-yetenekli cihazları "isim[transport]"
        /// olarak döndürür (LiveKit'in filtrelediği listeyle karşılaştırmak için).
        static func inputDevicesDiagnostics() -> String {
            let items = allDeviceIDs().compactMap { id -> String? in
                guard hasStreams(id, scope: kAudioObjectPropertyScopeInput) else { return nil }
                let name = stringProperty(id, kAudioObjectPropertyName) ?? "?"
                return "\(name)[\(transportName(uint32Property(id, kAudioDevicePropertyTransportType)))]"
            }
            return items.isEmpty ? "(yok)" : items.joined(separator: ", ")
        }

        static func transportName(_ t: UInt32?) -> String {
            switch t {
            case kAudioDeviceTransportTypeBuiltIn?: return "builtin"
            case kAudioDeviceTransportTypeBluetooth?: return "bt"
            case kAudioDeviceTransportTypeBluetoothLE?: return "btle"
            case kAudioDeviceTransportTypeUSB?: return "usb"
            case kAudioDeviceTransportTypeAggregate?: return "aggregate"
            case kAudioDeviceTransportTypeVirtual?: return "virtual"
            case .none: return "yok"
            default: return "diğer"
            }
        }

        // MARK: - CoreAudio plumbing

        private static func allDeviceIDs() -> [AudioDeviceID] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var dataSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
                dataSize > 0
            else { return [] }
            let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
            var ids = [AudioDeviceID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr
            else { return [] }
            return ids
        }

        private static func stringProperty(_ device: AudioDeviceID,
                                           _ selector: AudioObjectPropertySelector) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var ref: Unmanaged<CFString>?
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ref)
            guard status == noErr, let ref else { return nil }
            return ref.takeRetainedValue() as String
        }

        private static func uint32Property(_ device: AudioDeviceID,
                                           _ selector: AudioObjectPropertySelector) -> UInt32? {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            guard status == noErr else { return nil }
            return value
        }
    }
#endif
