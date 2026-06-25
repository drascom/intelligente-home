import Combine
import LiveKit
import SwiftUI

/// Picks a single audio **device** (microphone + speaker together) and keeps the
/// app pinned to it, independently of the macOS system default.
///
/// Why one device for both — not independent mic/speaker: with Apple
/// Voice-Processing I/O on (the LiveKit SDK default, and our only working echo
/// canceller — turning it off floods the audio engine with `-10877` on macOS 26),
/// VPIO builds an aggregate over the capture + playout devices. On macOS 26 that
/// aggregate **faults** when the mic and speaker are different physical devices
/// (endless `AUVPAggregate Timeout waiting for streams` / downlink-DSP errors). So
/// a single communication device is the only stable choice; we route both macOS
/// system defaults (and the WebRTC capture device) to it so VPIO sees one device.
///
/// Identity is by **name** (stable across reconnect/reboot, unlike CoreAudio ids),
/// resolved fresh from the live device list, with graceful fallback to the system
/// default when the chosen device is absent. `nil` = follow the system default
/// (e.g. built-in mic + built-in speakers, which VPIO handles fine).
///
/// On iOS/visionOS the device lists are empty and the setters are no-ops, so this
/// store is harmlessly inert there.
@MainActor
final class AudioDeviceStore: ObservableObject {
    private let deviceKey = "audio.preferredDeviceName"

    /// Preferred communication device name. `nil` = follow the system default.
    @Published private(set) var preferredDeviceName: String?

    private weak var localMedia: LocalMedia?
    private var started = false

    init() {
        preferredDeviceName = UserDefaults.standard.string(forKey: deviceKey)
    }

    /// Begin enforcing the stored preference. Chains (does not replace) the
    /// device-update handler `LocalMedia` installs, so its published device lists
    /// keep refreshing while we re-pin the chosen device on top.
    func start(localMedia: LocalMedia) {
        self.localMedia = localMedia
        guard !started else {
            apply()
            return
        }
        started = true

        // Capture LocalMedia's existing handler as a local @Sendable value so we
        // can chain it (keeping its published device-list refresh) without
        // touching main-actor state from inside the @Sendable closure.
        let previous = AudioManager.shared.onDeviceUpdate
        AudioManager.shared.onDeviceUpdate = { [weak self] manager in
            previous?(manager)
            Task { @MainActor [weak self] in self?.apply() }
        }
        apply()
    }

    // MARK: - Selection (from the UI)

    func selectDevice(_ name: String) { setPreferred(name) }

    /// Stop pinning and follow the macOS system default again.
    func resetDevice() { setPreferred(nil) }

    private func setPreferred(_ name: String?) {
        preferredDeviceName = name
        let defaults = UserDefaults.standard
        if let name { defaults.set(name, forKey: deviceKey) }
        else { defaults.removeObject(forKey: deviceKey) }
        apply()
    }

    // MARK: - Enforcement

    func apply() {
        // WebRTC capture device (the published mic track): keep it on the chosen
        // device, or the live system default when there's no preference. The id
        // check avoids redundant engine restarts when nothing changed.
        let input = resolvedInput()
        if AudioManager.shared.inputDevice.deviceId != input.deviceId {
            localMedia?.select(audioDevice: input)
        }

        // Pin BOTH macOS system defaults to the one chosen device, so VPIO's
        // capture + playout live on a single device (no cross-device aggregate
        // fault). nil preference = leave the system defaults alone (follow OS).
        // If the named device is gone, the setters fail and the system keeps its
        // current default — acceptable fallback.
        #if os(macOS)
        guard let name = preferredDeviceName else { return }
        SystemAudioDevice.setDefaultInput(named: name)
        SystemAudioDevice.setDefaultOutput(named: name)
        #endif
    }

    /// The chosen device (by name) if currently present as an input, otherwise the
    /// system default sentinel — which tracks the live system default.
    private func resolvedInput() -> AudioDevice {
        if let name = preferredDeviceName,
           let device = AudioManager.shared.inputDevices.first(where: { $0.name == name }) {
            return device
        }
        return AudioManager.shared.defaultInputDevice
    }
}
