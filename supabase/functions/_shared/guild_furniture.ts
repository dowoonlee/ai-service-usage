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
export const FURNITURE_LAYOUT_VERSION = 2;
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
