import { CompleteFrame } from "./assemblers";
import { PacketFlag } from "./protocol";

declare global {
  interface Window {
    VideoDecoder?: typeof VideoDecoder;
  }
}

export interface VideoStats {
  decodedFrames: number;
  droppedFrames: number;
  decoderErrors: number;
  lastDecodeMs: number;
  queueDepth: number;
  lastFrameLatencyMs: number;
}

export class CanvasVideoDecoder {
  readonly stats: VideoStats = {
    decodedFrames: 0,
    droppedFrames: 0,
    decoderErrors: 0,
    lastDecodeMs: 0,
    queueDepth: 0,
    lastFrameLatencyMs: 0
  };

  private decoder: VideoDecoder | null = null;
  private configuredVersion = -1;
  private readonly ctx: CanvasRenderingContext2D;

  constructor(
    private readonly canvas: HTMLCanvasElement,
    private readonly onNeedKeyframe: () => void
  ) {
    const ctx = canvas.getContext("2d", { alpha: false, desynchronized: true });
    if (!ctx) throw new Error("Canvas 2D unavailable");
    this.ctx = ctx;
  }

  configure(configVersion: number): void {
    if (this.configuredVersion === configVersion && this.decoder) return;
    this.decoder?.close();
    this.decoder = new VideoDecoder({
      output: (frame) => this.render(frame),
      error: () => {
        this.stats.decoderErrors += 1;
        this.onNeedKeyframe();
      }
    });

    const config: VideoDecoderConfig = {
      codec: "avc1.42E01F",
      optimizeForLatency: true
    };
    (config as any).avc = { format: "annexb" };
    this.decoder.configure(config);
    this.configuredVersion = configVersion;
  }

  decode(frame: CompleteFrame): void {
    const keyframe = (frame.flags & PacketFlag.Keyframe) !== 0;
    if (!keyframe && !this.decoder) {
      this.stats.droppedFrames += 1;
      this.onNeedKeyframe();
      return;
    }

    this.configure(frame.configVersion);
    if (!this.decoder) return;

    const start = performance.now();
    try {
      this.decoder.decode(
        new EncodedVideoChunk({
          type: keyframe ? "key" : "delta",
          timestamp: frame.timestampUs,
          data: frame.data
        })
      );
      this.stats.lastDecodeMs = performance.now() - start;
      this.stats.queueDepth = this.decoder.decodeQueueSize;
    } catch {
      this.stats.droppedFrames += 1;
      this.onNeedKeyframe();
    }
  }

  private render(frame: VideoFrame): void {
    if (this.canvas.width !== frame.displayWidth || this.canvas.height !== frame.displayHeight) {
      this.canvas.width = frame.displayWidth;
      this.canvas.height = frame.displayHeight;
    }

    this.ctx.drawImage(frame, 0, 0, this.canvas.width, this.canvas.height);
    this.stats.lastFrameLatencyMs = Math.max(0, performance.now() - frame.timestamp / 1000);
    this.stats.decodedFrames += 1;
    frame.close();
  }
}

