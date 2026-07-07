// 길드 정책 SSOT — guild-* 함수들이 모두 여기서 import (board_policy.ts 패턴).
// docs/plans/guild.md §2·§3 참조. 값 변경 시 이 파일만 수정.
//
// 주의: 월간 점수의 "상위 5명 합산"은 DB 뷰(guild_monthly_scores의 rn <= 5)에도
// 박혀 있다 — TOP_CONTRIBUTORS를 바꾸면 마이그레이션으로 뷰도 함께 갱신할 것.

export const TOP_CONTRIBUTORS = 5;              // 길드 점수에 반영되는 멤버 수
export const JOIN_COOLDOWN_SEC = 7 * 24 * 3600; // 탈퇴/추방 후 재가입 쿨다운 (7일)
export const OFFICE_SLOT_COUNT = 12;            // 사무실 스팟 수 (0..11) — DB CHECK와 쌍 (guilds migration)
export const INVITE_CODE_LEN = 8;

// 푸시 초대장 (guild_invites 테이블).
export const INVITE_EXPIRE_SEC = 7 * 24 * 3600;        // 초대 만료 (7일)
export const INVITE_REDECLINE_COOLDOWN_SEC = 24 * 3600; // 거절 후 같은 길드의 재초대 쿨다운 (24시간)
export const INVITE_MAX_PENDING_PER_GUILD = 30;         // 길드당 동시 대기중 초대 상한 (스팸 방지)

// 가구 카탈로그 — 클라 OfficeLayout.furnitureCatalog와 쌍 (id 순서 재배열 금지).
export const FURNITURE_KIND_COUNT = 11;                   // kind 0..10
export const FURNITURE_WALL_KINDS = new Set([8, 9, 10]);  // 벽 전용(시계/액자/화이트보드) — lane 3 강제
export const FURNITURE_TEXT_KINDS = new Set([9]);         // 문구 지원 (액자)
export const FURNITURE_WALL_LANE = 3;
export const FURNITURE_MAX_INSTANCES = 30;                // 클라 furnitureMaxInstances와 쌍
export const FURNITURE_TEXT_MAX = 10;                     // 클라 furnitureTextMax와 쌍

// P2a에서 사용 — 월간 길드 Top3 멤버 RP (1위/2위/3위). 자격: 해당 월 VP > 0.
export const GUILD_MONTHLY_RP = [500, 300, 200];

// 생성 rate-limit (register_attempts 패턴 — guild_create_attempts 테이블).
export const CREATE_IP_WINDOW_SEC = 24 * 3600;
export const CREATE_IP_MAX = 5;

// 혼동 문자(0/O, 1/I/L, S/5 등) 제외 — validation.ts의 RECOVERY_CHARS와 동일 셋.
const CODE_CHARS = "ABCDEFGHJKMNPQRTUVWXY23456789";

export function generateInviteCode(): string {
  let out = "";
  const buf = new Uint8Array(INVITE_CODE_LEN);
  crypto.getRandomValues(buf);
  for (const b of buf) out += CODE_CHARS[b % CODE_CHARS.length];
  return out;
}

// 길드명: 2~24자, 내부 공백 허용("Works on My Machine"), 제어문자·앞뒤 공백 금지.
// 닉네임(공백 전면 금지, 3~24자)과 규칙이 달라 validation.ts와 별도로 둔다.
export function isValidGuildName(s: unknown): s is string {
  if (typeof s !== "string") return false;
  if (s.length < 2 || s.length > 24) return false;
  if (/[\x00-\x1f\x7f]/.test(s)) return false;
  if (s !== s.trim()) return false;
  if (/\s{2,}/.test(s)) return false;   // 연속 공백 금지 (normalized 충돌 혼란 방지)
  return true;
}
