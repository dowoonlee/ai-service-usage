import { isValidUUID } from "./validation.ts";

export function parseDecorMove(raw: string): { x: number; y: number; version: string } | null {
  try {
    const p = JSON.parse(raw);
    if (!p || typeof p !== "object" || Array.isArray(p) || Object.keys(p).sort().join(",") !== "version,x,y"
      || !Number.isInteger(p.x) || !Number.isInteger(p.y) || p.x < 8 || p.x > 272
      || p.y < 32 || p.y > 140 || !isValidUUID(p.version)) return null;
    return { x: p.x, y: p.y, version: p.version };
  } catch { return null; }
}
