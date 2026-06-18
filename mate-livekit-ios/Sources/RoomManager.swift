import Foundation
import LiveKit

@MainActor
final class RoomManager: ObservableObject {

    let room = Room()

    @Published var connectionState: String = "disconnected"
    @Published var isMicEnabled: Bool = false
    @Published var remoteParticipants: [String] = []
    @Published var lastError: String?
    @Published var log: [String] = []

    init() {
        room.add(delegate: self)
        appendLog("RoomManager hazır.")
    }

    // MARK: - Logging

    private func appendLog(_ line: String) {
        let ts = Self.timeFormatter.string(from: Date())
        log.append("[\(ts)] \(line)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Connection

    func connect(url: String, token: String) async {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedToken.isEmpty else {
            appendLog("HATA: URL veya token boş.")
            lastError = "URL veya token boş."
            return
        }
        appendLog("Bağlanılıyor: \(trimmedURL)")
        do {
            try await room.connect(url: trimmedURL, token: trimmedToken)
            appendLog("Bağlandı. Mikrofon açılıyor…")
            try await room.localParticipant.setMicrophone(enabled: true)
            isMicEnabled = room.localParticipant.isMicrophoneEnabled()
            appendLog("Mikrofon: \(isMicEnabled ? "açık" : "kapalı")")
            refreshParticipants()
        } catch {
            appendLog("BAĞLANTI HATASI: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    func disconnect() async {
        appendLog("Bağlantı kesiliyor…")
        await room.disconnect()
        isMicEnabled = false
        remoteParticipants = []
    }

    func toggleMic() async {
        let target = !room.localParticipant.isMicrophoneEnabled()
        do {
            try await room.localParticipant.setMicrophone(enabled: target)
            isMicEnabled = room.localParticipant.isMicrophoneEnabled()
            appendLog("Mikrofon \(isMicEnabled ? "açıldı" : "kapatıldı").")
        } catch {
            appendLog("MİKROFON HATASI: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func refreshParticipants() {
        remoteParticipants = room.remoteParticipants.values.map {
            $0.identity?.stringValue ?? "(bilinmiyor)"
        }
    }
}

// MARK: - RoomDelegate

extension RoomManager: RoomDelegate {

    nonisolated func room(_ room: Room,
                          didUpdateConnectionState connectionState: ConnectionState,
                          from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            self.connectionState = String(describing: connectionState)
            self.appendLog("Durum: \(oldConnectionState) → \(connectionState)")
        }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.appendLog("Katılımcı geldi: \(participant.identity?.stringValue ?? "?")")
            self.refreshParticipants()
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in
            self.appendLog("Katılımcı ayrıldı: \(participant.identity?.stringValue ?? "?")")
            self.refreshParticipants()
        }
    }

    nonisolated func room(_ room: Room,
                          participant: RemoteParticipant,
                          didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor in
            let kind = String(describing: publication.kind)
            self.appendLog("Abone olundu (\(kind)) → \(participant.identity?.stringValue ?? "?"). Ses otomatik çalıyor.")
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor in
            if let error {
                self.appendLog("Bağlantı koptu (hata): \(error.localizedDescription)")
                self.lastError = error.localizedDescription
            } else {
                self.appendLog("Bağlantı kapatıldı.")
            }
            self.remoteParticipants = []
            self.isMicEnabled = false
        }
    }
}
