import { ChunkAssembler } from "./assemblers";
import { LowLatencyAudio } from "./audio";
import { CanvasVideoDecoder } from "./decoder";
import { parseMediaPacket, PacketType, SwiftCastSettings } from "./protocol";
import { SignalingClient } from "./signaling";

export interface ConnectionStats {
  state: RTCPeerConnectionState;
  iceState: RTCIceConnectionState;
  videoBytes: number;
  audioBytes: number;
  videoPackets: number;
  audioPackets: number;
  keyframes: number;
  requestedKeyframes: number;
  rttMs: number;
}

export class SwiftCastPeer {
  readonly stats: ConnectionStats = {
    state: "new",
    iceState: "new",
    videoBytes: 0,
    audioBytes: 0,
    videoPackets: 0,
    audioPackets: 0,
    keyframes: 0,
    requestedKeyframes: 0,
    rttMs: 0
  };

  private readonly pc = new RTCPeerConnection({
    iceServers: [
      { urls: ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"] }
    ]
  });
  private readonly videoChannel = this.pc.createDataChannel("video", { ordered: false, maxRetransmits: 0 });
  private readonly audioChannel = this.pc.createDataChannel("audio", { ordered: false, maxRetransmits: 0 });
  private readonly controlChannel = this.pc.createDataChannel("control", { ordered: true });
  private readonly assembler = new ChunkAssembler();
  private broadcastIceCursor = 0;
  private pollTimer = 0;
  private statsTimer = 0;

  constructor(
    private readonly signaling: SignalingClient,
    private readonly video: CanvasVideoDecoder,
    private readonly audio: LowLatencyAudio,
    private readonly onStatus: (status: string) => void
  ) {
    this.videoChannel.binaryType = "arraybuffer";
    this.audioChannel.binaryType = "arraybuffer";
    this.videoChannel.onmessage = (event) => this.handleVideo(event.data);
    this.audioChannel.onmessage = (event) => this.handleAudio(event.data);
    this.controlChannel.onopen = () => this.onStatus("Control channel ready");
    this.controlChannel.onmessage = (event) => this.handleControl(event.data);
    this.pc.onconnectionstatechange = () => {
      this.stats.state = this.pc.connectionState;
      this.onStatus(`Peer ${this.pc.connectionState}`);
    };
    this.pc.oniceconnectionstatechange = () => {
      this.stats.iceState = this.pc.iceConnectionState;
    };
    this.pc.onicecandidate = (event) => {
      if (event.candidate) void this.signaling.sendBrowserCandidate(event.candidate);
    };
  }

  async start(settings: SwiftCastSettings): Promise<void> {
    this.onStatus("Creating Chrome WebRTC offer");
    const offer = await this.pc.createOffer();
    await this.pc.setLocalDescription(offer);
    await this.signaling.sendOffer(offer);
    this.sendSettings(settings);
    this.onStatus("Waiting for iPhone broadcast answer");

    this.pollTimer = window.setInterval(() => void this.pollAnswerAndIce(), 350);
    this.statsTimer = window.setInterval(() => void this.collectStats(), 1000);
  }

  sendSettings(settings: SwiftCastSettings): void {
    const message = JSON.stringify({ type: "settings", settings });
    if (this.controlChannel.readyState === "open") {
      this.controlChannel.send(message);
    }
    void this.signaling.updateSettings(settings);
  }

  requestKeyframe(reason = "browser"): void {
    this.stats.requestedKeyframes += 1;
    this.assembler.clearDeltaFrames();
    if (this.controlChannel.readyState === "open") {
      this.controlChannel.send(JSON.stringify({ type: "request-keyframe", reason, at: performance.now() }));
    }
  }

  stop(): void {
    window.clearInterval(this.pollTimer);
    window.clearInterval(this.statsTimer);
    this.pc.close();
  }

  private async pollAnswerAndIce(): Promise<void> {
    if (!this.pc.remoteDescription) {
      const answer = await this.signaling.getAnswer();
      if (answer) {
        await this.pc.setRemoteDescription(answer);
        this.onStatus("Broadcast answer received");
      }
    }

    const { next, candidates } = await this.signaling.getBroadcastCandidates(this.broadcastIceCursor);
    this.broadcastIceCursor = next;
    for (const candidate of candidates) {
      await this.pc.addIceCandidate(candidate);
    }
  }

  private handleVideo(data: unknown): void {
    if (!(data instanceof ArrayBuffer)) return;
    const packet = parseMediaPacket(data);
    if (!packet || packet.type !== PacketType.Video) return;
    this.stats.videoBytes += data.byteLength;
    this.stats.videoPackets += 1;
    if ((packet.flags & 1) !== 0) this.stats.keyframes += 1;

    const frame = this.assembler.push(packet);
    if (frame) this.video.decode(frame);
  }

  private handleAudio(data: unknown): void {
    if (!(data instanceof ArrayBuffer)) return;
    const packet = parseMediaPacket(data);
    if (!packet || packet.type !== PacketType.Audio) return;
    this.stats.audioBytes += data.byteLength;
    this.stats.audioPackets += 1;
    this.audio.push(packet);
  }

  private handleControl(data: unknown): void {
    if (typeof data !== "string") return;
    try {
      const message = JSON.parse(data);
      if (message.type === "need-keyframe") this.requestKeyframe("native-request");
    } catch {
      // Ignore malformed control messages.
    }
  }

  private async collectStats(): Promise<void> {
    const report = await this.pc.getStats();
    report.forEach((item) => {
      if (item.type === "candidate-pair" && item.state === "succeeded" && typeof item.currentRoundTripTime === "number") {
        this.stats.rttMs = item.currentRoundTripTime * 1000;
      }
    });
    if (this.controlChannel.readyState === "open") {
      this.controlChannel.send(JSON.stringify({
        type: "stats",
        rttMs: this.stats.rttMs,
        videoPackets: this.stats.videoPackets,
        audioPackets: this.stats.audioPackets,
        requestedKeyframes: this.stats.requestedKeyframes
      }));
    }
  }
}
