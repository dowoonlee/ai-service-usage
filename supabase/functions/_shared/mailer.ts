// 최소 SMTP 발신기 (Gmail 465 implicit TLS 전용).
//
// denomailer의 MIME 출력(중첩 multipart/mixed + Q-encoded 제목 + LF 개행)이 일부 Exchange/M365
// (예: SKCC)에서 파싱 실패 → 빈 본문 또는 raw 소스 노출. 이를 피하려 여기서 직접 구성한다:
//   * CRLF 개행, 헤더/본문 사이 빈 줄 1개.
//   * 제목은 RFC2047 B-encoding(=?UTF-8?B?..?=) — Q-encoding의 공백 문제 회피.
//   * 본문은 단일 text/html; charset=utf-8, base64(76자 wrap). multipart 안 씀.
// From은 Gmail 인증 계정으로 강제되므로 opts.from == GMAIL_USER 여야 한다.

function b64(s: string): string {
  const bytes = new TextEncoder().encode(s);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

function wrap76(s: string): string {
  const out: string[] = [];
  for (let i = 0; i < s.length; i += 76) out.push(s.slice(i, i + 76));
  return out.join("\r\n");
}

export interface MailOptions {
  from: string;
  to: string;
  subject: string;
  html: string;
  user: string;   // SMTP 인증 계정 (= from)
  pass: string;   // Gmail 앱 비밀번호
}

export async function sendMail(opts: MailOptions): Promise<void> {
  const conn = await Deno.connectTls({ hostname: "smtp.gmail.com", port: 465 });
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const buf = new Uint8Array(8192);

  async function readCode(expect: number): Promise<void> {
    let acc = "";
    // 최종 응답 줄(`NNN ` — 코드 뒤 공백)이 나올 때까지 누적. multiline은 `NNN-`.
    for (let guard = 0; guard < 64; guard++) {
      const n = await conn.read(buf);
      if (n === null) throw new Error("smtp: connection closed");
      acc += dec.decode(buf.subarray(0, n));
      const lines = acc.split("\r\n").filter((l) => l.length > 0);
      const last = lines[lines.length - 1] ?? "";
      if (/^\d{3} /.test(last)) {
        const code = parseInt(last.slice(0, 3), 10);
        if (code !== expect) throw new Error(`smtp: expected ${expect}, got "${last}"`);
        return;
      }
    }
    throw new Error("smtp: reply overrun");
  }
  async function cmd(line: string, expect: number): Promise<void> {
    await conn.write(enc.encode(line + "\r\n"));
    await readCode(expect);
  }

  try {
    await readCode(220);                          // 서버 인사
    await cmd("EHLO aiusage", 250);
    await cmd("AUTH LOGIN", 334);
    await cmd(b64(opts.user), 334);
    await cmd(b64(opts.pass), 235);               // 인증 성공
    await cmd(`MAIL FROM:<${opts.from}>`, 250);
    await cmd(`RCPT TO:<${opts.to}>`, 250);
    await cmd("DATA", 354);

    const headers = [
      `From: ${opts.from}`,
      `To: ${opts.to}`,
      `Subject: =?UTF-8?B?${b64(opts.subject)}?=`,
      `Date: ${new Date().toUTCString()}`,
      `MIME-Version: 1.0`,
      `Content-Type: text/html; charset=utf-8`,
      `Content-Transfer-Encoding: base64`,
    ].join("\r\n");
    // base64 본문은 A-Za-z0-9+/= 뿐이라 '.'로 시작하는 줄이 없어 dot-stuffing 불필요.
    const message = headers + "\r\n\r\n" + wrap76(b64(opts.html)) + "\r\n.\r\n";
    await conn.write(enc.encode(message));
    await readCode(250);                          // 메시지 수락
    try { await cmd("QUIT", 221); } catch { /* QUIT 응답은 무시 가능 */ }
  } finally {
    try { conn.close(); } catch { /* 이미 닫힘 */ }
  }
}
