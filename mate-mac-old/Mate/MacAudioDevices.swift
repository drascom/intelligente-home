#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio

/// macOS ses cihazı seçimi. iOS'taki AVAudioSession route yönetiminin karşılığı:
/// Core Audio'dan giriş/çıkış cihazlarını listeler ve seçimi SİSTEM VARSAYILANI
/// olarak uygular (AVAudioEngine'ler varsayılanı takip eder — VP modunda unit'e
/// tek tek cihaz atamak kırılgan, varsayılan değişimi her engine'de çalışır).
/// Seçim UserDefaults'ta UID ile saklanır; "" = sisteme dokunma.
struct MacAudioDevice: Identifiable, Hashable {
    let id: String          // kAudioDevicePropertyDeviceUID (kalıcı)
    let deviceID: AudioDeviceID
    let name: String
}

/// Tek seçimle hem mic hem hoparlör sağlayan mantıksal ses cihazı. VPIO (AEC)
/// giriş+çıkışın EŞLEŞMİŞ cihaz olmasını ister; tek cihaz seçimi bunu garanti
/// eder. Dahili mic+hoparlör CoreAudio'da iki AYRI aygıttır → "MacBook" altında
/// tek girdide birleştirilir. `id` = inputUID (pair'i benzersiz tanımlar).
struct MacAudioPair: Identifiable, Hashable {
    let id: String
    let name: String
    let inputUID: String
    let outputUID: String
}

enum MacAudioDevices {
    static let inputUIDKey = "macInputDeviceUID"
    static let outputUIDKey = "macOutputDeviceUID"

    static func inputDevices() -> [MacAudioDevice] {
        allDevices().filter { hasStreams($0.deviceID, scope: kAudioObjectPropertyScopeInput) }
    }

    static func outputDevices() -> [MacAudioDevice] {
        allDevices().filter { hasStreams($0.deviceID, scope: kAudioObjectPropertyScopeOutput) }
    }

    /// Kayıtlı tercihleri sistem varsayılanına uygula (oturum başında ve
    /// dropdown değişiminde çağrılır). Cihaz artık takılı değilse sessizce geç.
    static func applyStoredSelection() {
        let defaults = UserDefaults.standard
        if let uid = defaults.string(forKey: inputUIDKey), !uid.isEmpty,
           let device = inputDevices().first(where: { $0.id == uid }) {
            setSystemDefault(device.deviceID, selector: kAudioHardwarePropertyDefaultInputDevice, label: "mic")
        }
        if let uid = defaults.string(forKey: outputUIDKey), !uid.isEmpty,
           let device = outputDevices().first(where: { $0.id == uid }) {
            setSystemDefault(device.deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "speaker")
        }
    }

    /// Tek-cihaz seçim listesi: her girdi hem mic hem hoparlör verir (AEC için
    /// eşleşmiş). Dahili mic+hoparlör → "MacBook (dahili)"; USB headset / aggregate
    /// gibi tek aygıtta iki yönlü cihazlar → kendi adlarıyla. Sadece giriş VEYA
    /// sadece çıkış yapan aygıtlar listelenmez (eşleşmiş AEC veremezler).
    static func audioPairs() -> [MacAudioPair] {
        let ins = inputDevices()
        let outs = outputDevices()
        var pairs: [MacAudioPair] = []
        var usedInputUIDs = Set<String>()

        // 1. Dahili mic + dahili hoparlör → tek "MacBook" girdisi (isimleri farklı).
        if let bi = ins.first(where: { transportType($0.deviceID) == kAudioDeviceTransportTypeBuiltIn }),
           let bo = outs.first(where: { transportType($0.deviceID) == kAudioDeviceTransportTypeBuiltIn }) {
            pairs.append(MacAudioPair(id: bi.id, name: "MacBook (dahili)", inputUID: bi.id, outputUID: bo.id))
            usedInputUIDs.insert(bi.id)
        }

        // 2. AYNI ADA sahip giriş+çıkış aygıtlarını eşle. USB headset genelde
        //    girişini ve çıkışını AYRI CoreAudio aygıtı olarak sunar (aynı isim,
        //    farklı UID). Tek aygıtta iki yön varsa kendisiyle eşleşir.
        for inDev in ins {
            if usedInputUIDs.contains(inDev.id) { continue }
            guard let outDev = outs.first(where: { $0.name == inDev.name }) else { continue }
            pairs.append(MacAudioPair(id: inDev.id, name: inDev.name, inputUID: inDev.id, outputUID: outDev.id))
            usedInputUIDs.insert(inDev.id)
        }
        return pairs
    }

    /// Saklı seçime (inputUID) karşılık gelen pair; yoksa ilk pair (dahili "MacBook").
    static func currentOrDefaultPair() -> MacAudioPair? {
        let pairs = audioPairs()
        let storedIn = UserDefaults.standard.string(forKey: inputUIDKey) ?? ""
        return pairs.first { $0.id == storedIn } ?? pairs.first
    }

    /// Dahili (built-in) giriş cihazı — MacBook mic. Transport == built-in.
    static func builtInInputDeviceID() -> AudioDeviceID? {
        inputDevices().first { transportType($0.deviceID) == kAudioDeviceTransportTypeBuiltIn }?.deviceID
    }

    /// Dahili (built-in) çıkış cihazı — MacBook hoparlör.
    static func builtInOutputDeviceID() -> AudioDeviceID? {
        outputDevices().first { transportType($0.deviceID) == kAudioDeviceTransportTypeBuiltIn }?.deviceID
    }

    /// AEC (VPIO) için: sistem giriş/çıkış varsayılanını dahili mic+hoparlöre
    /// zorla. macOS VPIO çapraz/eşleşmemiş cihazda -10875 ile patlar; dahili
    /// mic→dahili hoparlör bilinen-çalışan eşleşmedir. Önceki cihaz ID'lerini
    /// döndürür (istenirse `restoreDefaults` ile geri yüklenebilir).
    @discardableResult
    static func forceBuiltInDefaults() -> (input: AudioDeviceID?, output: AudioDeviceID?)? {
        guard let inDev = builtInInputDeviceID(), let outDev = builtInOutputDeviceID() else {
            Log.line("[MacAudio] built-in cihaz bulunamadı — AEC route zorlanamadı")
            return nil
        }
        let prevIn = currentDefault(kAudioHardwarePropertyDefaultInputDevice)
        let prevOut = currentDefault(kAudioHardwarePropertyDefaultOutputDevice)
        if prevIn != inDev {
            setSystemDefault(inDev, selector: kAudioHardwarePropertyDefaultInputDevice, label: "mic(AEC)")
        }
        if prevOut != outDev {
            setSystemDefault(outDev, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "speaker(AEC)")
        }
        return (prevIn, prevOut)
    }

    /// `forceBuiltInDefaults`'un döndürdüğü önceki cihazları geri yükle
    /// (örn. asistan idle'a dönerken kullanıcının kulaklığını iade etmek için).
    static func restoreDefaults(_ prev: (input: AudioDeviceID?, output: AudioDeviceID?)?) {
        guard let prev else { return }
        if let inDev = prev.input {
            setSystemDefault(inDev, selector: kAudioHardwarePropertyDefaultInputDevice, label: "mic(restore)")
        }
        if let outDev = prev.output {
            setSystemDefault(outDev, selector: kAudioHardwarePropertyDefaultOutputDevice, label: "speaker(restore)")
        }
    }

    // MARK: - Core Audio plumbing

    private static func currentDefault(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev
        ) == noErr else { return nil }
        return dev
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private static func allDevices() -> [MacAudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard let name = stringProperty(id, selector: kAudioObjectPropertyName),
                  let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
            else { return nil }
            // Gizli/özel sistem aygıtlarını ele: VPIO açılınca coreaudiod'un
            // ürettiği "CADefaultDeviceAggregate-…" gibi efemeral private aggregate'ler
            // kullanıcıya gösterilmemeli (system_profiler de gizler).
            if isHidden(id) || uid.hasPrefix("CADefaultDeviceAggregate")
                || name.hasPrefix("CADefaultDeviceAggregate") {
                return nil
            }
            return MacAudioDevice(id: uid, deviceID: id, name: name)
        }
    }

    /// `kAudioDevicePropertyIsHidden` — özel/sistem aygıtları true döner.
    private static func isHidden(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden) == noErr else {
            return false
        }
        return hidden != 0
    }

    private static func hasStreams(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    private static func stringProperty(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func setSystemDefault(_ device: AudioDeviceID, selector: AudioObjectPropertySelector, label: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dev = device
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &dev
        )
        Log.line("[MacAudio] default \(label) → device \(device) (\(status == noErr ? "ok" : "err \(status)"))")
    }
}
#endif
