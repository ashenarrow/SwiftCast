declare class AudioWorkletProcessor {
  readonly port: MessagePort;
}
declare function registerProcessor(name: string, processorCtor: new () => AudioWorkletProcessor): void;
declare const sampleRate: number;

class SwiftCastPcmPlayer extends AudioWorkletProcessor {
  private readonly ring = new Float32Array(48000 * 2);
  private writeIndex = 0;
  private readIndex = 0;
  private available = 0;
  private tick = 0;

  constructor() {
    super();
    this.port.onmessage = (event: MessageEvent<{ samples: Float32Array }>) => {
      const samples = event.data.samples;
      for (let i = 0; i < samples.length; i += 1) {
        if (this.available >= this.ring.length) {
          this.readIndex = (this.readIndex + 2) % this.ring.length;
          this.available -= 2;
        }
        this.ring[this.writeIndex] = samples[i];
        this.writeIndex = (this.writeIndex + 1) % this.ring.length;
        this.available += 1;
      }
    };
  }

  process(_inputs: Float32Array[][], outputs: Float32Array[][]): boolean {
    const output = outputs[0];
    const left = output[0];
    const right = output[1] ?? output[0];

    for (let i = 0; i < left.length; i += 1) {
      if (this.available >= 2) {
        left[i] = this.ring[this.readIndex];
        this.readIndex = (this.readIndex + 1) % this.ring.length;
        right[i] = this.ring[this.readIndex];
        this.readIndex = (this.readIndex + 1) % this.ring.length;
        this.available -= 2;
      } else {
        left[i] = 0;
        right[i] = 0;
      }
    }

    this.tick += 1;
    if (this.tick % 24 === 0) {
      this.port.postMessage({ bufferedMs: (this.available / 2 / sampleRate) * 1000 });
    }
    return true;
  }
}

registerProcessor("swiftcast-pcm-player", SwiftCastPcmPlayer);
