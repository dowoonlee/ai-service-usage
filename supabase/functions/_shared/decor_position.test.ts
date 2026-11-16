import { parseDecorMove } from "./decor_position.ts";
const version = "00000000-0000-0000-0000-000000000001";
Deno.test("decor move validates finite integer coordinates and version", () => {
  if (!parseDecorMove(JSON.stringify({ x: 100, y: 112, version }))) throw new Error("valid move rejected");
  for (const raw of ["null", "[]", "bad", JSON.stringify({ x: 100, y: 112 }),
    JSON.stringify({ x: 100.1, y: 112, version }), JSON.stringify({ x: 0, y: 112, version }),
    JSON.stringify({ x: 100, y: 151, version }), JSON.stringify({ x: 100, y: 112, version: "bad" }),
    JSON.stringify({ x: 100, y: 112, version, guildId: "other" })]) {
    if (parseDecorMove(raw)) throw new Error("invalid move accepted");
  }
});
