// 쪽지(DM) 정책 SSOT — dm-* 함수들이 import (guild_policy.ts 패턴).
// docs/plans/direct-messages.md §10 참조.

export const DM_MAX_PER_DAY = 200;              // 일일 발신 총량
export const DM_MAX_NEW_PEERS_PER_DAY = 30;     // 하루 "새 상대" 발신 수 (스팸 억제)
export const DM_CIPHERTEXT_MAX = 6144;          // ciphertext(base64) 최대 바이트 ≈ 평문 ~4KB
export const DM_THREAD_PAGE = 100;              // dm-thread 1회 반환 상한
export const DM_X25519_PUB_LEN = 44;            // base64(32B) = 44자 (padding 포함)

export type AllowFrom = "anyone" | "guild" | "none";
