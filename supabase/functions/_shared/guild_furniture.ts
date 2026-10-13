import {
  FURNITURE_KIND_COUNT,
  FURNITURE_MAX_INSTANCES,
  FURNITURE_TEXT_KINDS,
  FURNITURE_TEXT_MAX,
  FURNITURE_WALL_KINDS,
  FURNITURE_WALL_LANE,
} from "./guild_policy.ts";

// Swift OfficeLayout.emptyFurnitureLayout / furnitureMaxInstances와 쌍.
export const EMPTY_FURNITURE_LAYOUT = "empty:v2";
export const FURNITURE_LAYOUT_VERSION = 3;
// 60개의 문구 가구(문구 percent-encoding 최대 120자 + 좌표/구분자)를 수용.
export const FURNITURE_LAYOUT_MAX_LENGTH = 9000;

export function furnitureWriteError(
  version: unknown,
  expectedLayout: unknown,
): string | null {
  if (version !== FURNITURE_LAYOUT_VERSION) return "furniture_update_required";
  if (
    typeof expectedLayout !== "string" ||
    expectedLayout.length > FURNITURE_LAYOUT_MAX_LENGTH
  ) {
    return "invalid_layout";
  }
  return null;
}

export function isValidFurnitureLayout(layout: unknown): layout is string {
  if (
    typeof layout !== "string" || layout.length > FURNITURE_LAYOUT_MAX_LENGTH
  ) return false;
  if (layout === EMPTY_FURNITURE_LAYOUT) return true;
  // 빈 문자열은 초기 상태 전용. 0개 저장은 반드시 명시적인 sentinel을 사용한다.
  if (!layout.length) return false;
  const entries = layout.split(";");
  if (entries.length > FURNITURE_MAX_INSTANCES) return false;
  for (const e of entries) {
    const parts = e.split(":");
    if (parts.length < 3 || parts.length > 5) {
      return false;
    }
    if (parts.slice(0, 3).some((part) => part.trim().length === 0)) {
      return false;
    }
    const kind = Number(parts[0]);
    const x = Number(parts[1]);
    const lane = Number(parts[2]);
    if (
      !Number.isInteger(kind) || kind < 0 || kind >= FURNITURE_KIND_COUNT ||
      !Number.isFinite(x) || x < 0 || x > 280 ||
      !Number.isInteger(lane) ||
      (FURNITURE_WALL_KINDS.has(kind)
        ? lane !== FURNITURE_WALL_LANE
        : lane < 0 || lane > 2)
    ) {
      return false;
    }
    // 추가 필드 4·5: 숫자면 좌표(y), 비숫자면 문구.
    for (const field of parts.slice(3)) {
      if (field.length === 0) continue;
      const asNum = Number(field);
      if (Number.isFinite(asNum)) {
        if (asNum < 0 || asNum > 150) return false; // 씬 y 범위
        continue;
      }
      // 문구 — 액자 등 TEXT_KIND 한정.
      if (!FURNITURE_TEXT_KINDS.has(kind) || field.length > 120) {
        return false;
      }
      let text: string;
      try {
        text = decodeURIComponent(field);
      } catch {
        return false;
      }
      // 클라는 grapheme 10자 캡 — 이모지 ZWJ 시퀀스는 code point가 더 많으므로
      // 서버는 ×2 여유로 검증 (형식 방어가 목적, 정확한 글자 수는 클라 UX 책임).
      if (
        text.length === 0 || [...text].length > FURNITURE_TEXT_MAX * 2 ||
        /[\x00-\x1f\x7f;:]/.test(text)
      ) {
        return false;
      }
    }
  }
  return true;
}

export const STUDIO_MAX_ITEMS = 180;
export const STUDIO_MAX_PRESETS = 5;
export const STUDIO_MAX_LENGTH = 120000;
export type StudioOperation = "arrange" | "purchase" | "delete" | "presets";
export interface StudioItem {
  id: string;
  kind: number;
  x: number;
  lane: number;
  wallY?: number;
  text?: string;
  stored: boolean;
}
export interface StudioPosition {
  itemID: string;
  x: number;
  lane: number;
  wallY?: number;
}
export interface StudioPreset {
  id: string;
  name: string;
  positions: StudioPosition[];
}
export interface OfficeStudio {
  version: number;
  items: StudioItem[];
  presets: StudioPreset[];
}
const identifier = (value: unknown): value is string =>
  typeof value === "string" && /^[A-Za-z0-9-]{1,64}$/.test(value);
const record = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === "object" && !Array.isArray(value);
const onlyKeys = (value: Record<string, unknown>, keys: string[]) =>
  Object.keys(value).every((key) => keys.includes(key));
function encodedLength(text: string): number {
  try {
    return encodeURIComponent(text).length;
  } catch {
    return Infinity;
  }
}
function validPosition(p: Record<string, unknown>, kind: number): boolean {
  return typeof p.x === "number" && Number.isFinite(p.x) && p.x >= 0 &&
    p.x <= 280 &&
    typeof p.lane === "number" && Number.isInteger(p.lane) &&
    (FURNITURE_WALL_KINDS.has(kind)
      ? p.lane === 3
      : p.lane >= 0 && p.lane <= 2) &&
    (p.wallY == null ||
      (FURNITURE_WALL_KINDS.has(kind) && typeof p.wallY === "number" &&
        Number.isFinite(p.wallY) &&
        p.wallY >= ({ 8: 10, 9: 20, 10: 16 }[kind] ?? 0) && p.wallY <= 60));
}
export function isValidOfficeStudio(value: unknown): value is OfficeStudio {
  if (
    !record(value) || !onlyKeys(value, ["version", "items", "presets"]) ||
    value.version !== 1 ||
    !Array.isArray(value.items) || value.items.length > STUDIO_MAX_ITEMS ||
    !Array.isArray(value.presets) || value.presets.length > STUDIO_MAX_PRESETS
  ) return false;
  const items = new Map<string, StudioItem>();
  let placed = 0;
  for (const item of value.items) {
    if (
      !record(item) ||
      !onlyKeys(item, ["id", "kind", "x", "lane", "wallY", "text", "stored"]) ||
      !identifier(item.id) || items.has(item.id) ||
      typeof item.kind !== "number" ||
      !Number.isInteger(item.kind) || item.kind < 0 ||
      item.kind >= FURNITURE_KIND_COUNT ||
      typeof item.stored !== "boolean" || !validPosition(item, item.kind)
    ) return false;
    if (
      item.text != null &&
      (typeof item.text !== "string" || !FURNITURE_TEXT_KINDS.has(item.kind) ||
        [...item.text].length > FURNITURE_TEXT_MAX * 2 ||
        encodedLength(item.text) > 120 ||
        /[\x00-\x1f\x7f;:]/.test(item.text))
    ) return false;
    if (!item.stored) placed++;
    items.set(item.id, item as unknown as StudioItem);
  }
  if (placed > FURNITURE_MAX_INSTANCES) return false;
  const presets = new Set<string>();
  for (const preset of value.presets) {
    if (
      !record(preset) || !onlyKeys(preset, ["id", "name", "positions"]) ||
      !identifier(preset.id) || presets.has(preset.id) ||
      typeof preset.name !== "string" ||
      !preset.name.trim() || [...preset.name].length > 40 ||
      !Number.isFinite(encodedLength(preset.name)) ||
      /[\x00-\x1f\x7f]/.test(preset.name) ||
      !Array.isArray(preset.positions) ||
      preset.positions.length > FURNITURE_MAX_INSTANCES
    ) return false;
    presets.add(preset.id);
    const seen = new Set<string>();
    for (const position of preset.positions) {
      if (
        !record(position) ||
        !onlyKeys(position, ["itemID", "x", "lane", "wallY"]) ||
        !identifier(position.itemID) || seen.has(position.itemID)
      ) return false;
      const item = items.get(position.itemID);
      if (!item || !validPosition(position, item.kind)) return false;
      seen.add(position.itemID);
    }
  }
  return true;
}

export function parseOfficeStudio(raw: unknown): OfficeStudio | null {
  if (typeof raw !== "string" || raw.length > STUDIO_MAX_LENGTH) return null;
  try {
    const state = JSON.parse(raw);
    return isValidOfficeStudio(state) ? state : null;
  } catch {
    return null;
  }
}

export function studioLayout(state: OfficeStudio): string {
  const entries = state.items.filter((item) => !item.stored).map((item) => {
    let text = `${item.kind}:${item.x.toFixed(1)}:${item.lane}`;
    if (item.lane === 3) text += `:${(item.wallY ?? 52).toFixed(1)}`;
    if (item.text) text += `:${encodeURIComponent(item.text)}`;
    return text;
  });
  return entries.length ? entries.join(";") : EMPTY_FURNITURE_LAYOUT;
}

/** Swift OfficeStudioState(legacyLayout:)와 동일한 안정 id로 기존 구매 가구를 모두 보존한다. */
export function studioFromLegacy(raw: string | null): OfficeStudio {
  if (raw === EMPTY_FURNITURE_LAYOUT) {
    return { version: 1, items: [], presets: [] };
  }
  const defaults = "0:35:0;0:105:0;0:175:0;0:245:0;1:250:1";
  const items: StudioItem[] = [];
  for (
    const entry of (raw || defaults).split(";").slice(
      0,
      FURNITURE_MAX_INSTANCES,
    )
  ) {
    const p = entry.split(":");
    const kind = Number(p[0]), x = Number(p[1]), lane = Number(p[2]);
    if (
      p.length < 3 || p.length > 5 || !p[0] || !p[1] || !p[2] ||
      !Number.isInteger(kind) ||
      kind < 0 || kind >= FURNITURE_KIND_COUNT || !Number.isFinite(x) ||
      x < 0 || x > 280 ||
      !Number.isInteger(lane) ||
      (FURNITURE_WALL_KINDS.has(kind) ? lane !== 3 : lane < 0 || lane > 2)
    ) continue;
    const item: StudioItem = {
      id: `legacy-${items.length}`,
      kind,
      x,
      lane,
      stored: false,
    };
    const numericY = p[3] !== undefined && p[3] !== "" &&
      Number.isFinite(Number(p[3]));
    if (lane === 3 && numericY) {
      item.wallY = Math.min(
        60,
        Math.max({ 8: 10, 9: 20, 10: 16 }[kind] ?? 0, Number(p[3])),
      );
    }
    const text = p.length === 5
      ? p[4]
      : numericY && lane === 3
      ? undefined
      : p[3];
    if (text && kind === 9) {
      try {
        item.text = decodeURIComponent(text);
      } catch { /* malformed legacy text is empty */ }
    }
    items.push(item);
  }
  return items.length
    ? { version: 1, items, presets: [] }
    : studioFromLegacy(defaults);
}

const itemShape = (
  item: StudioItem,
) => [
  item.id,
  item.kind,
  item.x,
  item.lane,
  item.wallY ?? null,
  item.text || null,
  item.stored,
];
const presetShape = (presets: StudioPreset[]) =>
  presets.map((
    p,
  ) => [
    p.id,
    p.name,
    p.positions.map((q) => [q.itemID, q.x, q.lane, q.wallY ?? null]),
  ]);
const same = (a: unknown, b: unknown) =>
  JSON.stringify(a) === JSON.stringify(b);
/** 작업별 소유 id/개수 검증. 프리셋·실행 취소를 통한 가구 복제를 차단한다. */
export function studioTransitionError(
  before: OfficeStudio,
  after: OfficeStudio,
  operation: unknown,
  purchaseKind: unknown,
): string | null {
  const old = new Map(before.items.map((item) => [item.id, item]));
  const next = new Map(after.items.map((item) => [item.id, item]));
  const added = after.items.filter((item) => !old.has(item.id));
  const removed = before.items.filter((item) => !next.has(item.id));
  for (const item of after.items) {
    const previous = old.get(item.id);
    if (previous && previous.kind !== item.kind) {
      return "furniture_inventory_conflict";
    }
    if (
      previous && operation !== "arrange" &&
      !same(itemShape(previous), itemShape(item))
    ) return "furniture_inventory_conflict";
  }
  if (operation === "purchase") {
    if (
      removed.length || added.length !== 1 || added[0].kind !== purchaseKind
    ) return "furniture_inventory_conflict";
  } else if (operation === "delete") {
    if (added.length || removed.length !== 1) {
      return "furniture_inventory_conflict";
    }
  } else if (operation === "arrange" || operation === "presets") {
    if (added.length || removed.length) return "furniture_inventory_conflict";
  } else return "invalid_action";
  if (operation !== "presets") {
    const expectedPresets = before.presets.map((p) => ({
      ...p,
      positions: p.positions.filter((q) => next.has(q.itemID)),
    }));
    if (!same(presetShape(expectedPresets), presetShape(after.presets))) {
      return "furniture_inventory_conflict";
    }
  }
  return null;
}
