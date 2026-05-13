// HMAC-SHA256 + canonical JSON 직렬화.
//
// 클라이언트(Swift)는 `JSONEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]`로
// payload를 직렬화 후 HMAC. 서버측도 정확히 동일하게 재현해야 서명 일치. flat object만 지원
// (현재 SubmitPayload는 flat). nested object/array 들어가면 재귀 canonicalize 필요.

export function canonicalize(obj: Record<string, unknown>): string {
  const keys = Object.keys(obj).sort();
  const parts = keys.map((k) => {
    const v = obj[k];
    // JSON.stringify는 기본적으로 / 를 escape 안 함 — Swift의 withoutEscapingSlashes와 일치.
    return `${JSON.stringify(k)}:${JSON.stringify(v)}`;
  });
  return `{${parts.join(",")}}`;
}

export async function importHmacKey(base64Key: string): Promise<CryptoKey> {
  const binary = Uint8Array.from(atob(base64Key), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "raw",
    binary,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

export async function signHex(key: CryptoKey, message: string): Promise<string> {
  const data = new TextEncoder().encode(message);
  const sigBuf = await crypto.subtle.sign("HMAC", key, data);
  return Array.from(new Uint8Array(sigBuf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/// constant-time hex string 비교. timing attack 방어.
export function timingSafeEqualHex(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/// payload 객체 + signature(hex) + base64 key → verify.
export async function verifyHmac(
  payload: Record<string, unknown>,
  signatureHex: string,
  hmacKeyBase64: string,
): Promise<boolean> {
  const key = await importHmacKey(hmacKeyBase64);
  const expected = await signHex(key, canonicalize(payload));
  return timingSafeEqualHex(expected, signatureHex);
}

/// 32바이트 랜덤 → base64. 신규 사용자 등록 시 per-install 키 발급.
export function generateHmacKeyB64(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}
