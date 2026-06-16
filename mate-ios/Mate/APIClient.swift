import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case decoding
    case empty
    case timeout
    case cannotConnect
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Geçersiz URL"
        case .http(let c, let m): return "HTTP \(c): \(m)"
        case .decoding: return "Yanıt çözümlenemedi"
        case .empty: return "Boş yanıt"
        case .timeout: return "Bağlantı zaman aşımına uğradı"
        case .cannotConnect: return "Sunucuya bağlanılamadı"
        case .network(let message): return "Ağ hatası: \(message)"
        }
    }
}

struct Voice: Identifiable, Decodable, Hashable {
    let displayName: String
    let filename: String
    var id: String { filename }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case filename
    }
}

/// Speaker-ID (voice-ID) kayıtlı kişi. `sample_count` create yanıtında yok →
/// opsiyonel.
struct Speaker: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let sampleCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name
        case sampleCount = "sample_count"
    }

    var samples: Int { sampleCount ?? 0 }
}

final class APIClient {
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        // LAN'daki brain'e kısa istekler: sunucu kapalıysa 30+ sn spinner yerine
        // 5 sn'de hata ver; bağlantı bekleme kapalı → host yoksa hemen düş.
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 15
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func fetchVoices(baseURL: String, apiKey: String) async throws -> [Voice] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/v1/voices") else {
            throw APIError.badURL
        }
        var req = URLRequest(url: url)
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        try validate(response, data: data)
        return try JSONDecoder().decode([Voice].self, from: data)
    }

    // ---- speaker-ID (voice-ID) enrollment ----

    func listSpeakers(baseURL: String, apiKey: String) async throws -> [Speaker] {
        let (data, resp) = try await send(baseURL: baseURL, path: "/api/speakers",
                                          method: "GET", apiKey: apiKey)
        try validate(resp, data: data)
        return try JSONDecoder().decode([Speaker].self, from: data)
    }

    func createSpeaker(baseURL: String, apiKey: String, name: String) async throws -> Speaker {
        let body = try JSONSerialization.data(withJSONObject: ["name": name])
        let (data, resp) = try await send(baseURL: baseURL, path: "/api/speakers",
                                          method: "POST", apiKey: apiKey,
                                          json: body)
        try validate(resp, data: data)
        return try JSONDecoder().decode(Speaker.self, from: data)
    }

    @discardableResult
    func uploadSample(baseURL: String, apiKey: String, speakerId: Int,
                      wavData: Data, source: String) async throws -> Int {
        guard let url = URL(string: baseURL + "/api/speakers/\(speakerId)/samples?source=\(source)")
        else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\n"
            .data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let (data, resp) = try await session.upload(for: req, from: body)
        try validate(resp, data: data)
        struct R: Decodable { let sample_id: Int }
        return try JSONDecoder().decode(R.self, from: data).sample_id
    }

    func deleteSpeaker(baseURL: String, apiKey: String, speakerId: Int) async throws {
        let (data, resp) = try await send(baseURL: baseURL,
                                          path: "/api/speakers/\(speakerId)",
                                          method: "DELETE", apiKey: apiKey)
        try validate(resp, data: data)
    }

    /// JSON/boş gövdeli basit istek yardımcı.
    private func send(baseURL: String, path: String, method: String,
                      apiKey: String, json: Data? = nil) async throws -> (Data, URLResponse) {
        guard let url = URL(string: baseURL + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = json
        }
        return try await session.data(for: req)
    }

    /// `ws://host:port/path` → `http://host:port` (şema ws→http/wss→https, path/query atılır).
    static func httpBase(fromWS wsURL: String) -> String? {
        let trimmed = wsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty
        else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        default: components.scheme = "http"
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw APIError.http(http.statusCode, String(body))
        }
    }

    private func mapNetworkError(_ error: Error) -> Error {
        if let apiError = error as? APIError { return apiError }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .timedOut:
            return APIError.timeout
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return APIError.cannotConnect
        default:
            return APIError.network(urlError.localizedDescription)
        }
    }
}
