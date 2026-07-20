import Foundation

// 3v3 턴제 자동전투 결정적 시뮬레이터 (P0) — 순수 로직.
// 설계 SSOT: docs/plans/pet-battle.md §2-5 / §10.
//
// 랭크전은 서버가 이 규칙으로 시뮬레이션해 승패를 확정하고(authoritative), 클라는 로그를 재생만 한다.
// 서버 `_shared/battle_engine.ts`와 규칙 1:1. 동일 (두 팀 스냅샷 + 시드) → 동일 로그·승자.

/// 배틀 팀 멤버 스냅샷 — 서버가 보관하는 고스트 방어 팀의 한 마리.
struct BattlePetSnapshot: Codable, Equatable, Hashable {
    var kind: PetKind
    var variant: Int
    var enhanceLevel: Int
    var progressUnits: Double

    init(kind: PetKind, variant: Int = 0, enhanceLevel: Int = 0, progressUnits: Double = 0) {
        self.kind = kind
        self.variant = variant
        self.enhanceLevel = enhanceLevel
        self.progressUnits = progressUnits
    }
}

/// 배틀 팀 — 최대 3마리, `members[0]`가 리드(선봉).
struct BattleTeam: Codable, Equatable {
    var members: [BattlePetSnapshot]
    init(_ members: [BattlePetSnapshot]) { self.members = members }
}

enum BattleSide: String, Codable, Equatable { case a, b }

/// 재생용 턴 이벤트.
struct BattleEvent: Codable, Equatable {
    var round: Int
    var attacker: BattleSide
    var attackerKind: PetKind
    var defenderKind: PetKind
    var move: String            // "basic" | "signature"
    var damage: Int             // 최종 데미지 (패링 반영 후)
    var effectiveness: Double   // 타입 상성 1.6 / 1.0 / 0.625
    var collectionMult: Double  // 컬렉션 상성(밈/상성망) 배수
    var quip: String?           // 밈 라이벌 발동 시 배틀로그 대사
    var parried: Bool           // 방어자 퍼펙트 가드(패링) 발동 여부
    var defenderFainted: Bool
}

struct BattleResult: Codable, Equatable {
    var winner: BattleSide?     // nil = 무승부 (max turn 타이브레이크에서 잔여 HP 동률)
    var rounds: Int
    var log: [BattleEvent]
}

enum BattleEngine {
    /// 최대 행동 수 backstop (ATB라 "라운드"가 아니라 누적 행동 수). 초과 시 잔여 HP 타이브레이크.
    static let maxRounds = 120
    static let basicPower = 10.0
    static let signaturePower = 14.0
    /// ATB 행동 주기 = speedBase / SPD. SPD 2배 → 주기 절반 → 2배 자주 행동(연속 공격 가능).
    static let speedBase = 1000.0

    // MARK: 패링(퍼펙트 가드) — DEF+SPD 조합. 빠른 반응(SPD) + 단단한 가드(DEF)로 피격을 흘린다.
    static let parryBase = 0.06
    static let parrySpdWeight = 0.25   // 방어자가 공격자보다 빠를수록 ↑ (반응속도)
    static let parryDefWeight = 0.12   // 방어자 DEF 비중이 클수록 ↑ (가드력)
    static let parryMax = 0.40
    static let parryDamageMult = 0.10  // 패링 성공 시 데미지 대폭 경감(칩 데미지)

    /// 방어자 패링 확률 — SPD 차(반응) + DEF 비중(가드). [0, parryMax]로 클램프.
    static func parryChance(defSPD: Int, defDEF: Int, atkSPD: Int, atkDEF: Int) -> Double {
        let sd = Double(defSPD), sa = Double(atkSPD), dd = Double(defDEF), da = Double(atkDEF)
        let spdTerm = parrySpdWeight * (sd - sa) / max(1, sd + sa)          // -0.25…+0.25
        let defTerm = parryDefWeight * ((dd / max(1, dd + da)) - 0.5) * 2   // -0.12…+0.12
        return min(parryMax, max(0, parryBase + spdTerm + defTerm))
    }

    /// 전투용 인스턴스 (스탯 + 현재 HP).
    private struct Combatant {
        let kind: PetKind
        let type: BattleType
        let stats: BattleStats
        var hp: Int
        var alive: Bool { hp > 0 }
    }

    private static func makeCombatants(_ team: BattleTeam) -> [Combatant] {
        // A. 팀 시너지 — 같은 컬렉션/타입 팀원 버프를 팀 전체 스탯에 곱한다.
        let syn = TeamSynergy.multiplier(for: team.members)
        return team.members.map { m in
            let base = PetBattleStats.compute(kind: m.kind, variant: m.variant,
                                              enhanceLevel: m.enhanceLevel, progressUnits: m.progressUnits)
            let s = BattleStats(hp:  max(1, Int((Double(base.hp)  * syn).rounded())),
                                atk: max(1, Int((Double(base.atk) * syn).rounded())),
                                def: max(1, Int((Double(base.def) * syn).rounded())),
                                spd: max(1, Int((Double(base.spd) * syn).rounded())))
            return Combatant(kind: m.kind, type: m.kind.battleType, stats: s, hp: s.hp)
        }
    }

    /// 살아있는 첫 인덱스(=현재 선봉). 없으면 nil(전멸).
    private static func active(_ team: [Combatant]) -> Int? {
        team.firstIndex(where: { $0.alive })
    }

    /// 두 팀 + 시드 → 결정적 배틀 결과. **ATB** — 각 선봉이 SPD에 비례한 주기로 행동한다.
    /// 두 선봉의 "다음 행동 시각"(nextAt)을 비교해 이른 쪽이 행동하고, 자기 주기(cd=speedBase/SPD)를
    /// 더해 재스케줄. SPD가 2배면 주기가 절반이라 상대 1회당 2회 행동(연속 공격)이 나온다.
    /// 동시(nextAt 동률)엔 빠른 쪽 먼저(동속이면 시드) — 정확히 2배도 연속 2회가 나오게.
    static func simulate(teamA: BattleTeam, teamB: BattleTeam, seed: UInt64) -> BattleResult {
        var rng = SeededRNG(seed: seed)
        var a = makeCombatants(teamA)
        var b = makeCombatants(teamB)
        var log: [BattleEvent] = []
        func cd(_ spd: Int) -> Double { speedBase / Double(max(1, spd)) }

        guard let ai0 = active(a), let bi0 = active(b) else {
            let w: BattleSide? = active(a) != nil ? .a : (active(b) != nil ? .b : nil)
            return BattleResult(winner: w, rounds: 0, log: [])
        }
        var aNext = cd(a[ai0].stats.spd)
        var bNext = cd(b[bi0].stats.spd)
        var actions = 0

        while actions < maxRounds {
            guard let ai = active(a), let bi = active(b) else { break }
            let aSpd = a[ai].stats.spd, bSpd = b[bi].stats.spd
            let aGoes: Bool
            if abs(aNext - bNext) < 1e-6 {
                aGoes = aSpd != bSpd ? aSpd > bSpd : (rng.next() & 1 == 0)
            } else {
                aGoes = aNext < bNext
            }
            actions += 1
            let t = aGoes ? aNext : bNext
            if aGoes {
                let fainted = attack(from: &a, to: &b, attackerSide: .a, round: actions, log: &log, rng: &rng)
                aNext = t + cd(aSpd)
                if fainted, let nb = active(b) { bNext = t + cd(b[nb].stats.spd) }   // 새 방어자 재스케줄
            } else {
                let fainted = attack(from: &b, to: &a, attackerSide: .b, round: actions, log: &log, rng: &rng)
                bNext = t + cd(bSpd)
                if fainted, let na = active(a) { aNext = t + cd(a[na].stats.spd) }
            }
            if active(a) == nil { return BattleResult(winner: .b, rounds: actions, log: log) }
            if active(b) == nil { return BattleResult(winner: .a, rounds: actions, log: log) }
        }

        // backstop 도달 — 잔여 HP 합으로 타이브레이크.
        let sumA = a.reduce(0) { $0 + max(0, $1.hp) }
        let sumB = b.reduce(0) { $0 + max(0, $1.hp) }
        let winner: BattleSide? = sumA == sumB ? nil : (sumA > sumB ? .a : .b)
        return BattleResult(winner: winner, rounds: actions, log: log)
    }

    /// 공격 1회 수행. 방어자가 기절하면 true.
    @discardableResult
    private static func attack(from: inout [Combatant], to: inout [Combatant],
                               attackerSide: BattleSide, round: Int,
                               log: inout [BattleEvent], rng: inout SeededRNG) -> Bool {
        guard let ai = active(from), let di = active(to) else { return false }
        let attacker = from[ai]
        let defender = to[di]

        let eff = BattleType.effectiveness(attacker.type, vs: defender.type)
        // B/C. 컬렉션 상성(밈 라이벌 + 상성망) — 타입 상성과 곱해진다.
        let synergy = PetSynergy.matchup(attacker.kind.collection, vs: defender.kind.collection)
        // 무브 선택 휴리스틱: 타입 또는 컬렉션 상성 유리면 시그니처, 아니면 기본.
        let useSignature = eff > 1.0 || synergy.mult > 1.0
        let power = useSignature ? signaturePower : basicPower

        let rngFactor = Double.random(in: 0.9...1.0, using: &rng)
        let raw = (Double(attacker.stats.atk) / Double(defender.stats.def)) * power * eff * synergy.mult * rngFactor
        let baseDmg = max(1, Int(raw.rounded()))

        // 패링(퍼펙트 가드) — 방어자 SPD+DEF 조합 확률로 데미지 대폭 경감.
        let pc = parryChance(defSPD: defender.stats.spd, defDEF: defender.stats.def,
                             atkSPD: attacker.stats.spd, atkDEF: attacker.stats.def)
        let parried = Double.random(in: 0..<1, using: &rng) < pc
        let dmg = parried ? max(1, Int((Double(baseDmg) * parryDamageMult).rounded())) : baseDmg

        to[di].hp -= dmg
        let fainted = to[di].hp <= 0

        log.append(BattleEvent(
            round: round,
            attacker: attackerSide,
            attackerKind: attacker.kind,
            defenderKind: defender.kind,
            move: useSignature ? "signature" : "basic",
            damage: dmg,
            effectiveness: eff,
            collectionMult: synergy.mult,
            quip: synergy.quip,
            parried: parried,
            defenderFainted: fainted
        ))
        return fainted
    }
}
