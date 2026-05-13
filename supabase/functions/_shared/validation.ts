// 닉네임/UUID/recovery code 검증. 서버측 권위 검증 — 클라이언트 검증은 UX 보조용.

export function isValidNickname(s: unknown): s is string {
  if (typeof s !== "string") return false;
  if (s.length < 3 || s.length > 24) return false;
  // 공백 + 제어문자 금지 (\s = 공백류, \x00-\x1f + \x7f = ASCII 제어문자)
  if (/[\s\x00-\x1f\x7f]/.test(s)) return false;
  return true;
}

export function isValidUUID(s: unknown): s is string {
  if (typeof s !== "string") return false;
  return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(s);
}

const RECOVERY_CHARS = "ABCDEFGHJKMNPQRTUVWXY23456789";

/// 12자 영숫자 + dash → "XXXX-XXXX-XXXX". 헷갈리는 글자 제외.
export function generateRecoveryCode(): string {
  const chunk = (n: number) => {
    let out = "";
    const buf = new Uint8Array(n);
    crypto.getRandomValues(buf);
    for (const b of buf) out += RECOVERY_CHARS[b % RECOVERY_CHARS.length];
    return out;
  };
  return `${chunk(4)}-${chunk(4)}-${chunk(4)}`;
}

/// SHA-256(code) hex. DB에 plain text recovery code를 저장하지 않기 위함.
/// 입력은 대소문자/dash 무시 — "abcd-efgh-ijkl" 와 "ABCDEFGHIJKL" 동일 hash.
export async function hashRecoveryCode(code: string): Promise<string> {
  const normalized = code.toUpperCase().replace(/-/g, "");
  const data = new TextEncoder().encode(normalized);
  const buf = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
