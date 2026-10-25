// Interactive rules v1. Keep numerical state and event payloads in parity with ManualBattleEngine.swift.
import { BattleStats, BattleType, StatKind, battleTypeOf, collectionOf, computeStats, teamSynergyBonus,
  skillsFor, ultimateSkill, skillEffectiveness, stabMult, matchup, roundAway, EFFECTS } from "./pvp_policy.ts";
import { BattlePetSnapshot } from "./battle_engine.ts";
import { RARITY } from "./pet_meta_gen.ts";

export type Branch = "original" | "alternate";
export type Command = { move: { _0: string } } | { swap: { _0: number } } | { replacement: { _0: number } }
  | { guardMove: Record<string, never> } | { surrender: Record<string, never> };
export interface Move { id: string; name: string; type: BattleType; power: number; maxPP?: number;
  effect?: string; chance: number; selfTarget: boolean; ultimate: boolean; special?: string; summary: string }
export interface Effect { id: string; applied: number; expires: number; sequence: number; shield: number }
export interface Fighter { id: number; pet: BattlePetSnapshot; stats: BattleStats; hp: number; moves: Move[];
  pp: Record<string, number>; branch: Branch; effects: Effect[]; immuneUntil: number; participated: boolean; ultimateUsed: boolean }
export interface Team { fighters: Fighter[]; active: number; charge: number; lastGuard: number; lastSwitch: number }
export interface Event { id: number; turn: number; side: number; slot: number; kind: string; text: string;
  hp?: number; amount?: number; moveID?: string }
export interface State { id: string; rulesVersion: number; turn: number; revision: number; teams: Team[];
  seed: string; randomState: string; events: Event[]; outcome?: { winner: number | null; reason: string };
  committedAI?: Command; tutorial: boolean; effectSequence: number; achievementsEligible?: boolean }
export const control = (id: string) => ["deadlock", "rate_limited", "outage_stun"].includes(id);
export const shield = (id: string) => ["load_balancer", "safe_shield"].includes(id);
export const buff = (id: string) => ["optimization", "firewall", "caching", "load_balancer", "autoscaling", "safe_shield"].includes(id);
const duration = (id: string) => ["deadlock", "bsod_lag", "spread_dot"].includes(id) ? 2 : ["rate_limited", "outage_stun"].includes(id) ? 1 : id === "hot_reload" ? 0 : 3;
const magnitude = (id: string) => ({ mem_leak: .05, spread_dot: .05, infinite_loop: .08, autoscaling: .06, load_balancer: .2, safe_shield: .3 }[id] ?? 0);
const effectName = (id: string) => id === "spread_dot" ? "장애 전파" : id === "safe_shield" ? "세이프 모드" : EFFECTS[id]?.name ?? id;
const active = (s: State, side: number) => s.teams[side].fighters[s.teams[side].active];
const alive = (team: Team) => team.fighters.some(f => f.hp > 0);
const replacement = (team: Team) => alive(team) && team.fighters[team.active].hp <= 0;
const moveCmd = (id: string): Command => ({ move: { _0: id } });
const slotCmd = (slot: number, replace: boolean): Command => replace ? { replacement: { _0: slot } } : { swap: { _0: slot } };
const same = (a: Command, b: Command) => JSON.stringify(a) === JSON.stringify(b);
const emit = (s: State, side: number, kind: string, text: string, slot = s.teams[side].active, extra: Partial<Event> = {}) => {
  s.events.push({ id: s.events.length, turn: s.turn, side, slot, kind, text, ...extra });
};
const mask = (n: bigint) => BigInt.asUintN(64, n);
function next(s: State): bigint {
  const value = mask(BigInt(s.randomState) + 0x9E3779B97F4A7C15n); s.randomState = String(value);
  let z = mask((value ^ (value >> 30n)) * 0xBF58476D1CE4E5B9n);
  z = mask((z ^ (z >> 27n)) * 0x94D049BB133111EBn);
  return z ^ (z >> 31n);
}
const uniform = (s: State) => Number(next(s) >> 11n) / 9007199254740992;

export function ultimate(type: BattleType, branch: Branch): Move {
  const base = ultimateSkill(type);
  const m: Move = { id: base.id, name: base.name, type, power: 24, chance: 1, selfTarget: false, ultimate: true, summary: "" };
  if (branch === "original") {
    const changes: Record<BattleType, Partial<Move>> = {
      beast: { special: "splash", summary: "상대 벤치에 직접 피해의 30%" },
      warrior: { special: "pierce", summary: "상대 방어력의 30%로 피해 계산" },
      chaos: { effect: "outage_stun", summary: "다음 턴 행동불가" },
      arcane: { special: "critical", summary: "확정 치명타 1.5배" },
      machine: { effect: "bsod_lag", summary: "상대 속도 40% 감소 · 2턴" },
      mascot: { special: "healSelf", summary: "공격 후 자신의 최대 HP 25% 회복" },
    };
    return { ...m, ...changes[type] };
  }
  const changes: Record<BattleType, Partial<Move>> = {
    beast: { id: "focused_debug", name: "집중 디버깅", power: 30, summary: "광역 없이 한 상대에게 강한 공격" },
    warrior: { id: "rolling_deploy", name: "롤링 배포", power: 18, effect: "firewall", selfTarget: true, summary: "공격 후 자신의 방어력 30% 증가 · 3턴" },
    chaos: { id: "cascading_failure", name: "장애 전파", power: 16, special: "spread", summary: "상대 생존 전원에게 최대 HP 5% 지속 피해 · 2턴" },
    arcane: { id: "cache_invalidation", name: "캐시 무효화", power: 18, special: "dispelShield", summary: "상대 실드를 제거한 뒤 공격" },
    machine: { id: "safe_mode", name: "세이프 모드", power: 16, effect: "safe_shield", selfTarget: true, summary: "공격 후 최대 HP 30% 실드 · 3턴" },
    mascot: { id: "checkpoint", name: "체크포인트", power: 0, special: "healTeam", summary: "공격 없이 살아 있는 아군 전체 HP 15% 회복" },
  };
  return { ...m, ...changes[type] };
}

export function makeBattle(a: BattlePetSnapshot[], b: BattlePetSnapshot[], seed: bigint, id: string,
  branchesA: Record<string, Branch> = {}, branchesB: Record<string, Branch> = {}): State {
  if (a.length !== b.length || a.length < 1 || a.length > 5) throw new Error("invalid_team");
  const teams = [a, b].map((members, side): Team => {
    if (new Set(members.map(p => p.kind)).size !== members.length || members.some(p =>
      !Object.hasOwn(RARITY, p.kind) || !Number.isInteger(p.variant) || p.variant < 0 || p.variant > 4 ||
      !Number.isInteger(p.enhanceLevel) || p.enhanceLevel < 0 || p.enhanceLevel > 15 ||
      !Number.isFinite(p.progressUnits) || p.progressUnits < 0 || p.progressUnits > 8)) throw new Error("invalid_team");
    const bonus = teamSynergyBonus(members.map(p => p.kind));
    const fighters = members.map((pet, slot): Fighter => {
      const stats = computeStats(pet.kind, pet.variant, pet.enhanceLevel, pet.progressUnits);
      for (const stat of ["hp", "atk", "def", "spd"] as StatKind[]) {
        stats[stat] = Math.max(1, roundAway(stats[stat] * (1 + Math.min(.1, bonus.collectionMult - 1) + (bonus.typeStat === stat ? Math.min(.05, bonus.typeAdd) : 0))));
      }
      const branch = (side === 0 ? branchesA : branchesB)[pet.kind] ?? "original";
      if (!["original", "alternate"].includes(branch)) throw new Error("invalid_branch");
      const moves: Move[] = skillsFor(pet.kind, pet.variant).map(m => ({ id: m.id, name: m.name, type: m.type,
        power: m.tier === "typeShared" ? 6 : m.power, ...(m.tier === "generic" ? {} : { maxPP: m.tier === "unique" ? 2 : 3 }),
        effect: m.rider?.effectId, chance: m.tier === "typeShared" ? 1 : m.rider?.chance ?? 0,
        selfTarget: m.rider?.selfTarget ?? false, ultimate: false, summary: m.rider ? `${Math.round((m.tier === "typeShared" ? 1 : m.rider.chance) * 100)}% · ${effectName(m.rider.effectId)}` : "추가 효과 없음" }));
      if (pet.variant >= 4) moves.push(ultimate(battleTypeOf(pet.kind), branch));
      return { id: slot, pet, stats, hp: stats.hp, moves, pp: Object.fromEntries(moves.filter(m => m.maxPP != null).map(m => [m.id, m.maxPP!])),
        branch, effects: [], immuneUntil: 0, participated: false, ultimateUsed: false };
    });
    return { fighters, active: 0, charge: 0, lastGuard: -1, lastSwitch: -1 };
  });
  const s: State = { id, rulesVersion: 1, turn: 1, revision: 0, teams, seed: String(seed), randomState: String(seed || 0x9E3779B97F4A7C15n), events: [], tutorial: false, effectSequence: 0 };
  s.committedAI = chooseAI(s, 1); return s;
}

export function stat(f: Fighter, key: StatKind): number {
  let multiplier = 1;
  for (const e of f.effects) {
    const value: Record<string, number> = { "atk:tech_debt": .8, "atk:optimization": 1.25, "def:firewall": 1.3,
      "spd:legacy": .75, "spd:bsod_lag": .6, "spd:caching": 1.25 };
    multiplier *= value[`${key}:${e.id}`] ?? 1;
  }
  return Math.max(1, roundAway(f.stats[key] * multiplier));
}
export function damageEstimate(m: Move, from: Fighter, to: Fighter, factor = .95, guarded = false): number {
  if (m.power <= 0) return 0;
  const defense = stat(to, "def") * (m.special === "pierce" ? .3 : 1);
  const raw = stat(from, "atk") / Math.max(1, defense) * m.power * skillEffectiveness(m.type, battleTypeOf(to.pet.kind))
    * stabMult(m.type, battleTypeOf(from.pet.kind)) * matchup(collectionOf(from.pet.kind), collectionOf(to.pet.kind)).mult
    * factor * (m.special === "critical" ? 1.5 : 1) * (guarded ? .5 : 1);
  return Math.max(1, roundAway(raw));
}
export function legalCommands(s: State, side: number): Command[] {
  if (s.outcome || ![0, 1].includes(side)) return [];
  const t = s.teams[side];
  if (replacement(t)) return t.fighters.filter(f => f.hp > 0).map(f => slotCmd(f.id, true));
  if (s.teams.some(replacement)) return [];
  const f = active(s, side);
  const commands: Command[] = f.moves.filter(m => !(m.ultimate && t.charge < 10) && !(m.maxPP != null && (f.pp[m.id] ?? 0) <= 0)
    && !(m.special === "healTeam" && !t.fighters.some(f => f.hp > 0 && f.hp < f.stats.hp))).map(m => moveCmd(m.id));
  commands.push(...t.fighters.filter(f => f.id !== t.active && f.hp > 0).map(f => slotCmd(f.id, false)));
  if (t.lastGuard !== s.turn - 1) commands.push({ guardMove: {} });
  return commands;
}
function hurt(s: State, side: number, slot: number, amount: number): { hp: number; total: number } {
  const f = s.teams[side].fighters[slot];
  if (f.hp <= 0) return { hp: 0, total: 0 };
  let remaining = amount;
  for (const e of f.effects) if (e.shield > 0) { const n = Math.min(remaining, e.shield); e.shield -= n; remaining -= n; }
  f.effects = f.effects.filter(e => !(shield(e.id) && e.shield === 0));
  const hp = Math.min(f.hp, remaining); f.hp -= hp;
  if (f.hp === 0) f.effects = [];
  emit(s, side, "damage", `${f.pet.kind} HP −${hp}`, slot, { hp: f.hp, amount: hp });
  if (f.hp === 0) emit(s, side, "fainted", `${f.pet.kind} 기절!`, slot);
  return { hp, total: hp + amount - remaining };
}
function heal(s: State, side: number, slot: number, fraction: number): boolean {
  const f = s.teams[side].fighters[slot]; if (f.hp <= 0) return false;
  const amount = Math.min(f.stats.hp - f.hp, Math.max(1, roundAway(f.stats.hp * fraction)));
  if (amount <= 0) return false;
  f.hp += amount; emit(s, side, "healed", `${f.pet.kind} HP +${amount}`, slot, { hp: f.hp, amount }); return true;
}
function grant(s: State, side: number, slot: number, id: string): boolean {
  const f = s.teams[side].fighters[slot]; if (f.hp <= 0 || (control(id) && f.immuneUntil >= s.turn)) return false;
  const before = JSON.stringify(f.effects);
  if (id === "hot_reload") f.effects = f.effects.filter(e => buff(e.id));
  else {
    const strength = shield(id) ? Math.max(1, roundAway(f.stats.hp * magnitude(id))) : 0;
    const expires = s.turn + duration(id), existingShield = f.effects.findIndex(e => shield(e.id)), idx = f.effects.findIndex(e => e.id === id);
    const create = (): Effect => ({ id, applied: s.turn, expires, sequence: ++s.effectSequence, shield: strength });
    if (shield(id) && existingShield >= 0) {
      const old = f.effects[existingShield];
      if (strength > old.shield || (strength === old.shield && expires > old.expires)) f.effects[existingShield] = create();
    } else if (idx >= 0) f.effects[idx].expires = Math.max(f.effects[idx].expires, expires);
    else {
      if (f.effects.length >= 4) {
        const oldest = [...f.effects].sort((a, b) => a.expires - b.expires || a.sequence - b.sequence)[0];
        f.effects = f.effects.filter(e => e !== oldest);
      }
      f.effects.push(create());
    }
  }
  if (before === JSON.stringify(f.effects)) return false;
  emit(s, side, "effectApplied", `${f.pet.kind} · ${effectName(id)}`, slot); return true;
}
function skip(s: State, side: number): boolean {
  const f = active(s, side); if (f.immuneUntil >= s.turn) return false;
  const controls = f.effects.filter(e => control(e.id) && e.applied < s.turn && e.expires >= s.turn);
  const skipped = controls.some(e => e.id !== "deadlock") || (controls.length > 0 && uniform(s) < .35);
  if (skipped) {
    f.effects = f.effects.filter(e => !control(e.id)); f.immuneUntil = s.turn + 2;
    emit(s, side, "actionSkipped", `${f.pet.kind} 행동불가! 이후 2턴 면역입니다.`);
  }
  return skipped;
}
function endTurn(s: State) {
  for (let side = 0; side < 2; side++) for (const f of s.teams[side].fighters) if (f.hp > 0) {
    let delta = 0;
    for (const e of f.effects) if (e.applied < s.turn && e.expires >= s.turn) {
      const amount = Math.max(1, roundAway(f.stats.hp * magnitude(e.id)));
      if (["mem_leak", "infinite_loop", "spread_dot"].includes(e.id)) delta -= amount;
      else if (e.id === "autoscaling") delta += amount;
    }
    if (s.turn >= 25) delta -= Math.max(1, roundAway(f.stats.hp * .05));
    const hp = Math.max(0, Math.min(f.stats.hp, f.hp + delta));
    if (hp !== f.hp) emit(s, side, "residual", `${f.pet.kind} · 턴 종료 HP ${hp - f.hp}`, f.id, { hp, amount: hp - f.hp });
    f.hp = hp;
    if (hp === 0) { f.effects = []; emit(s, side, "fainted", `${f.pet.kind} 기절!`, f.id); }
    else f.effects = f.effects.filter(e => e.expires > s.turn);
  }
  observeComeback(s);
  const a = alive(s.teams[0]), b = alive(s.teams[1]);
  if (!a || !b) s.outcome = { winner: a ? 0 : b ? 1 : null, reason: "knockout" };
  else if (s.turn >= 40) s.outcome = { winner: null, reason: "turnLimit" };
  if (s.outcome) emit(s, s.outcome.winner ?? 0, "battleEnded", s.outcome.winner === null ? "무승부" : s.outcome.winner === 0 ? "승리했습니다!" : "패배했습니다.");
}

export function resolve(original: State, commands: Command[]): State {
  if (original.rulesVersion !== 1 || commands.length !== 2 || original.teams.some(replacement)
    || !commands.every((c, i) => legalCommands(original, i).some(l => same(c, l)))) throw new Error("invalid_command");
  const s = structuredClone(original), slots = s.teams.map(t => t.active), speeds = [stat(active(s, 0), "spd"), stat(active(s, 1), "spd")];
  const priority = (c: Command) => "swap" in c ? 2 : "guardMove" in c ? 1 : 0;
  const p = commands.map(priority);
  const first = p[0] !== p[1] ? (p[0] > p[1] ? 0 : 1) : speeds[0] !== speeds[1] ? (speeds[0] > speeds[1] ? 0 : 1) : (next(s) & 1n) === 0n ? 0 : 1;
  const guarded = [false, false], attackCharge = [false, false], hitCharge = [false, false];
  emit(s, 0, "turnStarted", `턴 ${s.turn}`);
  observeComeback(s);
  if (first === 0 && "move" in commands[0] && "move" in commands[1]) {
    const withoutSlow = structuredClone(active(s, 1));
    withoutSlow.effects = withoutSlow.effects.filter(e => !["legacy", "bsod_lag"].includes(e.id));
    if (speeds[0] > speeds[1] && speeds[0] < stat(withoutSlow, "spd"))
      emit(s, 0, "speedReversalWindow", "", slots[0], { amount: slots[1] });
  }
  for (const side of [first, 1 - first]) {
    const slot = slots[side], f = s.teams[side].fighters[slot], command = commands[side];
    if (f.hp <= 0 || s.teams[side].active !== slot) continue;
    if ("swap" in command) {
      f.effects = f.effects.filter(e => !buff(e.id)); s.teams[side].active = command.swap._0; s.teams[side].lastSwitch = s.turn;
      emit(s, side, "switched", `${active(s, side).pet.kind}에게 교체!`); continue;
    }
    if (skip(s, side)) continue;
    if ("guardMove" in command) { guarded[side] = true; s.teams[side].lastGuard = s.turn; emit(s, side, "guarded", `${f.pet.kind} 방어!`); continue; }
    if (!("move" in command)) continue;
    const m = f.moves.find(m => m.id === command.move._0)!;
    if (m.ultimate) s.teams[side].charge -= 10;
    if (m.maxPP != null) f.pp[m.id]--;
    emit(s, side, "skillUsed", `${f.pet.kind} · ${m.name}!`, slot, { moveID: m.id });
    const enemy = 1 - side, target = s.teams[enemy].active, defender = active(s, enemy);
    let effective = false;
    if (m.special === "dispelShield") {
      const old = defender.effects.length; defender.effects = defender.effects.filter(e => !shield(e.id));
      if (defender.effects.length !== old) { effective = true; emit(s, enemy, "effectRemoved", "실드가 제거되었습니다."); }
    }
    if (m.power > 0 && defender.hp > 0) {
      const amount = damageEstimate(m, f, defender, .9 + .1 * uniform(s), guarded[enemy]);
      const hit = hurt(s, enemy, target, amount);
      const effectiveness = skillEffectiveness(m.type, battleTypeOf(defender.pet.kind));
      if (enemy === 0 && s.teams[0].lastSwitch === s.turn && hit.total > 0 && effectiveness === .5)
        emit(s, 0, "resistedSwitch", "", target);
      if (side === 0 && hit.hp > 0 && defender.hp <= 0) {
        if (effectiveness === 2) achievementFact(s, "type_expert");
        if (s.events.some(e => e.kind === "resistedSwitch" && e.slot === slot && e.turn === s.turn - 1)) achievementFact(s, "switch_counter");
        if (s.events.some(e => e.kind === "speedReversalWindow" && e.slot === slot && e.turn === s.turn && e.amount === target)) achievementFact(s, "speed_planner");
        if (!m.ultimate && original.teams[0].charge === 10 && f.pet.variant >= 4) emit(s, 1, "reservedUltimate", "", target);
        if (m.ultimate && s.events.some(e => e.kind === "reservedUltimate" && e.slot !== target && e.turn < s.turn)) achievementFact(s, "ultimate_reserve");
      }
      if (hit.total > 0) { effective = true; if (!m.ultimate) attackCharge[side] = true; }
      if (hit.hp > 0) hitCharge[enemy] = true;
      if ((guarded[enemy] || s.teams[enemy].lastSwitch === s.turn) && hit.total > 0) defender.participated = true;
      if (m.special === "splash") for (const other of s.teams[enemy].fighters) if (other.id !== target && other.hp > 0) {
        const splash = hurt(s, enemy, other.id, Math.max(1, roundAway(amount * .3)));
        if (side === 0 && splash.hp > 0 && other.hp <= 0
          && s.events.some(e => e.kind === "reservedUltimate" && e.slot !== other.id && e.turn < s.turn)) achievementFact(s, "ultimate_reserve");
        if (splash.hp > 0) hitCharge[enemy] = true;
        effective = effective || splash.total > 0;
      }
    }
    if (m.special === "healSelf") effective = heal(s, side, slot, .25) || effective;
    if (m.special === "healTeam") {
      let healedCount = 0;
      for (const other of s.teams[side].fighters) { const healed = heal(s, side, other.id, .15); if (healed) healedCount++; effective = healed || effective; }
      if (side === 0 && healedCount >= 3) achievementFact(s, "team_recovery");
    }
    if (m.special === "spread") for (const other of s.teams[enemy].fighters) if (other.hp > 0) effective = grant(s, enemy, other.id, "spread_dot") || effective;
    if (m.effect) {
      const recipient = m.selfTarget ? side : enemy, idx = m.selfTarget ? slot : target, r = s.teams[recipient].fighters[idx];
      if (r.hp > 0 && !(control(m.effect) && r.immuneUntil >= s.turn) && (m.chance >= 1 || uniform(s) < m.chance)) effective = grant(s, recipient, idx, m.effect) || effective;
    }
    if (effective) { f.participated = true; if (m.ultimate) f.ultimateUsed = true; }
    observeComeback(s);
  }
  for (const side of [0, 1]) s.teams[side].charge = Math.min(10, s.teams[side].charge + Number(attackCharge[side]) + Number(hitCharge[side]));
  endTurn(s); s.revision++;
  if (!s.outcome) {
    s.turn++;
    const replaceAI = () => { const c = chooseAI(s, 1); if (c && "replacement" in c) {
      s.teams[1].active = c.replacement._0; emit(s, 1, "switched", `${active(s, 1).pet.kind} 출전!`);
    } };
    if (replacement(s.teams[1]) && !replacement(s.teams[0])) replaceAI();
    if (replacement(s.teams[0])) {
      const living = s.teams[0].fighters.filter(f => f.hp > 0);
      if (living.length === 1) {
        s.teams[0].active = living[0].id; emit(s, 0, "switched", `${active(s, 0).pet.kind} 출전!`);
        if (replacement(s.teams[1])) replaceAI();
      }
    }
    s.committedAI = chooseAI(s, 1);
  } else delete s.committedAI;
  return s;
}

export function submit(original: State, command: Command): State {
  if (original.rulesVersion !== 1 || original.outcome) throw new Error("invalid_command");
  const s = structuredClone(original);
  if (same(command, { surrender: {} })) {
    s.outcome = { winner: 1, reason: "surrender" }; emit(s, 0, "battleEnded", "항복했습니다."); s.revision++; return s;
  }
  if (!legalCommands(s, 0).some(c => same(c, command))) throw new Error("invalid_command");
  if ("replacement" in command) {
    s.teams[0].active = command.replacement._0; emit(s, 0, "switched", `${active(s, 0).pet.kind} 출전!`);
    if (replacement(s.teams[1]) && s.committedAI && "replacement" in s.committedAI) {
      s.teams[1].active = s.committedAI.replacement._0; emit(s, 1, "switched", `${active(s, 1).pet.kind} 출전!`);
    }
    s.revision++; s.committedAI = chooseAI(s, 1); return s;
  }
  if (!s.committedAI) throw new Error("invalid_command");
  return resolve(s, [command, s.committedAI]);
}

export function chooseAI(s: State, side: number): Command | undefined {
  const legal = legalCommands(s, side), team = s.teams[side], enemy = s.teams[1 - side], f = active(s, side), target = active(s, 1 - side);
  const bestDamage = (a: Fighter, b: Fighter) => Math.max(0, ...a.moves.filter(m => !m.ultimate && (m.maxPP == null || a.pp[m.id] > 0)).map(m => damageEstimate(m, a, b)));
  const score = (c: Command): number => {
    if ("replacement" in c) { const r = team.fighters[c.replacement._0]; return bestDamage(r, target) - bestDamage(target, r) * .5 + r.hp * .1; }
    if ("swap" in c) {
      if (team.lastSwitch === s.turn - 1) return -1000;
      const r = team.fighters[c.swap._0]; return bestDamage(r, target) - bestDamage(target, r) + (bestDamage(target, f) >= f.hp ? 15 : 0) - 10;
    }
    if ("guardMove" in c) return enemy.charge >= 10 && target.pet.variant >= 4 ? bestDamage(target, f) * .8 + 8 : -5;
    if (!("move" in c)) return -1000;
    const m = f.moves.find(m => m.id === c.move._0)!, damage = damageEstimate(m, f, target);
    let value = Math.min(target.hp, damage) - (m.maxPP != null ? 2 : 0) - (m.ultimate ? 8 : 0);
    if (m.power > 0 && damageEstimate(m, f, target, .9) >= target.hp) value += 30;
    if (m.effect) {
      const r = m.selfTarget ? f : target;
      if (m.effect === "hot_reload") { if (r.effects.some(e => !buff(e.id))) value += 12; }
      else if (!r.effects.some(e => e.id === m.effect) && !(control(m.effect) && r.immuneUntil >= s.turn)) value += (m.selfTarget ? 10 : 8) * m.chance;
    }
    if (m.special === "healSelf") value += Math.min(f.stats.hp - f.hp, Math.floor(f.stats.hp * .25));
    if (m.special === "healTeam") value += team.fighters.filter(f => f.hp > 0).reduce((n, f) => n + Math.min(f.stats.hp - f.hp, Math.floor(f.stats.hp * .15)), 0);
    if (m.special === "splash") value += (enemy.fighters.filter(f => f.hp > 0).length - 1) * damage * .25;
    if (m.special === "spread") value += enemy.fighters.filter(f => f.hp > 0).length * 5;
    if (m.special === "dispelShield") value += target.effects.reduce((n, e) => n + e.shield, 0);
    return value;
  };
  let best: Command | undefined, high = -Infinity;
  for (const c of legal) { const n = score(c); if (n > high) { best = c; high = n; } }
  return best;
}

export function publicState(state: State): State {
  const out = structuredClone(state);
  out.seed = "0"; out.randomState = "0"; delete out.committedAI;
  return out;
}

export function masteryAwards(state: State, eligibleKinds: string[]): { kind: string; branch: Branch | null }[] {
  if (state.tutorial || state.outcome?.winner !== 0 || state.outcome.reason !== "knockout") return [];
  return state.teams[0].fighters.filter(f => f.pet.variant >= 4 && f.participated && eligibleKinds.includes(f.pet.kind))
    .map(f => ({ kind: f.pet.kind, branch: f.ultimateUsed ? f.branch : null }));
}

function achievementFact(s: State, id: string) { emit(s, 0, "achievementFact", "", s.teams[0].active, { moveID: id }); }
function observeComeback(s: State) {
  if (s.teams[0].fighters.filter(f => f.hp > 0).length === 1 && s.teams[1].fighters.filter(f => f.hp > 0).length >= 3
    && !s.events.some(e => e.kind === "comebackWindow")) emit(s, 0, "comebackWindow", "");
}
