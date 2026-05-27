import ReplayKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: SwiftCastModel

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    pairingCard
                    broadcastCard
                    captureSettingsCard
                    qualitySettingsCard
                    audioSettingsCard
                    roiSettingsCard
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
            Text("Use the Railway tunnel URL for real gaming sessions. The local server is only a foreground fallback because iOS suspends apps that leave the screen.")
                .foregroundStyle(.secondary)
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Pairing", systemImage: "link")
                .font(.headline)

            Text("Pair code \(AppGroupStore.shared.pairCode)")
                .font(.title3.monospacedDigit().bold())

            Toggle("Use Railway tunnel", isOn: $model.connection.tunnelEnabled)

            TextField("Tunnel URL", text: $model.connection.tunnelBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)

            if let tunnelURL = tunnelViewerURL {
                QRCodeView(text: tunnelURL.absoluteString)
                    .frame(width: 180, height: 180)
                    .padding(.vertical, 4)

                Text(tunnelURL.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

            Divider()

            Toggle("Foreground local fallback", isOn: $model.connection.localServerEnabled)

            Label(model.serverStatus, systemImage: "network")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let url = model.serverURL {
                Text(url.absoluteString)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }

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
            Text("Tap the broadcast button below and choose SwiftCast Broadcast. This is the system screen broadcast prompt.")
                .foregroundStyle(.secondary)
            BroadcastPickerButton()
                .frame(width: 112, height: 112)
                .padding(.vertical, 4)
        }
        .cardStyle()
    }

    private var captureSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Capture")
                .font(.headline)

            Picker("Preset", selection: $model.settings.preset) {
                ForEach(SwiftCastPreset.allCases, id: \.self) { preset in
                    Text(preset.rawValue.capitalized).tag(preset)
                }
            }

            Stepper("Width \(model.settings.width)", value: $model.settings.width, in: 320...1920, step: 16)
            Stepper("Height \(model.settings.height)", value: $model.settings.height, in: 240...1080, step: 16)
            Stepper("FPS \(model.settings.fps)", value: $model.settings.fps, in: 10...60, step: 1)
        }
        .cardStyle()
    }

    private var qualitySettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Encoder")
                .font(.headline)

            Toggle("Dynamic bitrate", isOn: $model.settings.dynamicBitrateEnabled)
            Toggle("Temporal compression", isOn: $model.settings.temporalCompressionEnabled)
            Toggle("P-frames", isOn: $model.settings.pFramesEnabled)
            Stepper("Min bitrate \(model.settings.minBitrateKbps) Kbps", value: $model.settings.minBitrateKbps, in: 250...20000, step: 250)
            Stepper("Max bitrate \(model.settings.maxBitrateKbps) Kbps", value: $model.settings.maxBitrateKbps, in: 500...40000, step: 250)
            Stepper("Keyframe interval \(model.settings.keyframeIntervalMs) ms", value: $model.settings.keyframeIntervalMs, in: 250...5000, step: 250)

            VStack(alignment: .leading) {
                Text("Congestion response \(model.settings.congestionAggressiveness, specifier: "%.2f")")
                    .font(.subheadline)
                Slider(value: $model.settings.congestionAggressiveness, in: 0.1...1.0)
            }
        }
        .cardStyle()
    }

    private var audioSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio Capture")
                .font(.headline)

            Toggle("App audio", isOn: $model.settings.appAudioEnabled)
            Toggle("Mic audio", isOn: $model.settings.micAudioEnabled)
            VStack(alignment: .leading) {
                Text("App gain \(model.settings.appAudioGain, specifier: "%.2f")")
                Slider(value: $model.settings.appAudioGain, in: 0...2)
            }
            VStack(alignment: .leading) {
                Text("Mic gain \(model.settings.micGain, specifier: "%.2f")")
                Slider(value: $model.settings.micGain, in: 0...2)
            }
            Stepper("A/V sync \(model.settings.audioSyncOffsetMs) ms", value: $model.settings.audioSyncOffsetMs, in: -250...250, step: 5)
        }
        .cardStyle()
    }

    private var roiSettingsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROI")
                .font(.headline)

            Toggle("Enable ROI", isOn: $model.settings.roiEnabled)
            Picker("Mode", selection: $model.settings.roiMode) {
                ForEach(SwiftCastROIMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            VStack(alignment: .leading) {
                Text("ROI X \(model.settings.roiRect.x, specifier: "%.2f")")
                Slider(value: $model.settings.roiRect.x, in: 0...1)
                Text("ROI Y \(model.settings.roiRect.y, specifier: "%.2f")")
                Slider(value: $model.settings.roiRect.y, in: 0...1)
                Text("ROI Width \(model.settings.roiRect.width, specifier: "%.2f")")
                Slider(value: $model.settings.roiRect.width, in: 0.05...1)
                Text("ROI Height \(model.settings.roiRect.height, specifier: "%.2f")")
                Slider(value: $model.settings.roiRect.height, in: 0.05...1)
            }
        }
        .cardStyle()
    }

    private var tunnelViewerURL: URL? {
        guard var components = URLComponents(string: model.connection.tunnelBaseURL) else { return nil }
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "pair", value: AppGroupStore.shared.pairCode)]
        return components.url
    }

}

struct BroadcastPickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = Bundle.main.bundleIdentifier.map { "\($0).broadcast" } ?? "com.ashenarrow.swiftcast.broadcast"
        picker.showsMicrophoneButton = true
        picker.tintColor = .systemGreen
        picker.accessibilityLabel = "Start SwiftCast Broadcast"
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
