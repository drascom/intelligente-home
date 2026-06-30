import LiveKit
import SwiftUI

/// Agent'in gönderdiği zengin içerik öğesi (YouTube / görsel / PDF / web).
struct ContentItem: Identifiable, Equatable {
    enum Kind: String { case youtube, image, pdf, web, unknown }
    let id: String
    let kind: Kind
    let url: String
    let title: String
}

/// `mate.content` text-stream topic'ini dinler; agent JSON payload yollar:
/// `{ "type": "youtube"|"image"|"pdf"|"web", "url": "...", "id": "...", "title": "..." }`.
/// Parse edip @Published listede tutar; sağ içerik paneli bunu gösterir.
///
/// Ayrı topic — `lk.transcription` (MateTranscriptionReceiver) ve `mate.debug`
/// akışlarına dokunmaz. Best-effort: hatalı/boş payload sessiz atlanır.
@MainActor
final class ContentChannelReceiver: ObservableObject {
    @Published private(set) var items: [ContentItem] = []
    /// En son eklenen öğe — yeni içerik gelince paneli otomatik açmak için.
    @Published private(set) var latest: ContentItem?

    private static let topic = "mate.content"
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

        let kind = ContentItem.Kind(rawValue: (obj["type"] as? String ?? "").lowercased()) ?? .unknown
        let url = obj["url"] as? String ?? ""
        let title = obj["title"] as? String ?? url
        let id = obj["id"] as? String ?? "\(items.count)-\(url)"
        let item = ContentItem(id: id, kind: kind, url: url, title: title)
        items.append(item)
        latest = item
    }
}
