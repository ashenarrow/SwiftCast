import "./styles.css";
import { LowLatencyAudio } from "./audio";
import { CanvasVideoDecoder } from "./decoder";
import { defaultSettings, SwiftCastSettings } from "./protocol";
import { SwiftCastPeer } from "./rtc";
import { SignalingClient } from "./signaling";

function isChromeWithWebCodecs(): boolean {
  const ua = navigator.userAgent;
  return /Chrome\//.test(ua) && !/Edg\//.test(ua) && "VideoDecoder" in window && "AudioWorkletNode" in window;
}

const appRoot = document.querySelector<HTMLDivElement>("#app");
if (!appRoot) throw new Error("missing app root");
const app = appRoot;

app.innerHTML = `
  <main class="shell">
    <aside class="sidebar">
      <div class="brand">
        <div class="brand-mark">SC</div>
        <div>
          <h1>SwiftCast</h1>
          <p>WebCodecs gaming mirror</p>
        </div>
      </div>

      <section class="panel status-panel">
        <div class="status-dot" data-status-dot></div>
        <div>
          <strong data-status>Ready</strong>
          <span data-pair>Pair code loading</span>
        </div>
      </section>

      <section class="panel controls">
        <button class="primary" data-start>Start browser peer</button>
        <button data-audio>Enable audio</button>
        <button data-keyframe>Request keyframe</button>
      </section>

      <section class="panel">
        <h2>Gaming Stream</h2>
        <label>Resolution <select data-preset>
          <option value="gaming">1280x720 / 30 fps</option>
          <option value="hotspot">960x540 / 30 fps</option>
          <option value="battery">854x480 / 20 fps</option>
        </select></label>
        <label>Min bitrate <input data-min-bitrate type="range" min="500" max="8000" step="250" /></label>
        <label>Max bitrate <input data-max-bitrate type="range" min="1000" max="12000" step="250" /></label>
        <label class="check"><input data-dynamic type="checkbox" /> Dynamic bitrate</label>
        <label class="check"><input data-temporal type="checkbox" /> Temporal compression</label>
        <label class="check"><input data-pframes type="checkbox" /> P-frames</label>
        <label>Keyframe interval <input data-keyint type="number" min="250" max="5000" step="250" /></label>
      </section>

      <section class="panel">
        <h2>ROI</h2>
        <label class="check"><input data-roi-enabled type="checkbox" /> Enable ROI</label>
        <label>Mode <select data-roi-mode>
          <option value="off">Off</option>
          <option value="manual">Manual</option>
          <option value="motion">Motion</option>
          <option value="touch">Touch centered</option>
          <option value="center">Center weighted</option>
        </select></label>
      </section>

      <section class="panel">
        <h2>Audio</h2>
        <label class="check"><input data-app-audio type="checkbox" /> App audio</label>
        <label class="check"><input data-mic-audio type="checkbox" /> Mic</label>
        <label>Sync offset <input data-sync type="number" min="-250" max="250" step="5" /></label>
      </section>
    </aside>

    <section class="stage">
      <div class="stage-topbar">
        <div>
          <strong>Canvas decoder</strong>
          <span>No video tag. No media track.</span>
        </div>
        <div class="badges">
          <span>Chrome</span>
          <span>WebRTC DC</span>
          <span>H.264 Annex B</span>
        </div>
      </div>
      <div class="viewer">
        <canvas data-canvas></canvas>
        <div class="unsupported" data-unsupported hidden>
          <strong>Chrome with WebCodecs is required.</strong>
          <span>SwiftCast intentionally avoids HTML5 video buffering and decodes raw H.264 directly to canvas.</span>
        </div>
        <div class="empty" data-empty>
          <strong>Waiting for iPhone broadcast</strong>
          <span>Start the browser peer, then start SwiftCast from the iOS screen broadcast picker.</span>
        </div>
      </div>
      <div class="stats">
        <div><span>Peer</span><strong data-peer-state>new</strong></div>
        <div><span>ICE</span><strong data-ice-state>new</strong></div>
        <div><span>RTT</span><strong data-rtt>0 ms</strong></div>
        <div><span>Frames</span><strong data-frames>0</strong></div>
        <div><span>Video</span><strong data-video-rate>0 Mbps</strong></div>
        <div><span>Audio buffer</span><strong data-audio-buffer>0 ms</strong></div>
        <div><span>Drops</span><strong data-drops>0</strong></div>
        <div><span>Keyframes</span><strong data-keyframes>0</strong></div>
      </div>
    </section>
  </main>
`;

const $ = <T extends Element>(selector: string) => {
  const element = app.querySelector<T>(selector);
  if (!element) throw new Error(`missing ${selector}`);
  return element;
};

let settings: SwiftCastSettings = { ...defaultSettings };
let peer: SwiftCastPeer | null = null;
const signaling = new SignalingClient();
const audio = new LowLatencyAudio();
const canvas = $<HTMLCanvasElement>("[data-canvas]");
const statusText = $<HTMLElement>("[data-status]");
const statusDot = $<HTMLElement>("[data-status-dot]");
const pairText = $<HTMLElement>("[data-pair]");
const empty = $<HTMLElement>("[data-empty]");
const unsupported = $<HTMLElement>("[data-unsupported]");

const video = new CanvasVideoDecoder(canvas, () => peer?.requestKeyframe("decoder"));

function setStatus(text: string, live = false): void {
  statusText.textContent = text;
  statusDot.classList.toggle("live", live);
}

function bindSettings(): void {
  const preset = $<HTMLSelectElement>("[data-preset]");
  const minBitrate = $<HTMLInputElement>("[data-min-bitrate]");
  const maxBitrate = $<HTMLInputElement>("[data-max-bitrate]");
  const dynamic = $<HTMLInputElement>("[data-dynamic]");
  const temporal = $<HTMLInputElement>("[data-temporal]");
  const pframes = $<HTMLInputElement>("[data-pframes]");
  const keyint = $<HTMLInputElement>("[data-keyint]");
  const roiEnabled = $<HTMLInputElement>("[data-roi-enabled]");
  const roiMode = $<HTMLSelectElement>("[data-roi-mode]");
  const appAudio = $<HTMLInputElement>("[data-app-audio]");
  const micAudio = $<HTMLInputElement>("[data-mic-audio]");
  const sync = $<HTMLInputElement>("[data-sync]");

  const render = () => {
    preset.value = settings.preset;
    minBitrate.value = String(settings.minBitrateKbps);
    maxBitrate.value = String(settings.maxBitrateKbps);
    dynamic.checked = settings.dynamicBitrateEnabled;
    temporal.checked = settings.temporalCompressionEnabled;
    pframes.checked = settings.pFramesEnabled;
    keyint.value = String(settings.keyframeIntervalMs);
    roiEnabled.checked = settings.roiEnabled;
    roiMode.value = settings.roiMode;
    appAudio.checked = settings.appAudioEnabled;
    micAudio.checked = settings.micAudioEnabled;
    sync.value = String(settings.audioSyncOffsetMs);
  };

  const update = () => {
    settings = {
      ...settings,
      preset: preset.value as SwiftCastSettings["preset"],
      minBitrateKbps: Number(minBitrate.value),
      maxBitrateKbps: Number(maxBitrate.value),
      dynamicBitrateEnabled: dynamic.checked,
      temporalCompressionEnabled: temporal.checked,
      pFramesEnabled: pframes.checked,
      keyframeIntervalMs: Number(keyint.value),
      roiEnabled: roiEnabled.checked,
      roiMode: roiMode.value as SwiftCastSettings["roiMode"],
      appAudioEnabled: appAudio.checked,
      micAudioEnabled: micAudio.checked,
      audioSyncOffsetMs: Number(sync.value)
    };

    if (settings.preset === "hotspot") Object.assign(settings, { width: 960, height: 540, fps: 30 });
    if (settings.preset === "battery") Object.assign(settings, { width: 854, height: 480, fps: 20 });
    if (settings.preset === "gaming") Object.assign(settings, { width: 1280, height: 720, fps: 30 });
    peer?.sendSettings(settings);
  };

  app.querySelectorAll("input, select").forEach((element) => element.addEventListener("input", update));
  render();
}

async function boot(): Promise<void> {
  if (!isChromeWithWebCodecs()) {
    unsupported.hidden = false;
  }
  const session = await signaling.getSession();
  settings = { ...defaultSettings, ...session.settings };
  pairText.textContent = `Pair code ${session.pairCode}`;
  bindSettings();
  setStatus("Ready");
}

$<HTMLButtonElement>("[data-start]").addEventListener("click", async () => {
  peer?.stop();
  peer = new SwiftCastPeer(signaling, video, audio, (status) => setStatus(status, status.includes("connected")));
  await peer.start(settings);
  empty.hidden = true;
});

$<HTMLButtonElement>("[data-audio]").addEventListener("click", async () => {
  await audio.start();
  setStatus("AudioWorklet ready");
});

$<HTMLButtonElement>("[data-keyframe]").addEventListener("click", () => {
  peer?.requestKeyframe("user");
});

window.setInterval(() => {
  if (!peer) return;
  $<HTMLElement>("[data-peer-state]").textContent = peer.stats.state;
  $<HTMLElement>("[data-ice-state]").textContent = peer.stats.iceState;
  $<HTMLElement>("[data-rtt]").textContent = `${peer.stats.rttMs.toFixed(0)} ms`;
  $<HTMLElement>("[data-frames]").textContent = String(video.stats.decodedFrames);
  $<HTMLElement>("[data-drops]").textContent = String(video.stats.droppedFrames);
  $<HTMLElement>("[data-keyframes]").textContent = String(peer.stats.keyframes);
  $<HTMLElement>("[data-audio-buffer]").textContent = `${audio.stats.bufferedMs.toFixed(0)} ms`;
  $<HTMLElement>("[data-video-rate]").textContent = `${((peer.stats.videoBytes * 8) / 1_000_000).toFixed(1)} Mb`;
}, 500);

void boot();
