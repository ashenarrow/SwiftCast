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
    private var remoteSignaling: RemoteSignalingClient?
    private var isStopped = false
    private let queue = DispatchQueue(label: "swiftcast.webrtc.streamer")

    init(store: AppGroupStore) {
        self.store = store
        self.factory = RTCPeerConnectionFactory()
        super.init()
    }

    func start() {
        isStopped = false
        store.broadcastStatus = "Waiting for browser"
        queue.async {
            self.waitForOfferAndAnswer()
        }
    }

    func stop() {
        isStopped = true
        store.broadcastStatus = "Idle"
        remoteSignaling?.postStatus("idle")
        icePollTimer?.cancel()
        peerConnection?.close()
        peerConnection = nil
        videoChannel = nil
        audioChannel = nil
        controlChannel = nil
        remoteSignaling = nil
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
        remoteSignaling = RemoteSignalingClient(connection: store.connection, pairCode: store.pairCode)
        remoteSignaling?.postSettings(store.settings)
        remoteSignaling?.postStatus("waiting-for-offer", detail: "\(store.diagnostics), pair \(store.pairCode)")

        var offerJSON: String?
        while !isStopped && peerConnection == nil {
            offerJSON = remoteSignaling?.fetchOffer() ?? store.offer
            if offerJSON != nil { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let offerJSON,
              let offer = RTCSessionDescription(json: offerJSON) else {
            return
        }
        store.broadcastStatus = "Browser offer received"
        remoteSignaling?.postStatus("offer-received")

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [
            RTCIceServer(urlStrings: [
                "stun:stun.l.google.com:19302",
                "stun:stun1.l.google.com:19302"
            ])
        ]
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
                    let answerJSON = answer.jsonString
                    if let remoteSignaling = self.remoteSignaling {
                        remoteSignaling.postAnswer(answerJSON)
                        remoteSignaling.postStatus("answer-sent")
                    } else {
                        self.store.answer = answerJSON
                    }
                    self.store.broadcastStatus = "Connecting"
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
        if let remoteSignaling {
            guard let page = remoteSignaling.fetchBrowserIce(since: browserIceCursor) else { return }
            for record in page.candidates {
                peerConnection.add(RTCIceCandidate(sdp: record.candidate, sdpMLineIndex: record.sdpMLineIndex, sdpMid: record.sdpMid))
            }
            browserIceCursor = page.next
        } else {
            let candidates = store.browserIce
            guard browserIceCursor < candidates.count else { return }
            for record in candidates[browserIceCursor...] {
                peerConnection.add(RTCIceCandidate(sdp: record.candidate, sdpMLineIndex: record.sdpMLineIndex, sdpMid: record.sdpMid))
            }
            browserIceCursor = candidates.count
        }
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
            remoteSignaling?.postSettings(settings)
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
            remoteSignaling?.postSettings(settings)
        }
    }
}

extension WebRTCStreamer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let phase: String
        switch newState {
        case .connected, .completed:
            phase = "Broadcasting"
            remoteSignaling?.postStatus("connected")
        case .checking:
            phase = "Connecting"
            remoteSignaling?.postStatus("ice-checking")
        case .failed:
            phase = "Connection failed"
            remoteSignaling?.postStatus("ice-failed", detail: "Add a TURN server if STUN cannot create a direct route")
        case .disconnected:
            phase = "Disconnected"
            remoteSignaling?.postStatus("disconnected")
        case .closed:
            phase = "Idle"
            remoteSignaling?.postStatus("idle")
        default:
            phase = "Connecting"
        }
        store.broadcastStatus = phase
    }
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
        let record = IceCandidateRecord(candidate: candidate.sdp, sdpMLineIndex: candidate.sdpMLineIndex, sdpMid: candidate.sdpMid)
        if let remoteSignaling {
            remoteSignaling.postBroadcastCandidate(record)
        } else {
            var candidates = store.broadcastIce
            candidates.append(record)
            store.broadcastIce = candidates
        }
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
