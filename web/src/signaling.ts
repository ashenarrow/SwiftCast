import { defaultSettings, SwiftCastSettings } from "./protocol";

export interface SessionInfo {
  pairCode: string;
  settings: SwiftCastSettings;
  status?: RoomStatus;
  mode?: "local" | "tunnel";
}

export interface RoomStatus {
  phase?: string;
  detail?: string;
  hasOffer?: boolean;
  hasAnswer?: boolean;
  browserIce?: number;
  broadcastIce?: number;
  updatedAt?: number;
}

export class SignalingClient {
  private readonly pairCode: string | null;
  private readonly roomPrefix: string | null;

  constructor(private readonly baseUrl = window.location.origin) {
    const params = new URLSearchParams(window.location.search);
    this.pairCode = params.get("pair")?.trim() || window.localStorage.getItem("swiftcast.pairCode");
    this.roomPrefix = this.pairCode ? `/api/rooms/${encodeURIComponent(this.pairCode)}` : null;
    if (this.pairCode) window.localStorage.setItem("swiftcast.pairCode", this.pairCode);
  }

  async getSession(): Promise<SessionInfo> {
    const path = this.roomPrefix ? `${this.roomPrefix}/session` : "/api/session";
    const response = await fetch(`${this.baseUrl}${path}`, { cache: "no-store" });
    if (!response.ok) {
      return { pairCode: this.pairCode ?? "DEV", settings: defaultSettings };
    }
    const session = await response.json();
    return { ...session, pairCode: session.pairCode ?? this.pairCode ?? "DEV" };
  }

  async sendOffer(description: RTCSessionDescriptionInit): Promise<void> {
    await this.post(this.path("offer"), description);
  }

  async getAnswer(): Promise<RTCSessionDescriptionInit | null> {
    const response = await fetch(`${this.baseUrl}${this.path("answer")}`, { cache: "no-store" });
    if (response.status === 404 || response.status === 204) return null;
    if (!response.ok) throw new Error(`answer poll failed: ${response.status}`);
    return response.json();
  }

  async sendBrowserCandidate(candidate: RTCIceCandidate): Promise<void> {
    await this.post(this.path("ice/browser"), candidate.toJSON());
  }

  async getBroadcastCandidates(since: number): Promise<{ next: number; candidates: RTCIceCandidateInit[] }> {
    const response = await fetch(`${this.baseUrl}${this.path("ice/broadcast")}?since=${since}`, { cache: "no-store" });
    if (!response.ok) return { next: since, candidates: [] };
    return response.json();
  }

  async updateSettings(settings: SwiftCastSettings): Promise<void> {
    await this.post(this.path("settings"), settings);
  }

  async getStatus(): Promise<RoomStatus | null> {
    const response = await fetch(`${this.baseUrl}${this.path("status")}`, { cache: "no-store" });
    if (!response.ok) return null;
    return response.json();
  }

  async updateStatus(status: RoomStatus): Promise<void> {
    await this.post(this.path("status"), status);
  }

  private path(name: string): string {
    return this.roomPrefix ? `${this.roomPrefix}/${name}` : `/api/${name}`;
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
