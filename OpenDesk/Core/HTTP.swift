import Foundation

enum APIError: LocalizedError {
    case notConfigured(String)
    case badURL(String)
    case status(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let s): return "\(s) isn't configured yet. Add it in Settings."
        case .badURL(let s): return "Bad URL: \(s)"
        case .status(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func data(_ urlString: String, method: String = "GET", headers: [String: String] = [:], body: Encodable? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.status(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type = T.self, _ urlString: String, method: String = "GET", headers: [String: String] = [:], body: Encodable? = nil) async throws -> T {
        let d = try await data(urlString, method: method, headers: headers, body: body)
        let dec = JSONDecoder()
        return try dec.decode(T.self, from: d)
    }
}

extension String {
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
    var urlEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self }
    var queryEncoded: String { addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))) ?? self }
}
