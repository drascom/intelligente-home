#if os(macOS)
    import CoreAudio
    import Foundation

    /// Thin CoreAudio wrapper to read/set the macOS **system default** input/output
    /// devices by name.
    ///
    /// Why: with Apple Voice-Processing I/O enabled (the LiveKit SDK default — it
    /// gives us echo cancellation and is stable on macOS 26), WebRTC playout/capture
    /// is bound to the system *default* communication device and ignores a manual
    /// `AudioManager.outputDevice`. So to honor the user's speaker/mic choice we
    /// change the system default device here; voice processing then follows it.
    /// Matching is by name (consistent with how ``AudioDeviceStore`` persists), with
    /// graceful failure → the system keeps its current default.
    enum SystemAudioDevice {
        @discardableResult
        static func setDefaultOutput(named name: String) -> Bool {
            set(named: name, streamScope: kAudioObjectPropertyScopeOutput,
                selector: kAudioHardwarePropertyDefaultOutputDevice)
        }

        @discardableResult
        static func setDefaultInput(named name: String) -> Bool {
            set(named: name, streamScope: kAudioObjectPropertyScopeInput,
                selector: kAudioHardwarePropertyDefaultInputDevice)
        }

        // MARK: - Private

        private static func set(named name: String,
                                streamScope: AudioObjectPropertyScope,
                                selector: AudioObjectPropertySelector) -> Bool {
            guard let id = deviceID(named: name, streamScope: streamScope) else { return false }
            var dev = id
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &dev
            )
            return status == noErr
        }

        /// First device with the given name that has streams in `streamScope`
        /// (i.e. is an input or output device respectively).
        private static func deviceID(named name: String,
                                     streamScope: AudioObjectPropertyScope) -> AudioDeviceID? {
            for id in allDeviceIDs() where hasStreams(id, scope: streamScope) {
                if deviceName(id)?.caseInsensitiveCompare(name) == .orderedSame {
                    return id
                }
            }
            return nil
        }

        private static func allDeviceIDs() -> [AudioDeviceID] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
            ) == noErr else { return [] }
            let count = Int(size) / MemoryLayout<AudioDeviceID>.size
            var ids = [AudioDeviceID](repeating: 0, count: count)
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
            ) == noErr else { return [] }
            return ids
        }

        private static func deviceName(_ id: AudioDeviceID) -> String? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &cfName) {
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
            }
            return status == noErr ? (cfName as String) : nil
        }

        private static func hasStreams(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
        }
    }
#endif
