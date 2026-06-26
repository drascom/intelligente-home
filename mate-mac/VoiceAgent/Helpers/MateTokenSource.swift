import Foundation
import LiveKit

/// LiveKit token kaynağı — HER bağlanışta (`Session.start → fetch()`) brain'den
/// TAZE token çeker: `POST {brainURL}/api/livekit-token` + `Authorization: Bearer
/// <brainToken>`. Dönen JSON `{ serverUrl, roomName, participantToken,
/// participantName }` bağlantıya uygulanır.
///
/// FALLBACK: brainToken boşsa veya istek başarısız/timeout ise statik `Secrets`
/// token + Settings LiveKit URL'ine düşülür (uygulama kırılmaz); sebep loglanır.
struct MateTokenSource: TokenSourceFixed {
    func fetch() async throws -> TokenSourceResponse {
        // @MainActor-isolated Secrets/SettingsStore'u main'de oku (String'ler Sendable).
        let (brainURL, brainToken, livekitURL, secretsURL, secretsToken) = await MainActor.run {
            (SettingsStore.resolvedBrainURL,
             SettingsStore.resolvedBrainToken,
             SettingsStore.resolvedLivekitURL,
             Secrets.livekitServerURL,
             Secrets.livekitToken)
        }

        // Statik fallback yanıtı.
        func fallback(_ reason: String) -> TokenSourceResponse {
            Log.line("[Token] statik token'a düşüldü (\(reason))")
            let url = URL(string: livekitURL) ?? URL(string: secretsURL)!
            return TokenSourceResponse(serverURL: url, participantToken: secretsToken,
                                       participantName: "mac-client", roomName: "mate-demo")
        }

        // Bearer zinciri: ÖNCE oto-kayıt client token'ı (Keychain), yoksa Settings
        // manuel Brain Token, o da yoksa statik Secrets'e düş.
        let deviceToken = await DeviceRegistration.clientToken(brainURL: brainURL)
        let bearer: String
        let source: String
        if let dt = deviceToken, !dt.isEmpty {
            bearer = dt; source = "device"
        } else if !brainToken.isEmpty {
            bearer = brainToken; source = "manuel"
        } else {
            return fallback("bearer yok (oto-kayıt başarısız + manuel boş)")
        }
        Log.line("[Token] bearer kaynağı=\(source)")

        let base = brainURL.hasSuffix("/") ? String(brainURL.dropLast()) : brainURL
        guard let endpoint = URL(string: base + "/api/livekit-token") else {
            return fallback("brainURL geçersiz")
        }

        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return fallback("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = (obj["participantToken"] as? String), !token.isEmpty
            else {
                return fallback("JSON/participantToken yok")
            }
            let server = (obj["serverUrl"] as? String).flatMap { URL(string: $0) }
                ?? URL(string: livekitURL) ?? URL(string: secretsURL)!
            let room = obj["roomName"] as? String ?? "mate-demo"
            let name = obj["participantName"] as? String ?? "mac-client"
            Log.line("[Token] taze token alındı (room=\(room) name=\(name))")
            return TokenSourceResponse(serverURL: server, participantToken: token,
                                       participantName: name, roomName: room)
        } catch {
            return fallback("istek hata/timeout: \(error.localizedDescription)")
        }
    }
}
