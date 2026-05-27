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
        objectWillChange.send()
    }
}
