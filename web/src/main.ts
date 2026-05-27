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
  <main class="viewer-shell">
    <canvas data-canvas></canvas>

    <button class="menu-button" data-menu aria-label="Open controls">SC</button>

    <section class="hud top-hud">
      <div>
        <strong>SwiftCast</strong>
        <span data-status>Ready</span>
      </div>
      <div class="status-pill" data-status-pill>Pairing</div>
    </section>

    <section class="hud stats-strip">
      <div><span>Peer</span><strong data-peer-state>new</strong></div>
      <div><span>ICE</span><strong data-ice-state>new</strong></div>
      <div><span>RTT</span><strong data-rtt>0 ms</strong></div>
      <div><span>Frames</span><strong data-frames>0</strong></div>
      <div><span>Data</span><strong data-video-rate>0 Mb</strong></div>
      <div><span>Audio</span><strong data-audio-buffer>0 ms</strong></div>
      <div><span>Drops</span><strong data-drops>0</strong></div>
      <div><span>IDR</span><strong data-keyframes>0</strong></div>
    </section>

    <div class="center-message" data-empty>
      <strong>Waiting for broadcast</strong>
      <span>Start the browser peer, then start SwiftCast from the iOS broadcast picker.</span>
    </div>

    <div class="center-message warning" data-unsupported hidden>
      <strong>Chrome with WebCodecs is required.</strong>
      <span>SwiftCast decodes raw H.264 on canvas and intentionally avoids HTML5 video buffering.</span>
    </div>

    <aside class="drawer" data-drawer>
      <div class="drawer-header">
        <div>
          <h1>SwiftCast</h1>
          <p>Canvas-first gaming mirror</p>
        </div>
        <button data-close aria-label="Close controls">Close</button>
      </div>

      <section class="panel status-panel">
        <div>
          <span>Pair code</span>
          <strong data-pair>Loading</strong>
        </div>
        <small data-mode>Local or tunnel</small>
      </section>

      <section class="panel action-grid">
        <button class="primary" data-start>Start peer</button>
        <button data-audio>Enable audio</button>
        <button data-keyframe>Keyframe</button>
        <button data-fullscreen>Fullscreen</button>
      </section>

      <section class="panel">
        <h2>Viewer</h2>
        <label class="check"><input data-show-stats type="checkbox" checked /> Show stats</label>
        <label>Canvas fit <select data-fit>
          <option value="contain">Contain</option>
          <option value="cover">Fill screen</option>
        </select></label>
        <label>Audio sync offset <input data-sync type="number" min="-250" max="250" step="5" /></label>
      </section>

      <section class="panel">
        <h2>Live Stream Requests</h2>
        <label>ROI mode <select data-roi-mode>
          <option value="off">Off</option>
          <option value="manual">Manual</option>
          <option value="motion">Motion</option>
          <option value="touch">Touch centered</option>
          <option value="center">Center weighted</option>
        </select></label>
        <label class="check"><input data-roi-enabled type="checkbox" /> Enable ROI overlay</label>
        <label class="check"><input data-gaming type="checkbox" checked /> Gaming latency mode</label>
      </section>

      <section class="panel subtle">
        <h2>Capture Settings Live In iOS</h2>
        <p>Resolution, FPS, bitrate range, temporal compression, P-frames, audio sources, gains, and encoder limits are controlled in the SwiftCast iOS app so the broadcast extension can load them before capture starts.</p>
      </section>
    </aside>
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
const statusPill = $<HTMLElement>("[data-status-pill]");
const pairText = $<HTMLElement>("[data-pair]");
const modeText = $<HTMLElement>("[data-mode]");
const empty = $<HTMLElement>("[data-empty]");
const unsupported = $<HTMLElement>("[data-unsupported]");
const drawer = $<HTMLElement>("[data-drawer]");
const statsStrip = $<HTMLElement>("[data-stats-strip], .stats-strip");

const video = new CanvasVideoDecoder(canvas, () => peer?.requestKeyframe("decoder"));

function setStatus(text: string, live = false): void {
  statusText.textContent = text;
  statusPill.textContent = live ? "Live" : "Pairing";
  statusPill.classList.toggle("live", live);
}

function bindViewerSettings(): void {
  const fit = $<HTMLSelectElement>("[data-fit]");
  const showStats = $<HTMLInputElement>("[data-show-stats]");
  const sync = $<HTMLInputElement>("[data-sync]");
  const roiEnabled = $<HTMLInputElement>("[data-roi-enabled]");
  const roiMode = $<HTMLSelectElement>("[data-roi-mode]");
  const gaming = $<HTMLInputElement>("[data-gaming]");

  const render = () => {
    sync.value = String(settings.audioSyncOffsetMs);
    roiEnabled.checked = settings.roiEnabled;
    roiMode.value = settings.roiMode;
    gaming.checked = settings.latencyMode === "gaming";
  };

  const update = () => {
    canvas.style.objectFit = fit.value;
    statsStrip.hidden = !showStats.checked;
    settings = {
      ...settings,
      audioSyncOffsetMs: Number(sync.value),
      roiEnabled: roiEnabled.checked,
      roiMode: roiMode.value as SwiftCastSettings["roiMode"],
      latencyMode: gaming.checked ? "gaming" : "balanced"
    };
    peer?.sendSettings(settings);
  };

  app.querySelectorAll("input, select").forEach((element) => element.addEventListener("input", update));
  render();
  update();
}

async function boot(): Promise<void> {
  if (!isChromeWithWebCodecs()) {
    unsupported.hidden = false;
  }
  const session = await signaling.getSession();
  settings = { ...defaultSettings, ...session.settings };
  pairText.textContent = session.pairCode;
  modeText.textContent = session.mode === "tunnel" ? "Railway tunnel signaling" : "Local app signaling";
  bindViewerSettings();
  setStatus("Ready");
}

$<HTMLButtonElement>("[data-menu]").addEventListener("click", () => drawer.classList.add("open"));
$<HTMLButtonElement>("[data-close]").addEventListener("click", () => drawer.classList.remove("open"));

$<HTMLButtonElement>("[data-start]").addEventListener("click", async () => {
  peer?.stop();
  peer = new SwiftCastPeer(signaling, video, audio, (status) => setStatus(status, status.includes("connected")));
  await peer.start(settings);
  empty.hidden = true;
  drawer.classList.remove("open");
});

$<HTMLButtonElement>("[data-audio]").addEventListener("click", async () => {
  await audio.start();
  setStatus("AudioWorklet ready");
});

$<HTMLButtonElement>("[data-keyframe]").addEventListener("click", () => {
  peer?.requestKeyframe("user");
});

$<HTMLButtonElement>("[data-fullscreen]").addEventListener("click", () => {
  void document.documentElement.requestFullscreen?.();
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
