// 펫 카탈로그 추출기 — 클라 Swift 소스에서 표시 이름·희귀도·스프라이트 메타를 뽑아
// admin/pets.json 으로 굳힌다.
//
//   deno run --allow-read --allow-write admin/gen-pet-catalog.ts
//
// 왜 파싱인가: 이 셋의 SSOT가 전부 클라 코드다. `pet_metadata` 테이블은 79종만 있는
// override용이라 대시보드가 그것만 보면 대부분의 펫이 rawValue로 남는다. 서버는 희귀도를
// 아예 모른다(`Gacha.pool`은 클라 상수).
//
// 펫을 추가·수정한 뒤에는 이 스크립트를 다시 돌려 pets.json을 갱신할 것. 대시보드는 없는
// kind를 만나면 rawValue로 폴백하므로, 갱신을 잊어도 깨지지는 않고 이름만 투박해진다.

const ROOT = new URL("../", import.meta.url).pathname;
const SPRITE_SRC = `${ROOT}Sources/ClaudeUsage/PetSprite.swift`;
const GACHA_SRC = `${ROOT}Sources/ClaudeUsage/Gacha.swift`;
const OUT = `${ROOT}admin/pets.json`;

const spriteSwift = await Deno.readTextFile(SPRITE_SRC);
const gachaSwift = await Deno.readTextFile(GACHA_SRC);

// ── 1. PetDefinition — `case .fox:` 다음의 PetDefinition(...) 인자를 읽는다.
// 형태가 한 가지로 고정돼 있어(줄바꿈만 다양) 인자별 정규식으로 충분하다.
type Def = {
  kind: string;
  displayName: string;
  prefix: string;
  idleSuffix: string;
  cellW: number;
  cellH: number;
  facingLeft: boolean;
};
const defs: Def[] = [];
// `case .x:` 와 `return PetDefinition(` 사이에는 주석 줄이 끼기도 한다(실제로 archer·pawn·
// whale·rock1이 그렇다). 그 구간을 허용하되 다음 `case .y:` 를 넘어가지는 않도록 막는다.
const defRe =
  /case\s+\.(\w+):((?:(?!case\s+\.\w+:)[\s\S])*?)return\s+PetDefinition\(([\s\S]*?)\)\n/g;
for (const m of spriteSwift.matchAll(defRe)) {
  const kind = m[1];
  const body = m[3];
  const str = (k: string) => body.match(new RegExp(`${k}:\\s*"([^"]*)"`))?.[1];
  const cell = body.match(/cellSize:\s*\((\d+),\s*(\d+)\)/);
  const prefix = str("prefix");
  const displayName = str("displayName");
  const idleSuffix = str("idleSuffix");
  if (!prefix || !displayName || !idleSuffix || !cell) continue;
  defs.push({
    kind,
    displayName,
    prefix,
    idleSuffix,
    cellW: Number(cell[1]),
    cellH: Number(cell[2]),
    facingLeft: /defaultFacingLeft:\s*true/.test(body),
  });
}

// ── 2. Gacha.pool — `.rarity: [.a, .b, …],` 블록에서 등급별 kind 목록.
const rarityByKind = new Map<string, string>();
const poolBlock = gachaSwift.match(/static let pool:[\s\S]*?\n\s*\]\n/)?.[0] ?? "";
for (const m of poolBlock.matchAll(/\.(\w+):\s*\[([\s\S]*?)\]/g)) {
  const rarity = m[1];
  for (const k of m[2].matchAll(/\.(\w+)/g)) rarityByKind.set(k[1], rarity);
}

// ── 3. 스프라이트 파일 실재 확인. SwiftPM 리소스는 번들에서 평탄화되므로 basename이
//       유일하다(CLAUDE.md) — 그 전제를 여기서도 검증한다.
const spriteIndex = new Map<string, string>();
const dupes: string[] = [];
async function walk(dir: string) {
  for await (const e of Deno.readDir(dir)) {
    const p = `${dir}/${e.name}`;
    if (e.isDirectory) await walk(p);
    else if (e.name.endsWith(".png")) {
      if (spriteIndex.has(e.name)) dupes.push(e.name);
      else spriteIndex.set(e.name, p.slice(ROOT.length));
    }
  }
}
await walk(`${ROOT}Sources/ClaudeUsage/Resources`);

const RARITY_ORDER = ["mythic", "legendary", "epic", "rare", "common"];
const pets: Record<string, unknown> = {};
const missingSprite: string[] = [];
const missingRarity: string[] = [];

for (const d of defs) {
  const file = `${d.prefix}_${d.idleSuffix}.png`;
  if (!spriteIndex.has(file)) missingSprite.push(`${d.kind} → ${file}`);
  const rarity = rarityByKind.get(d.kind);
  if (!rarity) missingRarity.push(d.kind);
  pets[d.kind] = {
    name: d.displayName,
    rarity: rarity ?? "common",
    rarityRank: RARITY_ORDER.indexOf(rarity ?? "common"),
    sprite: file,
    // 팩 이름 — 방향 검수는 팩 단위로 봐야 한다. facing이 팩 전체에서 통째로 뒤집혀 있으면
    // "팩 내 소수파 찾기"로는 절대 안 걸린다(실제로 grafxkid 계열이 그랬다).
    pack: (spriteIndex.get(file) ?? "").split("/")[3] ?? "?",
    cellW: d.cellW,
    cellH: d.cellH,
    facingLeft: d.facingLeft,
  };
}

await Deno.writeTextFile(
  OUT,
  JSON.stringify({ generatedFrom: "Sources/ClaudeUsage", pets }, null, 0) + "\n",
);

console.log(`펫 ${defs.length}종 → admin/pets.json`);
const byRarity = RARITY_ORDER.map((r) =>
  `${r} ${[...rarityByKind.values()].filter((v) => v === r).length}`
).join(" · ");
console.log(`  희귀도: ${byRarity}`);
if (dupes.length) console.warn(`  ⚠ basename 중복 ${dupes.length}건: ${dupes.slice(0, 5).join(", ")}`);
if (missingSprite.length) {
  console.warn(`  ⚠ 스프라이트 없음 ${missingSprite.length}건: ${missingSprite.slice(0, 5).join(", ")}`);
}
if (missingRarity.length) {
  console.warn(`  ⚠ Gacha.pool 미등재 ${missingRarity.length}건: ${missingRarity.slice(0, 8).join(", ")}`);
}
