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
| `gen-pet-catalog.ts` | 클라 소스에서 펫 표시 이름·희귀도·스프라이트 메타를 추출 → `pets.json` |
| `pets.json` | 위 산출물(커밋 대상). 대시보드가 아이콘·이름·희귀도를 그리는 데 쓴다. |

### 스프라이트 방향 검수 — `/audit`

`http://127.0.0.1:8787/audit` 는 전 펫의 스프라이트를 **원본 그대로**(반전 없이) 팩별로 늘어놓고
현재 `defaultFacingLeft` 값을 화살표로 함께 보여준다. **그림이 보는 방향과 화살표가 일치해야**
정상이고, 어긋나면 앱에서 그 펫이 뒤로 걷는다.

팩 단위로 묶는 게 핵심이다. facing이 팩 전체에서 통째로 뒤집혀 있으면 "팩 안에서 튀는 종 찾기"
로는 절대 안 걸린다 — 실제로 `luizmelo-pets` 12종과 `superpowers-prehistoric-char` 6종이
전부 좌향인데 팩째로 `false`였고, 이 화면을 만들기 전에는 표본 검사로 놓쳤다.

펫을 추가하거나 방향이 의심되면 이 화면부터 열 것.

### 펫 카탈로그 재생성

펫을 추가·수정했다면 다시 돌린다:

```bash
deno run --allow-read --allow-write admin/gen-pet-catalog.ts
```

표시 이름·희귀도·스프라이트의 SSOT가 전부 클라 코드다 — `pet_metadata` 테이블은 일부만 담은
override용이고, 서버는 희귀도를 아예 모른다(`Gacha.pool`은 클라 상수). 그래서 파싱해서 굳힌다.
갱신을 잊어도 대시보드는 깨지지 않고 그 펫만 rawValue로 표시된다.

스프라이트 PNG는 서버가 `/sprite/<basename>.png`로 중계한다. SwiftPM 리소스 번들이 경로를
평탄화해 basename이 유일하다는 전제를 쓰며, 생성 스크립트가 그 전제를 검증한다.

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

## 테넌트 필터

헤더의 셀렉터가 **모든 탭에 동시에** 적용된다. 뷰는 테넌트별 행만 내고, "전체"는 대시보드가
합산한다 — 한 유저는 한 테넌트에만 속하므로 카운트·합계·활성 디바이스 수의 합산이 정확하다.

비율은 합산할 수 없어 원시 분자·분모로 다시 계산한다:

| 값 | 재계산 방식 |
|---|---|
| `accept_ratio` | `accepted_coins` 합 ÷ `reported_coins` 합 |
| `cleared_pct`(관장) | `cleared_by` 합 ÷ 선택 테넌트의 활성 유저 합 |
| `avg_variants`(펫) | 보유자 수 가중평균 |
| `last_seen`(버전) | 합계가 아니라 최댓값 |

## 탭

- **개요** — KPI 타일 + 최근 30일 활성 디바이스
- **사용량** — 일별 활성 디바이스 / 제출 처리 결과(전체·캡·거부) / 반영 코인
- **해금 진척** — 축별로 분리한다: 펫 해금(전체 종수 대비) / 이로치 해금(변종 1~3) /
  관장 격파(tier 스택 + 관장별 난이도 히트맵) / 컬렉션 완성. 하단 상세 표에서 서버 권위
  값(코인·제출)과 클라 자가 신고 값(stats·backup)을 대조할 수 있다.
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
- **이로치 vs 변종 총합** — `shiny_unlocked`는 변종 1~3만 센다. `variants_unlocked`는
  기본 변종(0)과 레인보우(4)까지 포함한 총합이라 진척 지표로 쓰면 안 된다 (펫 171종을
  보유하면 이로치가 0이어도 171이 나온다).
- **관장 격파 %** — 분모는 현재 만점(76)으로 통일했다. 개인 `badges_total`은 클라 버전마다
  달라(40·72·76) 그걸로 비율을 내면 막대 길이와 라벨이 어긋난다. 개인 기준치는 상세 표에서 본다.
- **펫 전체 종수** — 클라 `PetKind.allCases.count`(195)를 상수로 두되 관측 종수와 큰 값을
  분모로 쓴다. 펫이 추가돼도 상수를 갱신하지 않아 진척률이 100%를 넘는 일은 없다.
