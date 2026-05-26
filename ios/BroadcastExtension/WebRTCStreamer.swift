import Foundation
import WebRTC

final class WebRTCStreamer: NSObject {
    private let store: AppGroupStore
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var videoChannel: RTCDataChannel?
    private var audioChannel: RTCDataChannel?
    private var controlChannel: RTCDataChannel?
    private var icePollTimer: DispatchSourceTimer?
    private var browserIceCursor = 0
    private var keyframeRequested = true
    private let queue = DispatchQueue(label: "swiftcast.webrtc.streamer")

    init(store: AppGroupStore) {
        self.store = store
        self.factory = RTCPeerConnectionFactory()
        super.init()
    }

    func start() {
        queue.async {
            self.waitForOfferAndAnswer()
        }
    }

    func stop() {
        icePollTimer?.cancel()
        peerConnection?.close()
        peerConnection = nil
        videoChannel = nil
        audioChannel = nil
        controlChannel = nil
    }

    func takeKeyframeRequest() -> Bool {
        queue.sync {
            let value = keyframeRequested
            keyframeRequested = false
            return value
        }
    }

    func sendVideo(_ frame: EncodedVideoFrame) {
        let flags: SwiftCastPacketFlags = frame.isKeyframe ? [.keyframe, .config] : []
        let packets = MediaPacketWriter.packets(
            type: .video,
            streamId: 1,
            frameId: frame.frameId,
            timestampUs: frame.timestampUs,
            flags: flags,
            configVersion: frame.configVersion,
            payload: frame.payload
        )
        send(packets, on: videoChannel)
    }

    func sendAudio(_ packet: EncodedAudioPacket) {
        let packets = MediaPacketWriter.packets(
            type: .audio,
            streamId: packet.streamId,
            frameId: packet.frameId,
            timestampUs: packet.timestampUs,
            flags: [],
            configVersion: 1,
            payload: packet.payload
        )
        send(packets, on: audioChannel)
    }

    private func waitForOfferAndAnswer() {
        let deadline = Date().addingTimeInterval(20)
        while store.offer == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let offerJSON = store.offer,
              let offer = RTCSessionDescription(json: offerJSON) else {
            return
        }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        peerConnection = pc

        pc.setRemoteDescription(offer) { [weak self] error in
            guard error == nil, let self else { return }
            pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                guard error == nil, let answer else { return }
                pc.setLocalDescription(answer) { error in
                    guard error == nil else { return }
                    self.store.answer = answer.jsonString
                    self.startIcePolling()
                }
            }
        }
    }

    private func startIcePolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            self?.pollBrowserIce()
        }
        timer.resume()
        icePollTimer = timer
    }

    private func pollBrowserIce() {
        guard let peerConnection else { return }
        let candidates = store.browserIce
        guard browserIceCursor < candidates.count else { return }
        for record in candidates[browserIceCursor...] {
            peerConnection.add(RTCIceCandidate(sdp: record.candidate, sdpMLineIndex: record.sdpMLineIndex, sdpMid: record.sdpMid)) { _ in }
        }
        browserIceCursor = candidates.count
    }

    private func send(_ packets: [Data], on channel: RTCDataChannel?) {
        guard let channel, channel.readyState == .open else { return }
        for packet in packets {
            channel.sendData(RTCDataBuffer(data: packet, isBinary: true))
        }
    }

    private func handleControl(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        if type == "request-keyframe" {
            queue.async { self.keyframeRequested = true }
        }
        if type == "settings", let settingsObject = object["settings"],
           let settingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
           let settings = try? JSONDecoder().decode(SwiftCastSettings.self, from: settingsData) {
            store.settings = settings
            if settings.roiEnabled {
                queue.async { self.keyframeRequested = true }
            }
        }
        if type == "stats", let rttMs = object["rttMs"] as? Double {
            applyDynamicBitrate(rttMs: rttMs)
        }
    }

    private func applyDynamicBitrate(rttMs: Double) {
        var settings = store.settings
        guard settings.dynamicBitrateEnabled else { return }
        let oldMax = settings.maxBitrateKbps
        if rttMs > 120 {
            settings.maxBitrateKbps = max(settings.minBitrateKbps, Int(Double(settings.maxBitrateKbps) * 0.88))
        } else if rttMs < 45 {
            settings.maxBitrateKbps = min(12000, Int(Double(settings.maxBitrateKbps) * 1.04))
        }
        if settings.maxBitrateKbps != oldMax {
            store.settings = settings
        }
    }
}

extension WebRTCStreamer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        dataChannel.delegate = self
        switch dataChannel.label {
        case "video": videoChannel = dataChannel
        case "audio": audioChannel = dataChannel
        case "control": controlChannel = dataChannel
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var candidates = store.broadcastIce
        candidates.append(IceCandidateRecord(candidate: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid))
        store.broadcastIce = candidates
    }
}

extension WebRTCStreamer: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.label == "control" else { return }
        handleControl(buffer.data)
    }
}

private extension RTCSessionDescription {
    convenience init?(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = object["type"] as? String,
              let sdp = object["sdp"] as? String else {
            return nil
        }
        let type: RTCSdpType
        switch typeString {
        case "offer": type = .offer
        case "answer": type = .answer
        case "pranswer": type = .prAnswer
        default: return nil
        }
        self.init(type: type, sdp: sdp)
    }

    var jsonString: String {
        let typeString: String
        switch type {
        case .offer: typeString = "offer"
        case .prAnswer: typeString = "pranswer"
        case .answer: typeString = "answer"
        @unknown default: typeString = "answer"
        }
        let object = ["type": typeString, "sdp": sdp]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
