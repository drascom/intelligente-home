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

    // MARK: - Core Audio plumbing

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
            return MacAudioDevice(id: uid, deviceID: id, name: name)
        }
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
        print("[MacAudio] default \(label) → device \(device) (\(status == noErr ? "ok" : "err \(status)"))")
    }
}
#endif
