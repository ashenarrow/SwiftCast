import { MediaPacket } from "./protocol";

export interface AudioStats {
  packets: number;
  droppedPackets: number;
  bufferedMs: number;
}

export class LowLatencyAudio {
  readonly stats: AudioStats = { packets: 0, droppedPackets: 0, bufferedMs: 0 };
  private context: AudioContext | null = null;
  private node: AudioWorkletNode | null = null;
  private enabled = false;

  async start(): Promise<void> {
    if (this.enabled) return;
    this.context = new AudioContext({ latencyHint: "interactive", sampleRate: 48000 });
    await this.context.audioWorklet.addModule(new URL("./worklets/pcm-player.ts", import.meta.url));
    this.node = new AudioWorkletNode(this.context, "swiftcast-pcm-player", {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [2]
    });
    this.node.port.onmessage = (event: MessageEvent<{ bufferedMs?: number }>) => {
      if (typeof event.data.bufferedMs === "number") this.stats.bufferedMs = event.data.bufferedMs;
    };
    this.node.connect(this.context.destination);
    await this.context.resume();
    this.enabled = true;
  }

  push(packet: MediaPacket): void {
    if (!this.node) {
      this.stats.droppedPackets += 1;
      return;
    }

    const samples = new Int16Array(packet.payload.buffer, packet.payload.byteOffset, Math.floor(packet.payload.byteLength / 2));
    const floatSamples = new Float32Array(samples.length);
    for (let i = 0; i < samples.length; i += 1) {
      floatSamples[i] = Math.max(-1, Math.min(1, samples[i] / 32768));
    }

    this.node.port.postMessage({ samples: floatSamples, timestampUs: packet.timestampUs }, [floatSamples.buffer]);
    this.stats.packets += 1;
  }
}
