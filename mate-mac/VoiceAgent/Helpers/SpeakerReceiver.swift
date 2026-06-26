import LiveKit
import SwiftUI

/// O an tanınan/aktif konuşmacı bilgisi (brain `candan.speaker` topic'inden).
struct SpeakerInfo: Equatable {
    let name: String?
    let speakerId: Int?
    let guest: Bool

    /// Üstte gösterilecek etiket. Tanınan → isim; guest → "Misafir"; aksi → nil (gizle).
    var label: String? {
        if let name, !name.isEmpty { return name }
        if guest { return "Misafir" }
        return nil
    }
}

/// `candan.speaker` text-stream topic'ini dinler; brain JSON yollar:
/// `{ "name": string|null, "speakerId": int|null, "guest": bool }`.
/// @Published son konuşmacıyı tutar; üst barda küçük göstergede gösterilir.
///
/// Ayrı topic — transcript (`lk.transcription`), content (`candan.content`),
/// debug (`candan.debug`) akışlarına dokunmaz. Best-effort.
@MainActor
final class SpeakerReceiver: ObservableObject {
    @Published private(set) var current: SpeakerInfo?

    private static let topic = "candan.speaker"
    private var registered = false

    func connectionChanged(_ connected: Bool, room: Room) {
        if connected { register(room) } else { unregister(room) }
    }

    private func register(_ room: Room) {
        guard !registered else { return }
        registered = true
        Task {
            try? await room.registerTextStreamHandler(for: Self.topic) { [weak self] reader, _ in
                let payload = (try? await reader.readAll()) ?? ""
                await MainActor.run { self?.ingest(payload) }
            }
        }
    }

    private func unregister(_ room: Room) {
        guard registered else { return }
        registered = false
        Task { await room.unregisterTextStreamHandler(for: Self.topic) }
    }

    private func ingest(_ payload: String) {
        let line = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        current = SpeakerInfo(
            name: obj["name"] as? String,
            speakerId: obj["speakerId"] as? Int,
            guest: obj["guest"] as? Bool ?? false
        )
    }
}
