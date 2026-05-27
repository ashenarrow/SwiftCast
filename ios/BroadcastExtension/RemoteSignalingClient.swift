import Foundation

final class RemoteSignalingClient {
    private let baseURL: URL
    private let pairCode: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init?(connection: SwiftCastConnectionConfig, pairCode: String) {
        guard connection.tunnelEnabled,
              let url = URL(string: connection.tunnelBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        self.baseURL = url
        self.pairCode = pairCode

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: configuration)
    }

    func fetchOffer() -> String? {
        request(method: "GET", path: "offer", body: Optional<Data>.none)
    }

    func postAnswer(_ answerJSON: String) {
        _ = request(method: "POST", path: "answer", body: Data(answerJSON.utf8)) as Data?
    }

    func fetchBrowserIce(since: Int) -> CandidatePage? {
        request(method: "GET", path: "ice/browser?since=\(since)", body: Optional<Data>.none)
    }

    func postBroadcastCandidate(_ candidate: IceCandidateRecord) {
        guard let data = try? encoder.encode(candidate) else { return }
        _ = request(method: "POST", path: "ice/broadcast", body: data) as Data?
    }

    func postSettings(_ settings: SwiftCastSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        _ = request(method: "POST", path: "settings", body: data) as Data?
    }

    func postStatus(_ phase: String, detail: String? = nil) {
        let payload = BroadcastStatus(phase: phase, detail: detail, updatedAt: Date().timeIntervalSince1970)
        guard let data = try? encoder.encode(payload) else { return }
        _ = request(method: "POST", path: "status", body: data) as Data?
    }

    private func request<T: Decodable>(method: String, path: String, body: Data?) -> T? {
        guard let data = requestData(method: method, path: path, body: body) else { return nil }
        if T.self == String.self {
            return String(data: data, encoding: .utf8) as? T
        }
        if T.self == Data.self {
            return data as? T
        }
        return try? decoder.decode(T.self, from: data)
    }

    private func requestData(method: String, path: String, body: Data?) -> Data? {
        guard let url = roomURL(path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else { return }
            result = data
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return result
    }

    private func roomURL(path: String) -> URL? {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        let currentPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let roomPath = ["api", "rooms", pairCode, parts[0]]
            .flatMap { $0.split(separator: "/").map(String.init) }
            .joined(separator: "/")
        components?.path = "/" + ([currentPath, roomPath].filter { !$0.isEmpty }.joined(separator: "/"))

        if parts.count == 2 {
            components?.percentEncodedQuery = parts[1]
        }

        return components?.url
    }
}

struct CandidatePage: Codable {
    var next: Int
    var candidates: [IceCandidateRecord]
}

struct BroadcastStatus: Codable {
    var phase: String
    var detail: String?
    var updatedAt: TimeInterval
}
