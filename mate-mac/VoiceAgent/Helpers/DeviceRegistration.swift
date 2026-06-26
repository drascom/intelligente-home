import Foundation

/// Cihazı brain'e OTO-kaydeder ve client token'ı Keychain'de saklar.
///
/// `POST {brainURL}/api/device/register` (AÇIK / no-auth — özel NetBird mesh içi
/// varsayımı; public internete açılırsa auth eklenmeli). Body `{deviceId, name}`,
/// yanıt `{token, clientId, name}`. Idempotent: aynı deviceId → aynı token.
enum DeviceRegistration {
    /// Keychain'de client token varsa onu döndür; yoksa kaydolup yeni token'ı
    /// saklayıp döndür. Başarısızsa nil (çağıran manuel/Secrets fallback'e düşer).
    nonisolated static func clientToken(brainURL: String) async -> String? {
        if let cached = Keychain.read(DeviceIdentity.clientTokenKey), !cached.isEmpty {
            return cached
        }
        let base = brainURL.hasSuffix("/") ? String(brainURL.dropLast()) : brainURL
        guard let endpoint = URL(string: base + "/api/device/register") else { return nil }

        var req = URLRequest(url: endpoint, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["deviceId": DeviceIdentity.deviceId, "name": DeviceIdentity.deviceName]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = obj["token"] as? String, !token.isEmpty
            else {
                Log.error("[Device] kayıt başarısız (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1))")
                return nil
            }
            Keychain.write(DeviceIdentity.clientTokenKey, token)
            Log.line("[Device] kaydoldu clientId=\(obj["clientId"] ?? "-") name=\(obj["name"] ?? "-")")
            return token
        } catch {
            Log.error("[Device] kayıt hata/timeout: \(error.localizedDescription)")
            return nil
        }
    }
}
