import Foundation

final class AppGroupStore {
    static let shared = AppGroupStore()
    static var groupIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "SwiftCastAppGroup") as? String ?? "group.com.ashenarrow.swiftcast"
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let rootURL: URL

    init() {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.groupIdentifier) {
            rootURL = url
        } else {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCastAppGroup", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    var pairCode: String {
        if let code: String = read("pair-code.json") {
            return code
        }
        let code = String(format: "%06d", Int.random(in: 100000...999999))
        write(code, to: "pair-code.json")
        return code
    }

    var settings: SwiftCastSettings {
        get { read("settings.json") ?? .default }
        set { write(newValue, to: "settings.json") }
    }

    var connection: SwiftCastConnectionConfig {
        get { read("connection.json") ?? .default }
        set { write(newValue, to: "connection.json") }
    }

    var offer: String? {
        get { read("offer.json") }
        set { writeOptional(newValue, to: "offer.json") }
    }

    var answer: String? {
        get { read("answer.json") }
        set { writeOptional(newValue, to: "answer.json") }
    }

    var browserIce: [IceCandidateRecord] {
        get { read("browser-ice.json") ?? [] }
        set { write(newValue, to: "browser-ice.json") }
    }

    var broadcastIce: [IceCandidateRecord] {
        get { read("broadcast-ice.json") ?? [] }
        set { write(newValue, to: "broadcast-ice.json") }
    }

    var broadcastStatus: String {
        get { read("broadcast-status.json") ?? "Idle" }
        set { write(newValue, to: "broadcast-status.json") }
    }

    func resetSession() {
        offer = nil
        answer = nil
        browserIce = []
        broadcastIce = []
        broadcastStatus = "Idle"
    }

    func resetPairingCode() {
        resetSession()
        try? FileManager.default.removeItem(at: url("pair-code.json"))
    }

    private func url(_ filename: String) -> URL {
        rootURL.appendingPathComponent(filename)
    }

    private func read<T: Decodable>(_ filename: String) -> T? {
        guard let data = try? Data(contentsOf: url(filename)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, to filename: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(filename), options: [.atomic])
    }

    private func writeOptional<T: Encodable>(_ value: T?, to filename: String) {
        guard let value else {
            try? FileManager.default.removeItem(at: url(filename))
            return
        }
        write(value, to: filename)
    }
}
