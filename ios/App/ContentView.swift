import ReplayKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SwiftCastModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    serverCard
                    broadcastCard
                    settingsCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("SwiftCast")
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chrome WebCodecs mirror")
                .font(.title.bold())
            Text("Open the local URL in Chrome, start the browser peer, then start the SwiftCast broadcast from iOS Control Center or the picker below.")
                .foregroundStyle(.secondary)
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.serverStatus, systemImage: "network")
                .font(.headline)

            if let url = model.serverURL {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 180, height: 180)
                    .padding(.vertical, 4)

                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            Text("Pair code \(AppGroupStore.shared.pairCode)")
                .font(.subheadline.monospacedDigit())

            Button("Reset pairing") {
                model.resetPairing()
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private var broadcastCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Broadcast")
                .font(.headline)
            Text("The extension owns capture, H.264 encoding, and WebRTC DataChannel media.")
                .foregroundStyle(.secondary)
            BroadcastPickerButton()
                .frame(width: 220, height: 48)
        }
        .cardStyle()
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gaming Settings")
                .font(.headline)

            Picker("Preset", selection: $model.settings.preset) {
                ForEach(SwiftCastPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue.capitalized).tag(preset)
                }
            }

            Toggle("Dynamic bitrate", isOn: $model.settings.dynamicBitrateEnabled)
            Toggle("Temporal compression", isOn: $model.settings.temporalCompressionEnabled)
            Toggle("P-frames", isOn: $model.settings.pFramesEnabled)
            Toggle("App audio", isOn: $model.settings.appAudioEnabled)
            Toggle("Mic audio", isOn: $model.settings.micAudioEnabled)
            Toggle("ROI", isOn: $model.settings.roiEnabled)

            HStack {
                Text("Bitrate")
                Spacer()
                Text("\(model.settings.minBitrateKbps)-\(model.settings.maxBitrateKbps) Kbps")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

}

struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = "com.swiftcast.app.broadcast"
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}

private extension View {
    func cardStyle() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
