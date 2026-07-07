# 유저 간 1:1 쪽지 (E2EE) + 통합 인박스 — 설계 SSOT

길드 **푸시 초대장**에서 확립한 "닉네임→디바이스 해석 · 유저별 HMAC 서명 요청 · 테이블/함수/RLS
패턴" 위에, 트레이너 간 1:1 **종단간 암호화(E2EE) 쪽지**를 얹는다. 나아가 쪽지 전용 창을
**통합 인박스**로 삼아 **길드 초대까지 한 화면에서** 처리한다.

> 상태: **P1~P3 구현·로컬 실서버 검증 완료(배포 대기)**. 본 문서가 구현 SSOT.
> 초대 백엔드(`guild_invites`·`guild-invite`)는 재사용, 클라 표면만 인박스로 편입.

---

## 0. 확정 결정 요약

| # | 항목 | 결정 |
|---|---|---|
| 1 | 키 백업 | **옵션 A — 백업 없음**. 키 입력 구간 0, 기기 변경 시 이전 쪽지 소실 수용 |
| 2 | 암호 스택 | **시스템 CryptoKit HPKE**(RFC 9180) **Auth 모드**. macOS 14 상향으로 의존성 0 |
| 3 | 진입점 | **전용 창**(패널 ✉️ 아이콘 → NSWindow, 게시판 창 패턴) |
| 4 | 개방 범위 | **개방(닉네임) + 차단 + 수신 설정**(아무나/길드만/안 받음) + 레이트리밋 |
| 5 | 초대 통합 | 초대 백엔드 재사용, **받은 초대를 통합 인박스 카드**로. DM과 함께 배포 |
| 6 | 보존 | 기본 무기한 + 양측 삭제. 읽은 DM은 180일 후 자동 purge(안전판, DB 용량) |

---

## 1. 핵심 원리 — DM은 E2EE, 초대는 서버 가시 (통합 인박스에서 공존)

두 종류는 암호화 성격이 **정반대**라 하나의 암호 모델로 합칠 수 없다:

- **DM**: E2EE → **서버가 못 읽음**(수신자 기기에서만 복호). 본문 기밀.
- **길드 초대**: 서버가 **읽고 처리**(자격 검사 + 수락 시 `guild_members` 삽입). 서버 가시 필수.

→ 통합은 **암호 레벨이 아니라 UI/알림/인박스 표면에서** 한다. 전용 창의 인박스에 두 항목 타입이
공존한다:
- 🔒 **DM 스레드**(암호문 blob)
- 🛡 **길드 초대 카드**(서버 가시 시스템 항목, 수락/거절)

---

## 2. 위협 모델 (정직하게)

**지킨다**
- 서버/DB 유출(수동적) 시 **DM 본문 비노출**(암호문만). 서버가 HMAC 키를 보유해도 DM은 별도
  비대칭 키라 못 읽음.

**못 지킨다(명시)**
- **메타데이터**: 누가↔누구, 시각, 크기, 읽음 여부 — 서버가 봄.
- **능동적 악성 서버의 공개키 MITM**: 최초 교신 시 서버가 공개키를 바꿔치기하면 가로챌 수 있음.
  → **TOFU 고정 + 키 변경 경고 + (선택) 지문 비교**로 완화. 익명 유저 간 대역외 검증은 어려움.
- **엔드포인트(기기) 탈취**: 기기 침해 시 그 기기의 쪽지는 읽힘.
- **초대 본문**: E2EE 아님(서버 처리 필요). 초대는 "누가 어느 길드에 초대했다" 수준만 담김.

보증선: **DM 본문 기밀성은 E2EE, 발신자 인증은 HPKE Auth로 암호 레벨 보장, 서버의 키 바꿔치기는
TOFU로 탐지**. 나머지(메타데이터)는 서버 신뢰.

---

## 3. 암호 프리미티브 — 시스템 CryptoKit HPKE

- **신원 키쌍**: X25519 — `Curve25519.KeyAgreement.PrivateKey`. **개인키 Keychain**
  (service=`ClaudeUsage`, account=`dmIdentityKey`), **공개키만 서버 게시**(`user_keys`).
- **ciphersuite**: `HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly`
  (DHKEM(X25519,HKDF-SHA256) / HKDF-SHA256 / ChaChaPoly).
- **가용성**: 시스템 HPKE = macOS 14+. 앱 최소 지원을 14로 상향(완료)해 의존성 0. (13 유지가
  필요했다면 swift-crypto의 `@available(macOS 10.15+)` HPKE가 대안이었음 — 불필요.)
- 사용자는 **키를 입력/열람하지 않음**(전부 자동). 유일한 키 노출은 선택적 **지문(읽기 전용)**.

---

## 4. 메시지 암호화 스킴 — HPKE Auth 모드

HPKE는 KEM 캡슐이 **임시(ephemeral)** 라 메시지마다 키가 신선하고, **Auth 모드**로 발신자
인증까지 한 프리미티브에 담긴다.

**발신 A → 수신 B** (`import CryptoKit`):
```swift
let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
let info  = Data("aiusage-dm-v1".utf8)
let aad   = Data("\(A_device)|\(B_device)|1".utf8)   // 발신·수신·버전 바인딩
var sender = try HPKE.Sender(recipientKey: B_idPub, ciphersuite: suite,
                             info: info, authenticatedBy: A_idPriv)
let ct  = try sender.seal(plaintextUTF8, authenticating: aad)
let enc = sender.encapsulatedKey
// wire blob = 0x01(version) || enc(32B) || ct   → base64 → ciphertext 필드
```
**수신 B**:
```swift
var recipient = try HPKE.Recipient(privateKey: B_idPriv, ciphersuite: suite, info: info,
                                   encapsulatedKey: enc, authenticatedBy: A_idPub)
let text = try recipient.open(ct, authenticating: aad)   // open 성공 = A 개인키 보유자 증명
```
- 캡슐 `enc`가 매번 새로 → **메시지마다 키 신선**.
- Auth 모드 → **위조 불가**(서버가 A로 위조하려면 A_idPriv 필요).
- **와이어 포맷**: `version(1B) ‖ encapsulatedKey(32B) ‖ ct`, base64. version으로 향후 suite 교체 대비.
- **한계**: 단발 공개키 암호(ratchet 아님) → 수신자 정적키 침해 시 과거 메시지 복호 가능(편지형
  쪽지엔 수용). 완전 forward secrecy가 필요하면 P4에서 one-time prekey 도입.

---

## 5. 키 관리 & 복구 (옵션 A)

- 개인키는 기기 Keychain에만. **백업 없음**.
- **복구/재설치**: 개인키 소실 → 새 X25519 키 생성·`key-publish`(rotate). **이전에 받은 암호문은
  영구 복호 불가** → 스레드에 "🔒 이 기기에서 복호할 수 없어요"로 표시.
- 참고: `users.recovery_code_hash`는 SHA-256 해시만 저장(평문 없음)이나 recover 시 클라가 평문을
  보내므로, 복구코드 기반 백업(옵션 B)은 능동적 악성 서버에 취약 → 채택 안 함.

---

## 6. TOFU (공개키 신뢰 고정)

- 클라이언트는 상대 공개키를 **device_id 기준 로컬 고정**: `Settings.dmPinnedKeys: [deviceId: pubB64]`.
- `key-fetch` 결과가 핀과 **다르면** 스레드/작성에 경고 배너 → 사용자가 `[새 키 신뢰]`로 핀 갱신.
- 최초 교신은 자동 신뢰(TOFU). 지문 비교(선택)로 대역외 검증 지원.

---

## 7. 데이터 모델 (신규 마이그레이션 `..._direct_messages.sql`)

```sql
user_keys                              -- 신원 공개키 (device 1:1)
  device_id   UUID PK REFERENCES users(device_id) ON DELETE CASCADE
  x25519_pub  TEXT NOT NULL            -- base64 raw 32B
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()

direct_messages
  id            UUID PK DEFAULT gen_random_uuid()
  sender_device    UUID NOT NULL       -- FK 없음(탈퇴 후 스레드 유지) — 초대 inviter 패턴
  recipient_device UUID NOT NULL REFERENCES users(device_id) ON DELETE CASCADE
  ciphertext    TEXT NOT NULL          -- base64(version‖enc‖ct), ≤ 6KB
  sender_id_pub TEXT NOT NULL          -- 발신 당시 A_idPub 스냅샷(수신자 open/TOFU 대조)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
  read_at       TIMESTAMPTZ
  del_sender    BOOLEAN NOT NULL DEFAULT false   -- 양측 tombstone
  del_recipient BOOLEAN NOT NULL DEFAULT false

dm_blocks
  blocker_device UUID, blocked_device UUID, created_at TIMESTAMPTZ DEFAULT now()
  PRIMARY KEY (blocker_device, blocked_device)

dm_settings
  device_id  UUID PK REFERENCES users(device_id) ON DELETE CASCADE
  allow_from TEXT NOT NULL DEFAULT 'anyone' CHECK (allow_from IN ('anyone','guild','none'))
```
- 전부 **RLS 활성 + 정책 없음 = service_role(Edge Function) 전용** (다른 guild_* 테이블과 동일).
- 인덱스: `direct_messages(recipient_device, created_at)`,
  `(sender_device, recipient_device, created_at)`(스레드), `dm_blocks(blocked_device)`.
- 초대는 기존 `guild_invites` 재사용.

---

## 8. 엔드포인트 (모두 발신자 HMAC 서명, present-only canonical)

**키**
- `key-publish` `{deviceId, x25519Pub, ts}` → user_keys upsert(신규/rotate).
- `key-fetch` `{deviceId, targetNickname, ts}` → `{deviceId, nickname, x25519Pub}` / 404 `no_key`.

**DM**
- `dm-send` `{deviceId, targetNickname, ciphertext, senderIdPub, ts}` → 검사(존재·키 보유·차단·
  allow_from·레이트리밋) 후 insert. 반려 사유는 프라이버시상 뭉갬(`cannot_send`).
- `dm-inbox` `{deviceId, ts}` → 스레드 요약
  `[{peerDevice, peerNickname, peerIdPub, lastCiphertext, lastAt, unreadCount, blocked}]`.
  (클라가 lastCiphertext 복호해 미리보기)
- `dm-thread` `{deviceId, peerDevice, before?, ts}` → 메시지 페이지
  `[{id, fromMe, ciphertext, senderIdPub, createdAt, readAt}]` (before 커서, 50건/page).
- `dm-read` `{deviceId, peerDevice, upToTs, ts}` → 그 상대의 upToTs 이하 수신분 read 처리.
- `dm-delete` `{deviceId, messageId|peerDevice, ts}` → 내 쪽 tombstone(양측 삭제 시 물리 삭제).
- `dm-block` / `dm-unblock` `{deviceId, targetNickname, ts}`.
- `dm-settings` `{deviceId, allowFrom, ts}` → 수신 정책 변경.

**초대(재사용)**: `guild-manage.invite/cancel_invite`(길드장), `guild-invite.list/accept/decline`.

---

## 9. 통합 인박스 (클라 조립)

전용 창 인박스는 **두 소스를 클라에서 병합**:
1. `dm-inbox` → DM 스레드 요약
2. `guild-invite.list` → 받은 초대(기존)

렌더: **받은 초대 카드(있으면 상단)** → **DM 스레드 목록**(최신순). 미확인 배지 = 미확인 DM 수 +
대기중 초대 수. (초대와 DM을 시간순 완전 인터리브도 가능하나 v1은 섹션 분리가 명료.)

---

## 10. 안티스팸 / 레이트리밋 (`dm_policy.ts`)

- `DM_MAX_PER_DAY = 200` (총 발신), `DM_MAX_NEW_PEERS_PER_DAY = 30` (새 상대 발신 — 스팸 억제).
- `DM_CIPHERTEXT_MAX = 6144` (base64 바이트 ≈ 평문 ~4KB).
- 수신 정책 `allow_from`: anyone(기본)/guild(같은 길드만)/none. 차단 우선.
- 신고는 v1 후순위(P4) — 차단으로 갈음.

---

## 11. 클라이언트 구조

- **`DMWindowController`** — 전용 NSWindow 단일 인스턴스(GuildWindow/BoardWindow 패턴). 패널
  상단 **✉️ 아이콘 + 미확인 배지**로 진입.
- **`DMCrypto`** — 키 생성·Keychain 저장·`key-publish`, HPKE seal/open, TOFU 핀 관리.
- **뷰**: `DMInboxView`(통합) / `DMThreadView`(버블) / `DMComposeView`(닉네임 지정) /
  `DMSettingsView`(수신 정책·차단 목록·지문).
- **RankingAPI**: dm-*·key-* 서명 요청(기존 `signEncodable`·present-only 재사용).
- **재사용**: `TrainerCardView` 팝오버(아바타), 닉네임 입력·에러 매핑(초대), 미확인 배지,
  확인 다이얼로그, `runAction` 패턴.
- **초대 편입**: 기존 GuildView "받은 초대" 섹션 → `DMInboxView` 카드로 이동. "멤버 초대"(발송)는
  길드 탭 유지(길드장 관리 액션).

**보안 UI**
- 최초 진입: "🔒 이 기기에 암호화 키를 만들었어요. 기기를 바꾸면 새로 시작됩니다" 1회.
- 키 변경 경고 배너 + `[새 키 신뢰]`/`[무시]`.
- 복호 불가 버블: "🔒 이 기기에서 복호할 수 없어요".

---

## 12. 화면 스케치 (UI 기획 확정본)

**인박스 (전용 창 ~380×440)**
```
┌─ 쪽지 ───────────────────── [⚙] [✕] ┐
│ [🔍 닉네임 검색]         [＋ 새 쪽지] │
├──────────────────────────────────────┤
│ 🛡 데드락클럽 초대 · vibewolf          │  ← 초대 카드
│    [수락]  [거절]                      │
├──────────────────────────────────────┤
│ 🦊 vibewolf            2:14   ●        │  ← DM 스레드(미확인 dot)
│    빌드 깨진 거 확인했어?               │
│ 🐺 kimcoder            어제            │
│    ㅋㅋ 머지 고마워                     │
├──────────────────────────────────────┤
│ 🔒 종단간 암호화 · 이 기기에서만 읽힘  │
└──────────────────────────────────────┘
```
**스레드 / 작성**: §앞선 기획(버블·전송창 / 받는사람 닉네임+본문+TOFU 안내)과 동일.

---

## 13. 단계 (phasing)

- **P1 — DM 코어** ✅: `user_keys`/`direct_messages`, key-publish/fetch, dm-send/inbox/thread/read,
  `DMCrypto`(HPKE Auth·Keychain·TOFU), 전용 창(인박스/스레드/작성). 로컬 실서버 왕복 검증.
- **P2 — 초대 편입** ✅: 받은 초대를 통합 인박스 카드로, 길드 탭 받은-초대 섹션 제거·이동.
- **P3 — 개방+차단·설정** ✅: dm-settings(get/set/block/unblock 단일 함수), allow_from,
  레이트리밋(P1 dm-send), 안전 지문. 차단/정책 enforcement 로컬 검증.
- **P4 — 후순위**: 신고, dm-delete(양측 tombstone), 키 백업(옵션 B, 경고 동반),
  one-time prekey/forward secrecy 강화.

배포: P1~P3를 한 릴리스로 묶어(초대 편입 포함) 서버 배포(마이그레이션+함수) → 클라 태그.

---

## 14. 초대 인프라에서 재사용

닉네임→디바이스 해석 · HMAC 서명(present-only canonical) · 테이블/함수/RLS(service_role 전용) ·
프라이버시 뭉갬 에러 · 클라 UI/에러 관례(GuildView 초대 섹션).

---

## 15. 남은 소소한 확인 (구현 중 확정 가능)

- 미확인 배지: 패널 아이콘(권장) — 메뉴바 노출은 후순위.
- 작성 진입 바로가기: 트레이너 카드/멤버 목록에 "쪽지 보내기" 추가 여부(P2+).
- retention purge 주기(180일)와 실행 방식(요청 시 lazy vs 크론) — DB 용량 보고 결정.
