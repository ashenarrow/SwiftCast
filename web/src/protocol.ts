export const PACKET_MAGIC = 0x5343;
export const PACKET_VERSION = 1;
export const HEADER_LENGTH = 32;

export enum PacketType {
  Video = 1,
  Audio = 2
}

export enum PacketFlag {
  Keyframe = 1 << 0,
  Config = 1 << 1,
  ROI = 1 << 2
}

export interface MediaPacket {
  type: PacketType;
  flags: number;
  streamId: number;
  frameId: number;
  timestampUs: number;
  chunkIndex: number;
  chunkCount: number;
  configVersion: number;
  payload: Uint8Array;
}

export interface SwiftCastSettings {
  preset: "gaming" | "hotspot" | "battery" | "custom";
  width: number;
  height: number;
  fps: number;
  dynamicBitrateEnabled: boolean;
  minBitrateKbps: number;
  maxBitrateKbps: number;
  congestionAggressiveness: number;
  temporalCompressionEnabled: boolean;
  pFramesEnabled: boolean;
  keyframeIntervalMs: number;
  roiEnabled: boolean;
  roiMode: "off" | "manual" | "motion" | "touch" | "center";
  roiRect: { x: number; y: number; width: number; height: number };
  appAudioEnabled: boolean;
  micAudioEnabled: boolean;
  appAudioGain: number;
  micGain: number;
  audioSyncOffsetMs: number;
  latencyMode: "gaming" | "balanced";
}

export const defaultSettings: SwiftCastSettings = {
  preset: "gaming",
  width: 1280,
  height: 720,
  fps: 30,
  dynamicBitrateEnabled: true,
  minBitrateKbps: 3000,
  maxBitrateKbps: 8000,
  congestionAggressiveness: 0.72,
  temporalCompressionEnabled: true,
  pFramesEnabled: true,
  keyframeIntervalMs: 1000,
  roiEnabled: false,
  roiMode: "off",
  roiRect: { x: 0.35, y: 0.3, width: 0.3, height: 0.3 },
  appAudioEnabled: true,
  micAudioEnabled: false,
  appAudioGain: 1,
  micGain: 1,
  audioSyncOffsetMs: 0,
  latencyMode: "gaming"
};

export function parseMediaPacket(data: ArrayBuffer): MediaPacket | null {
  if (data.byteLength < HEADER_LENGTH) return null;
  const view = new DataView(data);
  if (view.getUint16(0, false) !== PACKET_MAGIC) return null;
  if (view.getUint8(2) !== PACKET_VERSION) return null;

  const headerLength = view.getUint8(5);
  if (headerLength < HEADER_LENGTH || data.byteLength < headerLength) return null;

  const payloadLength = view.getUint32(28, false);
  if (data.byteLength < headerLength + payloadLength) return null;

  return {
    type: view.getUint8(3) as PacketType,
    flags: view.getUint8(4),
    streamId: view.getUint16(6, false),
    frameId: view.getUint32(8, false),
    timestampUs: Number(view.getBigUint64(12, false)),
    chunkIndex: view.getUint16(20, false),
    chunkCount: view.getUint16(22, false),
    configVersion: view.getUint16(24, false),
    payload: new Uint8Array(data, headerLength, payloadLength)
  };
}

export function isKeyframe(packet: MediaPacket): boolean {
  return (packet.flags & PacketFlag.Keyframe) !== 0;
}

