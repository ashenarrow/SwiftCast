import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const tunnelRoot = path.resolve(here, "..");
const repoRoot = path.resolve(tunnelRoot, "..");
const webDist = path.resolve(repoRoot, "web", "dist");
const publicDir = path.resolve(tunnelRoot, "public");

if (!existsSync(webDist)) {
  throw new Error(`Missing ${webDist}. Run npm --prefix web run build before building the tunnel.`);
}

rmSync(publicDir, { recursive: true, force: true });
mkdirSync(publicDir, { recursive: true });
cpSync(webDist, publicDir, { recursive: true });
