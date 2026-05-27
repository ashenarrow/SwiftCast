import express, { Request, Response } from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";

type JsonObject = Record<string, unknown>;

interface Room {
  pairCode: string;
  createdAt: number;
  updatedAt: number;
  offer: JsonObject | null;
  answer: JsonObject | null;
  settings: JsonObject;
  browserIce: JsonObject[];
  broadcastIce: JsonObject[];
}

const app = express();
const rooms = new Map<string, Room>();
const ttlMs = Number(process.env.SWIFTCAST_SESSION_TTL_MS ?? 10 * 60 * 1000);
const bodyLimit = process.env.SWIFTCAST_MAX_BODY_BYTES ?? "1mb";
const defaultDomain = process.env.SWIFTCAST_PUBLIC_URL ?? "https://swiftcast-production.up.railway.app";

app.disable("x-powered-by");
app.use(express.json({ limit: bodyLimit }));

function now(): number {
  return Date.now();
}

function cleanPairCode(value: string): string | null {
  const trimmed = value.trim();
  if (!/^[A-Za-z0-9_-]{3,32}$/.test(trimmed)) return null;
  return trimmed;
}

function getRoom(req: Request, res: Response): Room | null {
  const rawPair = Array.isArray(req.params.pair) ? req.params.pair[0] : req.params.pair;
  const pairCode = cleanPairCode(rawPair ?? "");
  if (!pairCode) {
    res.status(400).json({ error: "invalid_pair_code" });
    return null;
  }

  let room = rooms.get(pairCode);
  if (!room) {
    room = {
      pairCode,
      createdAt: now(),
      updatedAt: now(),
      offer: null,
      answer: null,
      settings: {},
      browserIce: [],
      broadcastIce: []
    };
    rooms.set(pairCode, room);
  }

  room.updatedAt = now();
  return room;
}

function postJson(pathName: string, arrayName: "browserIce" | "broadcastIce") {
  app.post(pathName, (req, res) => {
    const room = getRoom(req, res);
    if (!room) return;
    room[arrayName].push(req.body as JsonObject);
    room.updatedAt = now();
    res.json({ ok: true, next: room[arrayName].length });
  });
}

function getPagedJson(pathName: string, arrayName: "browserIce" | "broadcastIce") {
  app.get(pathName, (req, res) => {
    const room = getRoom(req, res);
    if (!room) return;
    const since = Math.max(0, Number(req.query.since ?? 0) || 0);
    const source = room[arrayName];
    res.json({ next: source.length, candidates: source.slice(since) });
  });
}

app.get("/healthz", (_req, res) => {
  res.json({ ok: true, rooms: rooms.size, publicUrl: defaultDomain });
});

app.get("/api/rooms/:pair/session", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  res.json({ pairCode: room.pairCode, settings: room.settings, mode: "tunnel" });
});

app.post("/api/rooms/:pair/offer", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  room.offer = req.body as JsonObject;
  room.answer = null;
  room.browserIce = [];
  room.broadcastIce = [];
  room.updatedAt = now();
  res.json({ ok: true });
});

app.get("/api/rooms/:pair/offer", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  if (!room.offer) {
    res.status(204).end();
    return;
  }
  res.json(room.offer);
});

app.post("/api/rooms/:pair/answer", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  room.answer = req.body as JsonObject;
  room.updatedAt = now();
  res.json({ ok: true });
});

app.get("/api/rooms/:pair/answer", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  if (!room.answer) {
    res.status(204).end();
    return;
  }
  res.json(room.answer);
});

app.get("/api/rooms/:pair/settings", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  res.json(room.settings);
});

app.post("/api/rooms/:pair/settings", (req, res) => {
  const room = getRoom(req, res);
  if (!room) return;
  room.settings = req.body as JsonObject;
  room.updatedAt = now();
  res.json({ ok: true });
});

postJson("/api/rooms/:pair/ice/browser", "browserIce");
postJson("/api/rooms/:pair/ice/broadcast", "broadcastIce");
getPagedJson("/api/rooms/:pair/ice/browser", "browserIce");
getPagedJson("/api/rooms/:pair/ice/broadcast", "broadcastIce");

setInterval(() => {
  const cutoff = now() - ttlMs;
  for (const [pairCode, room] of rooms) {
    if (room.updatedAt < cutoff) rooms.delete(pairCode);
  }
}, Math.min(ttlMs, 60_000)).unref();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = process.env.SWIFTCAST_WEB_DIR
  ? path.resolve(process.env.SWIFTCAST_WEB_DIR)
  : path.resolve(__dirname, "..", "public");
const indexPath = path.join(publicDir, "index.html");

app.use(express.static(publicDir, {
  etag: true,
  maxAge: "30s"
}));

app.get(["/", "/watch"], (_req, res) => {
  res.sendFile(indexPath);
});

app.use((_req, res) => {
  res.status(404).json({ error: "not_found" });
});

const port = Number(process.env.PORT ?? 8080);
app.listen(port, "0.0.0.0", () => {
  console.log(`SwiftCast tunnel listening on :${port}`);
});
