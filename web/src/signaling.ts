import { defaultSettings, SwiftCastSettings } from "./protocol";

export interface SessionInfo {
  pairCode: string;
  settings: SwiftCastSettings;
}

export class SignalingClient {
  constructor(private readonly baseUrl = window.location.origin) {}

  async getSession(): Promise<SessionInfo> {
    const response = await fetch(`${this.baseUrl}/api/session`, { cache: "no-store" });
    if (!response.ok) {
      return { pairCode: "DEV", settings: defaultSettings };
    }
    return response.json();
  }

  async sendOffer(description: RTCSessionDescriptionInit): Promise<void> {
    await this.post("/api/offer", description);
  }

  async getAnswer(): Promise<RTCSessionDescriptionInit | null> {
    const response = await fetch(`${this.baseUrl}/api/answer`, { cache: "no-store" });
    if (response.status === 404 || response.status === 204) return null;
    if (!response.ok) throw new Error(`answer poll failed: ${response.status}`);
    return response.json();
  }

  async sendBrowserCandidate(candidate: RTCIceCandidate): Promise<void> {
    await this.post("/api/ice/browser", candidate.toJSON());
  }

  async getBroadcastCandidates(since: number): Promise<{ next: number; candidates: RTCIceCandidateInit[] }> {
    const response = await fetch(`${this.baseUrl}/api/ice/broadcast?since=${since}`, { cache: "no-store" });
    if (!response.ok) return { next: since, candidates: [] };
    return response.json();
  }

  async updateSettings(settings: SwiftCastSettings): Promise<void> {
    await this.post("/api/settings", settings);
  }

  private async post(path: string, body: unknown): Promise<void> {
    const response = await fetch(`${this.baseUrl}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body)
    });
    if (!response.ok) throw new Error(`${path} failed: ${response.status}`);
  }
}

