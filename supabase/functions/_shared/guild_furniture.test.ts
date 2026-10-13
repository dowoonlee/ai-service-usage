import {
  EMPTY_FURNITURE_LAYOUT,
  furnitureWriteError,
  isValidFurnitureLayout,
} from "./guild_furniture.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("가구 60개 허용, 61개 거부", () => {
  assert(
    isValidFurnitureLayout(Array(60).fill("0:35.0:0").join(";")),
    "60개 저장",
  );
  assert(
    !isValidFurnitureLayout(Array(61).fill("0:35.0:0").join(";")),
    "61개 차단",
  );
});

Deno.test("60개의 긴 문구 액자가 기존 1500자 제한을 넘어도 저장된다", () => {
  for (const text of ["가나다라마바사아자차", "😀".repeat(10)]) {
    const layout = Array(60).fill(`9:280.0:3:52.0:${encodeURIComponent(text)}`)
      .join(";");
    assert(layout.length > 1500, "기존 길이 한도 초과 fixture");
    assert(isValidFurnitureLayout(layout), "최대 문구 배치 저장");
  }
});

Deno.test("명시적 빈 사무실 허용, 초기 상태 문자열과 불완전 배치는 거부", () => {
  assert(isValidFurnitureLayout(EMPTY_FURNITURE_LAYOUT), "0개 저장");
  for (
    const layout of [
      "",
      "empty:v3",
      "0:35:0;",
      ":35:0",
      "0::0",
      "0:35:",
      "x".repeat(9001),
    ]
  ) {
    assert(
      !isValidFurnitureLayout(layout),
      `잘못된 배치: ${layout.slice(0, 20)}`,
    );
  }
});

Deno.test("구버전 요청과 기준 배치가 없는 요청을 차단한다", () => {
  for (const version of [undefined, null, 1, "2", 3]) {
    assert(
      furnitureWriteError(version, "") === "furniture_update_required",
      "구버전 덮어쓰기 방지",
    );
  }
  assert(
    furnitureWriteError(2, undefined) === "invalid_layout",
    "기준 배치 필수",
  );
  assert(
    furnitureWriteError(2, "x".repeat(9001)) === "invalid_layout",
    "기준 배치 길이 방어",
  );
  for (const expected of ["", "0:35:0", EMPTY_FURNITURE_LAYOUT]) {
    assert(
      furnitureWriteError(2, expected) === null,
      "신형 요청은 초기/빈/기존 배치 모두 허용",
    );
  }
});

Deno.test("기존 가구 종류/좌표/문구 검증 유지", () => {
  for (const layout of ["0:35:0", "9:100:3:hello", "8:220:3:40"]) {
    assert(isValidFurnitureLayout(layout), "기존 배치 허용");
  }
  for (
    const layout of [
      "11:35:0",
      "8:35:0",
      "0:35:3",
      "0:281:0",
      "0:NaN:0",
      "0:35:0:text",
      "9:35:3:40:%ZZ",
      "9:35:3:40:%0A",
    ]
  ) {
    assert(!isValidFurnitureLayout(layout), `잘못된 배치 차단: ${layout}`);
  }
});
