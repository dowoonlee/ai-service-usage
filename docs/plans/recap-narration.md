# 리캡 개인화 내레이션

2026-11-13 결정: 사용자·리캡 연도·펫 **종**별로 한 번 생성한 대사를 재사용한다. 색상 variant,
현재 통계, 앱 버전, 프롬프트 버전이 바뀌어도 성공한 대사는 다시 생성하지 않는다.

## 흐름

1. 클라이언트가 계정·연도·종으로 분리된 로컬 캐시를 확인한다.
2. 없으면 랭킹 계정의 HMAC으로 `recap-narration`에 통계 요약을 보낸다. 원본 스냅샷,
   닉네임, 계정 식별자는 Claude 프롬프트에 넣지 않는다.
3. 서버는 `recap_narrations`의 완료 행을 우선 반환한다. 없으면 DB claim으로 생성 작업 하나를
   선점하고, `EdgeRuntime.waitUntil`에서 Claude 생성과 저장을 마친다. 앱은 pending을 조회한다.
4. Claude는 기존 `ANTHROPIC_API_KEY` / 선택적 `ANTHROPIC_BASE_URL`,
   `ANTHROPIC_WORKSPACE_ID`를 사용한다. 모델은 운세의 `CLAUDE_MODEL`과 같다.
5. 도감 `PetDescriptions`와 펫 이름을 서버용으로 생성해 성격 근거로 제공한다. 13장면과 성격
   요약을 JSON schema로 생성하고, 모든 장면·길이를 검사한 결과만 저장한다.

처음 대사를 만든 날짜를 화면에 표시한다. 대사는 최초 생성 당시의 요약을 바탕으로 하며,
리캡 차트와 숫자는 창을 열 때의 기록이다. 사용량은 2026년, 게임 통계는 누적값이다.
랭킹 미등록·오프라인·생성 실패 때에는 기존 로컬 기본 대사를 사용한다.

## 저장·권한·실패

- PK: `(device_id, recap_year, pet_kind)`. 계정 복구 시 같은 device_id를 쓰므로 같은 이야기를
  받고, 계정 삭제 시 FK cascade로 서버 캐시도 삭제된다.
- RLS 활성. 테이블과 RPC는 `service_role`만 접근하며, Edge Function이 본인 HMAC을 검증한다.
- 사용자 행에 짧은 트랜잭션 락을 걸어 동시 claim을 직렬화한다. Claude 호출 중에는 DB 락을
  잡지 않는다. 사용자당 동시에 진행하는 생성은 하나다.
- lease는 3분, Claude timeout은 80초다. 만료된 작업의 token은 새 작업 결과를 덮어쓸 수 없다.
- 저장 오류는 같은 생성 결과의 저장만 최대 3회 시도한다. 생성 실패는 15분 cooldown,
  동일 캐시 키의 생성 시도는 최대 3회다. 성공한 결과는 자동 갱신하지 않는다.
- worker 강제 종료 등으로 lease가 만료되면 재요청에서 복구한다. 외부 API 호출과 DB 저장은
  하나의 트랜잭션이 아니므로, 이 장애 구간에서만 제한된 재생성이 발생할 수 있다.
- 현재 리캡은 2026 전용이다. 다음 연도 지원 시 서버/DB의 허용 연도와 `RecapFacts.year`를
  함께 변경해야 한다.

## 검증

```bash
swift test
deno test supabase/functions/_shared/
deno check supabase/functions/recap-narration/index.ts
bash scripts/test-recap-db.sh  # postgres:17.6-alpine 이미지 필요
RECAP_PREVIEW_OUT=/tmp/recap-samples.json bash scripts/recap_e2e.sh
PREVIEW_OUT_DIR=/tmp/recap-previews RECAP_CLAUDE_SAMPLES=/tmp/recap-samples.json swift test --filter RecapPreviews
```

E2E는 합성 통계와 임시 계정으로 곰/닌자 개구리를 생성하고, 동시·반복 호출에 대한 DB
attempts=1과 동일 대사를 확인한다. 종료 시 테스트 계정과 서버 캐시를 지운다.

v0.20.2에서는 사용자 요청에 따라 기존 0.20.0 앱 공지를 그대로 유지한다.
