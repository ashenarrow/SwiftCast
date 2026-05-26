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
    @Published var serverStatus = "Starting"
    @Published var settings = AppGroupStore.shared.settings {
        didSet { AppGroupStore.shared.settings = settings }
    }

    private let server = LocalWebServer(store: .shared)

    func startServer() async {
        do {
            let url = try await server.start()
            serverURL = url
            serverStatus = "Ready"
        } catch {
            serverStatus = "Server failed: \(error.localizedDescription)"
        }
    }

    func resetPairing() {
        AppGroupStore.shared.resetSession()
    }
}

