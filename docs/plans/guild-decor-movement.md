# 장식 드래그 이동

시즌 6종을 포함한 장식 카탈로그 전체를 사무실 꾸미기에서 드래그할 수 있게 한다.
바닥은 x 자유 이동 + 3개 레인 스냅, 벽은 벽 영역 안에서 x/y 자유 이동이다.

- 기존 `guild_furniture` 행과 슬롯은 그대로 유지한다. 좌표가 NULL인 기존 행은 기존 슬롯
  위치로 표시하며, 처음 이동할 때만 좌표를 저장한다. 기부자·구매 시각·아이템은 바꾸지 않는다.
- `move_decor`는 재구매/제거 경로를 사용하지 않으며 코인을 차감하지 않는다.
- 위치 버전 UUID로 동시 편집을 검증한다. 장식이 교체·제거됐거나 다른 멤버가 먼저 이동하면
  저장을 거절하고 새로고침한다. 구버전 앱의 교체 구매도 DB 트리거가 위치/버전을 갱신한다.
- 방문객은 이동할 수 없고 길드 멤버만 가능하다. RPC 실행 권한은 service_role에만 부여한다.
- 렌더링, 펫 충돌 그리드, 방문 화면, 사진 촬영 모두 저장된 좌표를 사용한다.
- 보관함/프리셋은 기존 일반 가구 대상 그대로다. 이번 수정은 장식의 이동과 위치 유지에 한정한다.

배포 순서: `20261116011236_guild_decor_positions.sql` 마이그레이션 → `guild-office`,
`guild-info`, `guild-visit` 함수 → 앱 릴리스. DB보다 먼저 조회 함수를 배포하면 새 필드를
조회할 수 없으므로 반드시 순서를 지킨다. 구버전 앱은 이동 좌표를 무시하고 기존 슬롯에 표시한다.

검증: `OfficeDecorMovementTests`, `OfficeDecorMovementPreviews`,
`deno test supabase/functions/_shared/decor_position.test.ts`,
`POSTGRES_TEST_IMAGE=postgres:16-alpine bash scripts/test-decor-db.sh`.
