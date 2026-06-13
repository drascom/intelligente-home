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
