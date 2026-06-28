import Foundation
import LiveKit

/// Hermes `mate_voice` plugin token kaynağı — brain'den BAĞIMSIZ.
///
/// ORTAK SÖZLEŞME (plugin tarafı buna göre kurulu):
///   `GET {tokenBaseURL}/mate/token?identity=<client-id>&room=<opsiyonel>`
///   Header: `X-Mate-Key: <clientKey>`
///   Yanıt:  `{ "url", "room", "token", "identity" }`
///
/// `tokenBaseURL` + `clientKey` Settings'ten gelir (hardcode YOK) → başkaları kendi
/// Hermes/plugin deploy'larına aynı app'le bağlanabilir. Bağlanılacak LiveKit URL'i
/// yanıttaki `url`; ama bu iç/loopback adres ise (örn. ws://127.0.0.1:7880) yok
/// sayılır ve Settings LiveKit URL'ine düşülür (mate-mac'in "her zaman erişilebilir
/// URL" kuralı).
struct HermesTokenSource: TokenSourceFixed {
    enum TokenError: LocalizedError {
        case noEndpoint
        case noKey
        case http(Int)
        case badResponse
        var errorDescription: String? {
            switch self {
            case .noEndpoint: return "Hermes token endpoint URL'i boş (Settings → Bağlantı)."
            case .noKey: return "Hermes istemci anahtarı (X-Mate-Key) boş (Settings → Bağlantı)."
            case let .http(c): return "Hermes token endpoint HTTP \(c)."
            case .badResponse: return "Hermes token yanıtı geçersiz (url/token eksik)."
            }
        }
    }

    func fetch() async throws -> TokenSourceResponse {
        let (base, key, roomOverride, livekitURL, secretsURL) = await MainActor.run {
            (SettingsStore.resolvedTokenEndpointURL,
             SettingsStore.resolvedClientKey,
             SettingsStore.resolvedRoom,
             SettingsStore.resolvedLivekitURL,
             Secrets.livekitServerURL)
        }
        let identity = DeviceIdentity.deviceId

        guard !base.isEmpty else { throw TokenError.noEndpoint }
        guard !key.isEmpty else { throw TokenError.noKey }

        guard var comps = URLComponents(string: base + "/mate/token") else {
            throw TokenError.noEndpoint
        }
        var items = [URLQueryItem(name: "identity", value: identity)]
        if !roomOverride.isEmpty { items.append(URLQueryItem(name: "room", value: roomOverride)) }
        comps.queryItems = items
        guard let endpoint = comps.url else { throw TokenError.noEndpoint }

        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-Mate-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TokenError.badResponse }
        guard (200 ..< 300).contains(http.statusCode) else { throw TokenError.http(http.statusCode) }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (obj["token"] as? String), !token.isEmpty
        else { throw TokenError.badResponse }

        let returnedURL = (obj["url"] as? String) ?? ""
        let room = (obj["room"] as? String) ?? roomOverride
        let name = (obj["identity"] as? String) ?? identity

        // Bağlantı URL'i: yanıttaki url public ise onu kullan; iç/loopback ise yok
        // say → Settings/Secrets URL. (Plugin iç ws://127.0.0.1 dönebilir.)
        let server = Self.pickServerURL(returned: returnedURL,
                                        settings: livekitURL, secrets: secretsURL)
        Log.line("[Hermes] token alındı (room=\(room) identity=\(name) server=\(server.absoluteString))")
        return TokenSourceResponse(serverURL: server, participantToken: token,
                                   participantName: name, roomName: room)
    }

    private static func pickServerURL(returned: String, settings: String, secrets: String) -> URL {
        if !returned.isEmpty, let u = URL(string: returned), !isInternal(returned) {
            return u
        }
        if !returned.isEmpty, isInternal(returned) {
            Log.line("[Hermes] yanıttaki url iç adres (\(returned)) → Settings/Secrets'e düşüldü")
        }
        return URL(string: settings) ?? URL(string: secrets)!
    }

    private static func isInternal(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("127.0.0.1") || l.contains("localhost") || l.contains("://0.0.0.0")
    }
}

/// `Session`'a verilen TEK token kaynağı. **HERMES-ONLY**: brain tamamen devre dışı
/// (sunucuda da kapatıldı). Token yalnız `HermesTokenSource` (mate_voice endpoint)
/// üzerinden çekilir. Endpoint/key eksikse veya istek hata verirse hata YUKARI
/// FIRLATILIR → ekrana (ErrorView) düşer. FALLBACK YOK.
struct MateTokenSource: TokenSourceFixed {
    func fetch() async throws -> TokenSourceResponse {
        try await HermesTokenSource().fetch()
    }
}
