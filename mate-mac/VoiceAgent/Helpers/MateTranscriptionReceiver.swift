import Foundation
import LiveKit

/// Transcript alıcısı — agent HEM kullanıcı HEM asistan satırını aynı gönderenden
/// ("assistant" kimliği) yayınlar. SDK'nın varsayılan `TranscriptionStreamReceiver`'ı
/// satırı YALNIZ gönderen kimliğine göre atfettiği için kullanıcının kendi sözünü de
/// "agent" olarak işaretlerdi. Bu alıcı bunun yerine agent'in koyduğu açık
/// `mate.role` stream attribute'unu okur (user/assistant); yoksa gönderen kimliğine
/// düşer. Aksi her şey (segment id, final, akış) standart text-stream davranışıdır.
///
/// `lk.transcription` topic'inde dinler — bu yüzden Session'a verilen receiver
/// listesinde SDK'nın varsayılan transcription receiver'ı YERİNE bu kullanılmalı
/// (aynı topic'e iki handler kaydı çakışır).
final class MateTranscriptionReceiver: MessageReceiver, @unchecked Sendable {
    private let room: Room
    private let topic: String

    init(room: Room, topic: String = "lk.transcription") {
        self.room = room
        self.topic = topic
    }

    func messages() async throws -> AsyncStream<ReceivedMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: ReceivedMessage.self)
        let room = room
        let topic = topic

        try await room.registerTextStreamHandler(for: topic) { reader, participantIdentity in
            let attrs = reader.info.attributes
            let id = reader.info.id
            let timestamp = reader.info.timestamp
            let isUser = Self.isUserLine(attrs: attrs, sender: participantIdentity, room: room)
            let isFinal = (attrs["lk.transcription_final"] as NSString?)?.boolValue ?? false

            // agent her satırı tek send_text ile (tam metin) yollar; yine de
            // chunk gelebilir → biriktirip her güncellemede yayınla, kapanışta final.
            var content = ""
            for try await chunk in reader {
                content += chunk
                continuation.yield(Self.message(id: id, ts: timestamp, text: content,
                                                 isUser: isUser, final: isFinal))
            }
            continuation.yield(Self.message(id: id, ts: timestamp, text: content,
                                             isUser: isUser, final: true))
        }

        continuation.onTermination = { _ in
            Task { await room.unregisterTextStreamHandler(for: topic) }
        }
        return stream
    }

    private static func message(id: String, ts: Date, text: String,
                                isUser: Bool, final: Bool) -> ReceivedMessage {
        ReceivedMessage(
            id: id, timestamp: ts,
            content: isUser ? .userTranscript(text) : .agentTranscript(text),
            isFinal: final
        )
    }

    /// Konuşmacı: önce agent'in açık `mate.role` attribute'u, yoksa gönderen
    /// kimliği (yerel katılımcı → kullanıcı, diğer → agent).
    private static func isUserLine(attrs: [String: String],
                                   sender: Participant.Identity, room: Room) -> Bool {
        switch attrs["mate.role"]?.lowercased() {
        case "user": return true
        case "assistant", "agent": return false
        default: return sender == room.localParticipant.identity
        }
    }
}
