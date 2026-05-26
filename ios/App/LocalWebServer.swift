import Foundation
import Darwin
import Network
import Security

final class LocalWebServer {
    private let store: AppGroupStore
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "swiftcast.local-web")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var scheme = "http"

    init(store: AppGroupStore) {
        self.store = store
    }

    func start() async throws -> URL {
        if let listener, let port = listener.port {
            return URL(string: "\(scheme)://\(Self.lanAddress()):\(port.rawValue)")!
        }

        let parameters: NWParameters
        if let tlsOptions = Self.localTLSOptions() {
            parameters = NWParameters(tls: tlsOptions, tcp: .init())
            scheme = "https"
        } else {
            parameters = .tcp
            scheme = "http"
        }

        let listener = try NWListener(using: parameters, on: 0)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        while listener.port == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        return URL(string: "\(scheme)://\(Self.lanAddress()):\(listener.port!.rawValue)")!
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let response = self.route(data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func route(_ data: Data) -> Data {
        guard let request = HTTPRequest(data: data) else {
            return HTTPResponse.badRequest("Malformed request").data
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return serveStatic(path: "index.html")
        case ("GET", let path) where path.hasPrefix("/assets/"):
            return serveStatic(path: String(path.dropFirst(1)))
        case ("GET", "/api/session"):
            return json(SessionInfo(pairCode: store.pairCode, settings: store.settings))
        case ("GET", "/api/settings"):
            return json(store.settings)
        case ("POST", "/api/settings"):
            if let settings = try? decoder.decode(SwiftCastSettings.self, from: request.body) {
                store.settings = settings
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid settings").data
        case ("POST", "/api/offer"):
            store.resetSession()
            store.offer = String(data: request.body, encoding: .utf8)
            return json(["ok": true])
        case ("GET", "/api/answer"):
            guard let answer = store.answer else {
                return HTTPResponse(status: 204, reason: "No Content", headers: [:], body: Data()).data
            }
            return HTTPResponse.jsonString(answer).data
        case ("POST", "/api/ice/browser"):
            if let candidate = try? decoder.decode(IceCandidateRecord.self, from: request.body) {
                var candidates = store.browserIce
                candidates.append(candidate)
                store.browserIce = candidates
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid ICE candidate").data
        case ("GET", "/api/ice/broadcast"):
            let since = Int(request.query["since"] ?? "0") ?? 0
            let candidates = store.broadcastIce
            let slice = since < candidates.count ? Array(candidates[since...]) : []
            return json(BroadcastIceResponse(next: candidates.count, candidates: slice))
        default:
            return HTTPResponse.notFound("Not found").data
        }
    }

    private func serveStatic(path: String) -> Data {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("dist", isDirectory: true) else {
            return HTTPResponse.notFound("Web client is not bundled").data
        }
        let fileURL = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL) else {
            return HTTPResponse.notFound("Missing \(path)").data
        }
        return HTTPResponse(
            status: 200,
            reason: "OK",
            headers: ["content-type": Self.contentType(for: path), "cache-control": "no-store"],
            body: data
        ).data
    }

    private func json<T: Encodable>(_ value: T) -> Data {
        guard let data = try? encoder.encode(value) else {
            return HTTPResponse.badRequest("JSON encoding failed").data
        }
        return HTTPResponse(status: 200, reason: "OK", headers: ["content-type": "application/json"], body: data).data
    }

    private static func contentType(for path: String) -> String {
        if path.hasSuffix(".js") { return "text/javascript" }
        if path.hasSuffix(".css") { return "text/css" }
        if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if path.hasSuffix(".svg") { return "image/svg+xml" }
        return "application/octet-stream"
    }

    private static func localTLSOptions() -> NWProtocolTLS.Options? {
        guard let url = Bundle.main.url(forResource: "swiftcast-local", withExtension: "p12"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        let importOptions = [kSecImportExportPassphrase as String: "swiftcast-local"]
        var imported: CFArray?
        guard SecPKCS12Import(data as CFData, importOptions as CFDictionary, &imported) == errSecSuccess,
              let first = (imported as? [[String: Any]])?.first,
              let identity = first[kSecImportItemIdentity as String] as? SecIdentity,
              let secIdentity = sec_identity_create(identity) else {
            return nil
        }

        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        return options
    }

    private static func lanAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: hostname)
            break
        }
        return address
    }
}

private struct BroadcastIceResponse: Encodable {
    var next: Int
    var candidates: [IceCandidateRecord]
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    init?(data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerString = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        method = String(parts[0])
        let rawTarget = String(parts[1])
        if let components = URLComponents(string: rawTarget) {
            path = components.path.isEmpty ? "/" : components.path
            query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        } else {
            path = rawTarget
            query = [:]
        }

        body = Data(data[separator.upperBound...])
    }
}

private struct HTTPResponse {
    var status: Int
    var reason: String
    var headers: [String: String]
    var body: Data

    var data: Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        var allHeaders = headers
        allHeaders["content-length"] = "\(body.count)"
        allHeaders["connection"] = "close"
        allHeaders["access-control-allow-origin"] = "*"
        for (key, value) in allHeaders {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    static func jsonString(_ string: String) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", headers: ["content-type": "application/json"], body: Data(string.utf8))
    }

    static func badRequest(_ message: String) -> HTTPResponse {
        HTTPResponse(status: 400, reason: "Bad Request", headers: ["content-type": "text/plain"], body: Data(message.utf8))
    }

    static func notFound(_ message: String) -> HTTPResponse {
        HTTPResponse(status: 404, reason: "Not Found", headers: ["content-type": "text/plain"], body: Data(message.utf8))
    }
}
