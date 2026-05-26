# SwiftCast Protocol

SwiftCast uses WebRTC for connectivity and congestion visibility, but it does not use normal WebRTC media tracks for screen video. Encoded H.264 and audio packets are sent over DataChannels.

## DataChannels

The Chrome client creates these channels before sending its SDP offer:

| Label | Reliability | Purpose |
| --- | --- | --- |
| `video` | `ordered: false`, `maxRetransmits: 0` | H.264 access unit chunks |
| `audio` | `ordered: false`, `maxRetransmits: 0` | Low-latency audio chunks |
| `control` | `ordered: true` | Settings, stats, keyframe requests, ROI commands |

The Broadcast Upload Extension answers the offer and receives these channels through the native WebRTC delegate callbacks.

## Binary Packet Header

All media packets use big-endian integers.

| Offset | Type | Field |
| --- | --- | --- |
| 0 | `uint16` | Magic `0x5343` (`SC`) |
| 2 | `uint8` | Version, currently `1` |
| 3 | `uint8` | Packet type: `1` video, `2` audio |
| 4 | `uint8` | Flags: bit 0 keyframe, bit 1 config, bit 2 ROI |
| 5 | `uint8` | Header length, currently `32` |
| 6 | `uint16` | Stream id |
| 8 | `uint32` | Frame id |
| 12 | `uint64` | Timestamp in microseconds |
| 20 | `uint16` | Chunk index |
| 22 | `uint16` | Chunk count |
| 24 | `uint16` | Codec config version |
| 26 | `uint16` | Reserved |
| 28 | `uint32` | Payload byte length |
| 32 | bytes | Payload |

The browser drops a frame if any chunk is missing or if a newer frame makes it stale. It requests a keyframe after corruption or decoder errors.

## Video Payload

Video payloads are H.264 Annex B bytes. Keyframes include SPS/PPS followed by the IDR access unit so Chrome WebCodecs can recover after loss.

The browser configures `VideoDecoder` with an AVC codec string and `avc.format = "annexb"` where supported.

## Audio Payload

The first implementation transports signed 16-bit little-endian PCM frames at 48 kHz through the `audio` DataChannel and renders them with an `AudioWorklet` ring buffer. This is intentionally low-buffer and robust while AAC/Opus DataChannel encoding is wired in later. The public settings and packet framing are ready for `aac-lc` or `opus` codec negotiation.

## Control Messages

Control messages are JSON over the `control` DataChannel.

```json
{
  "type": "settings",
  "settings": {
    "preset": "gaming",
    "width": 1280,
    "height": 720,
    "fps": 30,
    "dynamicBitrateEnabled": true,
    "minBitrateKbps": 3000,
    "maxBitrateKbps": 8000,
    "temporalCompressionEnabled": true,
    "pFramesEnabled": true,
    "keyframeIntervalMs": 1000,
    "roiEnabled": false,
    "roiMode": "off",
    "appAudioEnabled": true,
    "micAudioEnabled": false,
    "audioSyncOffsetMs": 0,
    "latencyMode": "gaming"
  }
}
```

Other message types:

- `request-keyframe`
- `roi`
- `stats`
- `pong`

## Host App HTTPS Signaling

The iOS app hosts the website over local HTTPS because Chrome exposes WebCodecs `VideoDecoder` only in secure contexts. The app exposes these control endpoints:

- `GET /` serves the Chrome client.
- `GET /assets/...` serves built web assets.
- `GET /api/session` returns pair code, server status, and active settings.
- `POST /api/offer` stores the Chrome SDP offer in the App Group.
- `GET /api/answer` returns the extension SDP answer when available.
- `POST /api/ice/browser` appends Chrome ICE candidates for the extension.
- `GET /api/ice/broadcast?since=N` returns extension ICE candidates for Chrome.
- `GET /api/settings` returns current settings.
- `POST /api/settings` updates settings in the App Group.

These endpoints are control-plane only. No media bytes are sent through HTTP.
