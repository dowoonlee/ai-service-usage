import { makeBattle, legalCommands, chooseAI, submit, resolve, ultimate, publicState, masteryAwards, State, Command } from "./manual_battle.ts";
import { RARITY } from "./pet_meta_gen.ts";
import { battleTypeOf } from "./pvp_policy.ts";

// No registry dependency: the battle parity suite must run offline like the existing ATB suite.
function assert(value: unknown, message = "assertion failed"): asserts value { if (!value) throw new Error(message); }
function assertEquals(actual: unknown, expected: unknown, message = "values differ") {
  const a = JSON.stringify(canonical(actual)), e = JSON.stringify(canonical(expected));
  if (a !== e) throw new Error(`${message}\nactual: ${a}\nexpected: ${e}`);
}
function assertThrows(run: () => unknown) { let threw = false; try { run(); } catch { threw = true; } assert(threw, "expected rejection"); }

const team = ["fox", "warrior", "scrapBot"].map(kind => ({ kind, variant: 4, enhanceLevel: 0, progressUnits: 0 }));
Deno.test("manual engine completes deterministic games with legal commands", () => {
  for (let seed = 1; seed <= 100; seed++) {
    let s = makeBattle(team, [...team].reverse(), BigInt(seed), "test");
    let steps = 0;
    while (!s.outcome && steps++ < 100) {
      const command = chooseAI(s, 0)!;
      assert(legalCommands(s, 0).some(c => JSON.stringify(c) === JSON.stringify(command)));
      assertEquals(submit(s, command), submit(s, command));
      s = submit(s, command);
    }
    assert(s.outcome); assert(s.turn <= 40);
  }
});
Deno.test("public projection hides seed and precommitted opponent move", () => {
  const s = makeBattle(team, [...team].reverse(), 111n, "test");
  assert(s.committedAI);
  const visible = publicState(s);
  assertEquals(visible.seed, "0"); assertEquals(visible.randomState, "0");
  assertEquals(visible.committedAI, undefined);
  assertEquals(s.seed, "111");
});
Deno.test("invalid commands and forged payloads cannot advance a battle", () => {
  const s = makeBattle(team, [...team].reverse(), 111n, "test"), initial = structuredClone(s);
  for (const command of [{ move: { _0: "fake" } }, { swap: { _0: 0 } }, { swap: { _0: 999 } }, { surrender: {}, move: { _0: "fake" } }]) {
    assertThrows(() => submit(s, command as Command)); assertEquals(s, initial);
  }
});
Deno.test("official medals require verified rainbow participation and a completed victory", () => {
  const s = makeBattle(team, [...team].reverse(), 111n, "test");
  s.outcome = { winner: 0, reason: "knockout" };
  s.teams[0].fighters[0].participated = true; s.teams[0].fighters[0].ultimateUsed = true;
  assertEquals(masteryAwards(s, []), []);
  assertEquals(masteryAwards(s, ["fox", "warrior"]), [{ kind: "fox", branch: "original" }]);
  s.outcome.reason = "surrender"; assertEquals(masteryAwards(s, ["fox"]), []);
});

Deno.test("checkpoint achievement evidence counts actual healed allies, not merely targets", () => {
  const mascot = Object.keys(RARITY).find(k => battleTypeOf(k) === "mascot")!;
  const allies = [mascot, "fox", "warrior"].map(kind => ({ kind, variant: 4, enhanceLevel: 0, progressUnits: 0 }));
  const initial = makeBattle(allies, team, 33n, "test", { [mascot]: "alternate" });
  initial.teams[0].charge = 10;
  for (const f of initial.teams[0].fighters) f.hp = Math.max(1, Math.floor(f.stats.hp / 2));
  const all = resolve(initial, [{ move: { _0: ultimate("mascot", "alternate").id } }, { guardMove: {} }]);
  assert(all.events.some(e => e.kind === "achievementFact" && e.moveID === "team_recovery"));
  initial.teams[0].fighters[2].hp = initial.teams[0].fighters[2].stats.hp;
  const two = resolve(initial, [{ move: { _0: "checkpoint" } }, { guardMove: {} }]);
  assert(!two.events.some(e => e.kind === "achievementFact" && e.moveID === "team_recovery"));
});

// Generate with MANUAL_PARITY_OUT=... swift test --filter testExportServerParityVectors.
// Fixture is checked in so ordinary Deno tests detect drift without requiring Swift on the server.
function canonical(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).filter(([key, value]) => !["text", "name", "summary"].includes(key) && value != null)
      .sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => [k, canonical(v)]));
  }
  return value;
}
import vectors from "./manual_battle.vectors.json" with { type: "json" };
Deno.test("Swift and TypeScript match every turn across all 12 ultimate branches", () => {
  for (const vector of vectors) {
    const base = vector.base as unknown as State;
    const branches = Object.fromEntries(base.teams[0].fighters.map(f => [f.pet.kind, f.branch]));
    const made = makeBattle(base.teams[0].fighters.map(f => f.pet), base.teams[1].fighters.map(f => f.pet), BigInt(base.seed), base.id, branches);
    assertEquals(canonical(made), canonical(base), "battle creation / policy parity");
    let state = vector.initial as unknown as State;
    for (const step of vector.steps) {
      const count = state.events.length;
      state = submit(state, step.command as Command);
      const projection = { turn: state.turn, revision: state.revision, randomState: state.randomState,
        outcome: state.outcome, committedAI: state.committedAI, effectSequence: state.effectSequence,
        teams: state.teams.map(t => ({ active: t.active, charge: t.charge, lastGuard: t.lastGuard, lastSwitch: t.lastSwitch,
          fighters: t.fighters.map(f => ({ hp: f.hp, pp: f.pp, effects: f.effects, immuneUntil: f.immuneUntil,
            participated: f.participated, ultimateUsed: f.ultimateUsed })) })), events: state.events.slice(count) };
      assertEquals(canonical(projection), canonical(step.expected), `battle ${state.id}, revision ${state.revision}`);
    }
  }
});
