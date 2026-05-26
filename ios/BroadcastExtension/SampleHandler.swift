import CoreMedia
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
    private let store = AppGroupStore.shared
    private var streamer: WebRTCStreamer?
    private var encoder: H264Encoder?
    private let audioEncoder = PCM16AudioEncoder()
    private var lastVideoTime = CMTime.invalid
    private var frameId: UInt32 = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let settings = store.settings
        let streamer = WebRTCStreamer(store: store)
        self.streamer = streamer
        self.encoder = H264Encoder(settings: settings) { [weak self] frame in
            self?.streamer?.sendVideo(frame)
        }
        streamer.start()
    }

    override func broadcastFinished() {
        streamer?.stop()
        encoder?.invalidate()
        streamer = nil
        encoder = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        let settings = store.settings
        encoder?.update(settings: settings)

        switch sampleBufferType {
        case .video:
            guard shouldAcceptVideo(sampleBuffer, fps: settings.fps) else { return }
            encoder?.encode(sampleBuffer: sampleBuffer, forceKeyframe: streamer?.takeKeyframeRequest() == true)
        case .audioApp:
            guard settings.appAudioEnabled,
                  let packet = audioEncoder.encode(sampleBuffer: sampleBuffer, streamId: 2) else { return }
            streamer?.sendAudio(packet)
        case .audioMic:
            guard settings.micAudioEnabled,
                  let packet = audioEncoder.encode(sampleBuffer: sampleBuffer, streamId: 3) else { return }
            streamer?.sendAudio(packet)
        @unknown default:
            break
        }
    }

    private func shouldAcceptVideo(_ sampleBuffer: CMSampleBuffer, fps: Int) -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        defer { lastVideoTime = pts }
        guard lastVideoTime.isValid else { return true }
        let minDelta = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        return pts - lastVideoTime >= minDelta
    }

    func nextFrameId() -> UInt32 {
        frameId &+= 1
        return frameId
    }
}

