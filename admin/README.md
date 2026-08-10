# 운영 대시보드 (로컬 전용)

사용량 · 유저별 해금 진척 · abuse 트리아지를 한 화면에서 보는 로컬 대시보드.

```bash
DENO_TLS_CA_STORE=system deno run --allow-net --allow-read --allow-env admin/server.ts
# → http://127.0.0.1:8787
```

`DENO_TLS_CA_STORE=system`은 사내망 TLS inspection 대응(시스템 키체인의 사내 CA 신뢰).
일반 네트워크에서는 없어도 된다.

## 구성

| 파일 | 역할 |
|---|---|
| `server.ts` | service_role 키를 들고 PostgREST를 호출하는 로컬 프록시. 브라우저엔 키가 안 내려간다. |
| `index.html` | 대시보드 SPA. 외부 의존성 없음(SVG 직접 렌더). |
| `../supabase/migrations/20260810000000_admin_views.sql` | 집계 로직 SSOT. 쿼리를 고칠 땐 **여기**를 고친다. |

키는 `scripts/ranking.env`(gitignore됨)에서 읽는다. 이 디렉토리에는 secret이 없다.

## 보안 전제

로컬 전용 설계이며, 아래 셋 중 하나라도 깨지면 재설계 대상이다.

1. **127.0.0.1 에만 바인드.** `0.0.0.0`으로 바꾸면 같은 네트워크의 누구나 service_role
   권한으로 전 사용자 데이터(백업 blob 포함)를 읽는다.
2. **인증 없음.** 위 1번이 유일한 접근 통제다.
3. **뷰 화이트리스트.** `server.ts`의 `ALLOWED_VIEWS`에 있는 `admin_*` 뷰만 프록시한다.
   `users` 원본을 직접 조회하는 경로는 의도적으로 없다.

DB 쪽은 `admin_*` 뷰 전부 `security_invoker = true` + anon/authenticated `REVOKE` 상태다
(anon 키로 접근 시 `permission denied`). 뷰를 DROP+CREATE로 재정의하면 이 두 설정이
초기화되므로, 재정의하는 마이그레이션은 반드시 함께 복원할 것.

## 탭

- **개요** — KPI 타일 + 최근 30일 활성 디바이스
- **사용량** — 일별 활성 디바이스 / 제출 처리 결과(전체·캡·거부) / 반영 코인
- **해금 진척** — 유저별 펫·이로치·뱃지·컬렉션·플레이타임. 서버 권위 값(코인·제출)과
  클라 자가 신고 값(stats·backup)을 나란히 두어 대조할 수 있다.
- **abuse** — 미검토 플래그 우선 정렬. 계정 나이·누적 플래그·7일 제출 패턴을 한 행에 조인.
- **버전** — app_version 분포 (클라 게이트 판단용)
- **펫** — 펫별 보유자/획득량/장착 분포 (가챠 밸런스 점검용)

## 읽기 전용이다

이 대시보드는 조회만 한다. 실제 운영 조치는 기존 경로 그대로:

| 작업 | 경로 |
|---|---|
| 플래그 검토 기록 | `abuse_flags.reviewed_at` / `review_note` 를 service_role로 UPDATE |
| 제재 | `users.status` UPDATE (`active` / `banned` / `shadow_banned`) |
| RP·코인 지급 | `reward-grants` skill |
| 공지 발행 | `announcements` INSERT (`release-app` skill 6단계) |

## 지표 해석 노트

- **획득합 vs 가챠** (해금 진척 탭) — `획득합`은 `backup.ownedPets`의 펫별 `count` 합,
  `가챠`는 `stats.totalPulls`. 둘 다 클라가 보낸 값이라 서로 맞아야 정상이다. 크게
  어긋나면 백업 조작이나 마이그레이션 버그 신호.
- **캡 적용 / 거부** — 캡만 오르면 정상 헤비유저, 거부까지 함께 뛰면 서명·리플레이 실패
  (조작 시도 또는 클라 버그).
- **미수령 보상** — 지급했는데 클라가 안 받아간 건수. 오래 남아 있으면 해당 유저가
  구버전이거나 폴링이 안 도는 상태다.
- **무결성 위반** — 클라 자가 탐지라 casual deterrent 수준. 결정적 치터는 끌 수 있으니
  단독 근거로 제재하지 말고 제출 패턴(캡·거부·최대 delta)과 함께 볼 것.
