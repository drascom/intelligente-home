import LiveKit
import SwiftUI

/// Sunucunun (agent) canlı durum satırını dinler — `mate.debug` text-stream
/// topic'i (turn detection/EOU, agent state, stt partial/final, tts baş/bit…).
/// Gelen SON satırı tutar; AppView en altta soluk monospace bir şeritte gösterir.
///
/// Ayrı topic — `lk.transcription` (MateTranscriptionReceiver) ve `mate.cue`
/// ile çakışmaz. Best-effort: hata olursa sessiz yutulur.
@MainActor
final class DebugStatusMonitor: ObservableObject {
    @Published private(set) var lastLine = ""

    private static let topic = "mate.debug"
    private var registered = false

    func connectionChanged(_ connected: Bool, room: Room) {
        if connected { register(room) } else { unregister(room) }
    }

    private func register(_ room: Room) {
        guard !registered else { return }
        registered = true
        Task {
            try? await room.registerTextStreamHandler(for: Self.topic) { [weak self] reader, _ in
                Task { @MainActor [weak self] in
                    let value = (try? await reader.readAll()) ?? ""
                    let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { self?.lastLine = line }
                }
            }
        }
    }

    private func unregister(_ room: Room) {
        guard registered else { return }
        registered = false
        Task { await room.unregisterTextStreamHandler(for: Self.topic) }
    }
}
