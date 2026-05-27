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
    private var advertisedHost = "127.0.0.1"

    init(store: AppGroupStore) {
        self.store = store
    }

    func start() async throws -> URL {
        if let listener, let port = listener.port {
            return URL(string: "\(scheme)://\(advertisedHost):\(port.rawValue)")!
        }

        let parameters: NWParameters
        if let tlsOptions = Self.localTLSOptions() {
            parameters = NWParameters(tls: tlsOptions, tcp: .init())
            scheme = "https"
        } else {
            parameters = .tcp
            scheme = "http"
        }

        advertisedHost = Self.lanAddress()
        let listener = try await startListener(using: parameters)
        self.listener = listener
        return URL(string: "\(scheme)://\(advertisedHost):\(listener.port!.rawValue)")!
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func startListener(using parameters: NWParameters) async throws -> NWListener {
        let safePorts: [UInt16] = [8443, 9443, 10443, 49152, 49153, 49154]
        var lastError: Error?

        for port in safePorts {
            do {
                return try await startListener(using: parameters, port: port)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    private func startListener(using parameters: NWParameters, port: UInt16) async throws -> NWListener {
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: listener)
                case .failed(let error):
                    guard !didResume else { return }
                    didResume = true
                    listener.cancel()
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(throwing: NWError.posix(.ECANCELED))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
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

        if let roomRoute = Self.roomRouteSuffix(for: request.path) {
            return routeRoom(method: request.method, suffix: roomRoute, request: request)
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            return serveStatic(path: "index.html")
        case ("GET", "/watch"):
            return serveStatic(path: "index.html")
        case ("GET", let path) where path.hasPrefix("/assets/"):
            return serveStatic(path: String(path.dropFirst(1)))
        case ("GET", "/api/session"):
            return json(SessionInfo(pairCode: store.pairCode, settings: store.settings))
        case ("GET", "/api/settings"):
            return json(store.settings)
        case ("GET", "/api/status"):
            return json(LocalRoomStatus(phase: store.broadcastStatus, hasOffer: store.offer != nil, hasAnswer: store.answer != nil, browserIce: store.browserIce.count, broadcastIce: store.broadcastIce.count))
        case ("POST", "/api/status"):
            if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let phase = object["phase"] as? String {
                store.broadcastStatus = phase
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid status").data
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

    private func routeRoom(method: String, suffix: String, request: HTTPRequest) -> Data {
        switch (method, suffix) {
        case ("GET", "session"):
            return json(SessionInfo(pairCode: store.pairCode, settings: store.settings))
        case ("GET", "settings"):
            return json(store.settings)
        case ("GET", "status"):
            return json(LocalRoomStatus(phase: store.broadcastStatus, hasOffer: store.offer != nil, hasAnswer: store.answer != nil, browserIce: store.browserIce.count, broadcastIce: store.broadcastIce.count))
        case ("POST", "status"):
            if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let phase = object["phase"] as? String {
                store.broadcastStatus = phase
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid status").data
        case ("POST", "settings"):
            if let settings = try? decoder.decode(SwiftCastSettings.self, from: request.body) {
                store.settings = settings
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid settings").data
        case ("POST", "offer"):
            store.resetSession()
            store.offer = String(data: request.body, encoding: .utf8)
            return json(["ok": true])
        case ("GET", "offer"):
            guard let offer = store.offer else {
                return HTTPResponse(status: 204, reason: "No Content", headers: [:], body: Data()).data
            }
            return HTTPResponse.jsonString(offer).data
        case ("POST", "answer"):
            store.answer = String(data: request.body, encoding: .utf8)
            return json(["ok": true])
        case ("GET", "answer"):
            guard let answer = store.answer else {
                return HTTPResponse(status: 204, reason: "No Content", headers: [:], body: Data()).data
            }
            return HTTPResponse.jsonString(answer).data
        case ("POST", "ice/browser"):
            if let candidate = try? decoder.decode(IceCandidateRecord.self, from: request.body) {
                var candidates = store.browserIce
                candidates.append(candidate)
                store.browserIce = candidates
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid ICE candidate").data
        case ("GET", "ice/browser"):
            let since = Int(request.query["since"] ?? "0") ?? 0
            let candidates = store.browserIce
            let slice = since < candidates.count ? Array(candidates[since...]) : []
            return json(BroadcastIceResponse(next: candidates.count, candidates: slice))
        case ("POST", "ice/broadcast"):
            if let candidate = try? decoder.decode(IceCandidateRecord.self, from: request.body) {
                var candidates = store.broadcastIce
                candidates.append(candidate)
                store.broadcastIce = candidates
                return json(["ok": true])
            }
            return HTTPResponse.badRequest("Invalid ICE candidate").data
        case ("GET", "ice/broadcast"):
            let since = Int(request.query["since"] ?? "0") ?? 0
            let candidates = store.broadcastIce
            let slice = since < candidates.count ? Array(candidates[since...]) : []
            return json(BroadcastIceResponse(next: candidates.count, candidates: slice))
        default:
            return HTTPResponse.notFound("Not found").data
        }
    }

    private func serveStatic(path: String) -> Data {
        guard let root = Self.webClientRoot() else {
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

    private static func webClientRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("WebClient", isDirectory: true),
            resourceURL.appendingPathComponent("dist", isDirectory: true),
            resourceURL
        ]
        return candidates.first { candidate in
            FileManager.default.fileExists(atPath: candidate.appendingPathComponent("index.html").path)
        }
    }

    private static func roomRouteSuffix(for path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4,
              parts[0] == "api",
              parts[1] == "rooms" else {
            return nil
        }
        return parts.dropFirst(3).joined(separator: "/")
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
              let identityValue = first[kSecImportItemIdentity as String] else {
            return nil
        }

        let identity = identityValue as! SecIdentity
        guard let secIdentity = sec_identity_create(identity) else { return nil }

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

private struct LocalRoomStatus: Encodable {
    var phase: String
    var hasOffer: Bool
    var hasAnswer: Bool
    var browserIce: Int
    var broadcastIce: Int
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
