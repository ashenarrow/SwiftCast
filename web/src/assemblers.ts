import { MediaPacket, PacketFlag } from "./protocol";

interface PendingFrame {
  createdAt: number;
  timestampUs: number;
  flags: number;
  configVersion: number;
  chunks: Array<Uint8Array | undefined>;
  received: number;
  totalBytes: number;
}

export interface CompleteFrame {
  frameId: number;
  timestampUs: number;
  flags: number;
  configVersion: number;
  data: Uint8Array;
}

export class ChunkAssembler {
  private readonly pending = new Map<number, PendingFrame>();
  private newestFrameId = 0;

  constructor(private readonly staleAfterMs = 90) {}

  push(packet: MediaPacket): CompleteFrame | null {
    this.newestFrameId = Math.max(this.newestFrameId, packet.frameId);
    this.sweep();

    if (packet.frameId + 2 < this.newestFrameId) {
      return null;
    }

    let frame = this.pending.get(packet.frameId);
    if (!frame) {
      frame = {
        createdAt: performance.now(),
        timestampUs: packet.timestampUs,
        flags: packet.flags,
        configVersion: packet.configVersion,
        chunks: new Array(packet.chunkCount),
        received: 0,
        totalBytes: 0
      };
      this.pending.set(packet.frameId, frame);
    }

    if (packet.chunkIndex >= frame.chunks.length || frame.chunks[packet.chunkIndex]) {
      return null;
    }

    frame.chunks[packet.chunkIndex] = packet.payload;
    frame.received += 1;
    frame.totalBytes += packet.payload.byteLength;

    if (frame.received !== frame.chunks.length) {
      return null;
    }

    const data = new Uint8Array(frame.totalBytes);
    let offset = 0;
    for (const chunk of frame.chunks) {
      if (!chunk) return null;
      data.set(chunk, offset);
      offset += chunk.byteLength;
    }

    this.pending.delete(packet.frameId);
    return {
      frameId: packet.frameId,
      timestampUs: frame.timestampUs,
      flags: frame.flags,
      configVersion: frame.configVersion,
      data
    };
  }

  clearDeltaFrames(): void {
    for (const [frameId, frame] of this.pending) {
      if ((frame.flags & PacketFlag.Keyframe) === 0) {
        this.pending.delete(frameId);
      }
    }
  }

  private sweep(): void {
    const now = performance.now();
    for (const [frameId, frame] of this.pending) {
      if (now - frame.createdAt > this.staleAfterMs || frameId + 4 < this.newestFrameId) {
        this.pending.delete(frameId);
      }
    }
  }
}

