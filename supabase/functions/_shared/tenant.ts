// 테넌트 격리 공용 헬퍼. docs/plans/tenant.md.
//
// 원칙(§2): 소속의 단일 진실은 users.tenant_id. 클라는 tenant를 주장할 수 없고 서버가 device_id로만
// 판정한다. 모든 상호작용 Edge Function은 진입 시 resolveTenant로 호출자 테넌트를 구하고,
//   - 읽기는 .eq("tenant_id", tenant) 필터
//   - 쓰기는 tenant_id: tenant 스탬프
//   - 타깃 있는 액션(쪽지·길드가입 등)은 assertSameTenant로 교차 차단(→ 403 cross_tenant)
// 세 패턴만 반복한다.

import { SupabaseClient } from "jsr:@supabase/supabase-js@2";

// device_id UUID 정규화 — 클라(Swift)는 대문자로 보내지만 DB는 소문자 저장. PostgREST .eq(uuid)는
// 대소문자 무시지만, 조회 결과를 JS에서 매칭할 때 케이스가 어긋나지 않도록 항상 소문자로 통일한다.
// (leaderboard가 겪었던 medalsByDevice 매칭 버그와 동일 클래스의 예방.)
export function normDeviceId(deviceId: string): string {
  return deviceId.toLowerCase();
}

// device_id → 현재 테넌트 slug. 미등록이면 null (호출부가 404 등으로 처리).
export async function resolveTenant(
  db: SupabaseClient,
  deviceId: string,
): Promise<string | null> {
  const { data } = await db
    .from("users")
    .select("tenant_id")
    .eq("device_id", normDeviceId(deviceId))
    .maybeSingle();
  return (data?.tenant_id as string | undefined) ?? null;
}

// 여러 device의 tenant를 한 번에 조회 → device_id(소문자) → tenant_id 맵.
// dm-inbox처럼 상대방 여러 명의 테넌트를 확인해야 할 때 N+1을 피한다.
export async function tenantsOf(
  db: SupabaseClient,
  deviceIds: string[],
): Promise<Map<string, string>> {
  const ids = [...new Set(deviceIds.map(normDeviceId))];
  const out = new Map<string, string>();
  if (ids.length === 0) return out;
  const { data } = await db
    .from("users")
    .select("device_id, tenant_id")
    .in("device_id", ids);
  for (const r of data ?? []) {
    out.set(normDeviceId(r.device_id as string), r.tenant_id as string);
  }
  return out;
}

// 범용 SHA-256 hex — OTP 코드 해시용(평문 저장 안 함). validation.hashRecoveryCode는 대문자화/dash
// 제거 정규화가 있어 6자리 숫자 OTP엔 부적합하므로 별도.
export async function sha256Hex(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// 이메일 정규화(trim+lowercase) 후 `@` 뒤 도메인 추출. 형식 이상이면 null.
// 서브도메인/접미사 트릭은 이후 tenant_email_domains 정확 일치 조회로 걸러진다.
export function emailDomain(email: string): string | null {
  const e = email.trim().toLowerCase();
  const m = /^[^@\s]+@([^@\s]+\.[^@\s]+)$/.exec(e);
  return m ? m[1] : null;
}

// 두 device가 같은 테넌트인지. 어느 한쪽이라도 미등록이면 false(격리 우선 — 모르면 차단).
export async function sameTenant(
  db: SupabaseClient,
  a: string,
  b: string,
): Promise<boolean> {
  const map = await tenantsOf(db, [a, b]);
  const ta = map.get(normDeviceId(a));
  const tb = map.get(normDeviceId(b));
  return ta != null && tb != null && ta === tb;
}
