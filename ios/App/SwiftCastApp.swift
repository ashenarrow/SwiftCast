import SwiftUI

@main
struct SwiftCastApp: App {
    @StateObject private var model = SwiftCastModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .task {
                    await model.startServer()
                }
        }
    }
}

@MainActor
final class SwiftCastModel: ObservableObject {
    @Published var serverURL: URL?
    @Published var serverStatus = "Local server idle"
    @Published var broadcastStatus = AppGroupStore.shared.broadcastStatus
    @Published var tunnelStatus = ""
    @Published var settings = AppGroupStore.shared.settings {
        didSet { AppGroupStore.shared.settings = settings }
    }
    @Published var connection = AppGroupStore.shared.connection {
        didSet {
            AppGroupStore.shared.connection = connection
            Task { await startServer() }
        }
    }

    private let server = LocalWebServer(store: .shared)

    func startServer() async {
        guard connection.localServerEnabled else {
            server.stop()
            serverURL = nil
            serverStatus = "Local server off"
            return
        }
        do {
            let url = try await server.start()
            serverURL = url
            serverStatus = "Foreground local server"
        } catch {
            serverStatus = "Server failed: \(error.localizedDescription)"
        }
    }

    func resetPairing() {
        AppGroupStore.shared.resetPairingCode()
        broadcastStatus = AppGroupStore.shared.broadcastStatus
        objectWillChange.send()
    }

    func refreshBroadcastStatus() {
        broadcastStatus = AppGroupStore.shared.broadcastStatus
        Task { await refreshTunnelStatus() }
    }

    private func refreshTunnelStatus() async {
        guard connection.tunnelEnabled,
              var components = URLComponents(string: connection.tunnelBaseURL) else {
            return
        }
        components.path = "/api/rooms/\(AppGroupStore.shared.pairCode)/status"
        guard let url = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            let phase = object["phase"] as? String ?? "unknown"
            let hasOffer = object["hasOffer"] as? Bool == true ? "offer" : "no offer"
            let hasAnswer = object["hasAnswer"] as? Bool == true ? "answer" : "no answer"
            let browserIce = object["browserIce"] as? Int ?? 0
            let broadcastIce = object["broadcastIce"] as? Int ?? 0
            await MainActor.run {
                tunnelStatus = "\(phase) | \(hasOffer) | \(hasAnswer) | browser ICE \(browserIce) | broadcast ICE \(broadcastIce)"
            }
        } catch {
            await MainActor.run {
                tunnelStatus = "Tunnel status unavailable"
            }
        }
    }
}
