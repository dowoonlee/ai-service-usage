import {
  isValidOfficeStudio,
  type OfficeStudio,
  parseOfficeStudio,
  studioFromLegacy,
  studioLayout,
  studioTransitionError,
} from "./guild_furniture.ts";
function assert(value: unknown, label: string) {
  if (!value) throw new Error(label);
}
const copy = (s: OfficeStudio) => structuredClone(s);

Deno.test("기존 기본/구매 가구를 안정 id로 이전하고 빈 방을 구분한다", () => {
  const initial = studioFromLegacy("");
  assert(
    initial.items.length === 5 && initial.items[4].id === "legacy-4",
    "기본 가구 보존",
  );
  const custom = studioFromLegacy(
    "0:35:0;9:180:3:40:%EC%95%88%EB%85%95;8:70:3:35",
  );
  assert(
    custom.items.length === 3 && custom.items[1].text === "안녕",
    "문구/구매 가구 보존",
  );
  assert(isValidOfficeStudio(custom), "이전한 상태 유효");
  assert(
    studioFromLegacy("empty:v2").items.length === 0,
    "빈 방은 기본 가구를 복구하지 않음",
  );
  assert(
    studioLayout(studioFromLegacy(studioLayout(custom))) ===
      studioLayout(custom),
    "레거시 조회 왕복",
  );
});

Deno.test("보관과 꺼내기는 동일 소유 가구를 유지하고 추가 구매하지 않는다", () => {
  const before = studioFromLegacy("");
  const stored = copy(before);
  stored.items.forEach((i) => i.stored = true);
  assert(
    studioTransitionError(before, stored, "arrange", undefined) === null,
    "전체 보관 허용",
  );
  assert(studioLayout(stored) === "empty:v2", "방에서는 보이지 않음");
  assert(
    studioTransitionError(stored, before, "arrange", undefined) === null,
    "꺼내기/실행 취소 허용",
  );
  assert(stored.items.length === before.items.length, "보유 개수 유지");
});

Deno.test("프리셋은 보유 가구의 위치만 참조하고 가구 복제를 차단한다", () => {
  const before = studioFromLegacy("");
  const after = copy(before);
  after.presets.push({
    id: "preset-1",
    name: "카페",
    positions: [{ itemID: "legacy-0", x: 70, lane: 1 }],
  });
  assert(isValidOfficeStudio(after), "정상 프리셋");
  assert(
    studioTransitionError(before, after, "presets", undefined) === null,
    "프리셋 저장",
  );
  after.presets[0].positions.push({ itemID: "not-owned", x: 70, lane: 1 });
  assert(!isValidOfficeStudio(after), "미보유 가구 참조 차단");
  after.presets[0].positions[1].itemID = "legacy-0";
  assert(!isValidOfficeStudio(after), "같은 가구를 두 번 배치할 수 없음");
});

Deno.test("배치 편집/프리셋 API로 구매하지 않은 가구를 추가할 수 없다", () => {
  const before = studioFromLegacy("");
  const after = copy(before);
  after.items.push({ ...after.items[0], id: "new-item" });
  for (const action of ["arrange", "presets", "delete"]) {
    assert(
      studioTransitionError(before, after, action, 0) !== null,
      "추가 가구는 구매만 허용",
    );
  }
  assert(
    studioTransitionError(before, after, "purchase", 0) === null,
    "올바른 1개 구매",
  );
  assert(
    studioTransitionError(before, after, "purchase", 9) !== null,
    "종류 바꿔치기 차단",
  );
  after.items[0].kind = 2;
  assert(
    studioTransitionError(before, after, "purchase", 0) !== null,
    "기존 가구 종류 변조 차단",
  );
});

Deno.test("영구 삭제는 한 개만 제거하고 프리셋 참조도 정리해야 한다", () => {
  const before = studioFromLegacy("");
  before.presets.push({
    id: "p",
    name: "책상",
    positions: [{ itemID: "legacy-0", x: 35, lane: 0 }],
  });
  const after = copy(before);
  after.items.shift();
  after.presets[0].positions = [];
  assert(
    studioTransitionError(before, after, "delete", undefined) === null,
    "1개 삭제 허용",
  );
  assert(
    studioTransitionError(after, before, "arrange", undefined) !== null,
    "undo로 삭제 가구 복구 불가",
  );
  after.items.shift();
  assert(
    studioTransitionError(before, after, "delete", undefined) !== null,
    "일괄 삭제 방지",
  );
});

Deno.test("보유 180개, 배치 60개, 프리셋 5개 제한과 입력 검증", () => {
  const base = studioFromLegacy("").items[0];
  const state: OfficeStudio = {
    version: 1,
    items: Array.from(
      { length: 180 },
      (_, i) => ({ ...base, id: `item-${i}`, stored: i >= 60 }),
    ),
    presets: [],
  };
  assert(isValidOfficeStudio(state), "상한 경계 허용");
  state.items[60].stored = false;
  assert(!isValidOfficeStudio(state), "배치 61개 차단");
  state.items[60].stored = true;
  state.items.push({ ...base, id: "extra", stored: true });
  assert(!isValidOfficeStudio(state), "보유 181개 차단");
  state.items.pop();
  state.presets = Array.from(
    { length: 5 },
    (_, i) => ({ id: `p-${i}`, name: "방", positions: [] }),
  );
  assert(isValidOfficeStudio(state), "빈 프리셋도 허용");
  state.presets.push({ id: "p-6", name: "방", positions: [] });
  assert(!isValidOfficeStudio(state), "프리셋 6개 차단");
  assert(parseOfficeStudio("{") === null, "잘못된 JSON");
  assert(parseOfficeStudio("x".repeat(120001)) === null, "과대한 payload 차단");
});

Deno.test("클라이언트 JSON 키 순서 차이와 숫자 액자 문구를 허용한다", () => {
  const before = studioFromLegacy("9:100:3:40:hello");
  const after = JSON.parse(
    '{"presets":[],"items":[{"stored":false,"text":"2026","wallY":40,"lane":3,"x":100,"kind":9,"id":"legacy-0"}],"version":1}',
  );
  assert(isValidOfficeStudio(after), "좌표가 아닌 숫자 문구 허용");
  assert(
    studioTransitionError(before, after, "arrange", undefined) === null,
    "문구 변경",
  );
  after.items[0].text = "\ud800";
  assert(!isValidOfficeStudio(after), "깨진 유니코드는 예외 없이 거부");
});
