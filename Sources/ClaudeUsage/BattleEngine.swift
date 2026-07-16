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
    var damage: Int
    var effectiveness: Double   // 타입 상성 1.6 / 1.0 / 0.625
    var collectionMult: Double  // 컬렉션 상성(밈/상성망) 배수
    var quip: String?           // 밈 라이벌 발동 시 배틀로그 대사
    var defenderFainted: Bool
}

struct BattleResult: Codable, Equatable {
    var winner: BattleSide?     // nil = 무승부 (max turn 타이브레이크에서 잔여 HP 동률)
    var rounds: Int
    var log: [BattleEvent]
}

enum BattleEngine {
    static let maxRounds = 50
    static let basicPower = 10.0
    static let signaturePower = 14.0

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

    /// 두 팀 + 시드 → 결정적 배틀 결과.
    static func simulate(teamA: BattleTeam, teamB: BattleTeam, seed: UInt64) -> BattleResult {
        var rng = SeededRNG(seed: seed)
        var a = makeCombatants(teamA)
        var b = makeCombatants(teamB)
        var log: [BattleEvent] = []
        var round = 0

        while round < maxRounds {
            round += 1
            guard let ai = active(a), let bi = active(b) else { break }

            // 선공 결정 — SPD 높은 쪽, 동률은 시드.
            let spdA = a[ai].stats.spd, spdB = b[bi].stats.spd
            let aFirst = spdA != spdB ? spdA > spdB : (rng.next() & 1 == 0)
            let order: [BattleSide] = aFirst ? [.a, .b] : [.b, .a]

            for side in order {
                guard active(a) != nil, active(b) != nil else { break }
                if side == .a {
                    attack(from: &a, to: &b, attackerSide: .a, round: round, log: &log, rng: &rng)
                } else {
                    attack(from: &b, to: &a, attackerSide: .b, round: round, log: &log, rng: &rng)
                }
            }

            if active(a) == nil { return BattleResult(winner: .b, rounds: round, log: log) }
            if active(b) == nil { return BattleResult(winner: .a, rounds: round, log: log) }
        }

        // max round 도달 — 잔여 HP 합으로 타이브레이크.
        let sumA = a.reduce(0) { $0 + max(0, $1.hp) }
        let sumB = b.reduce(0) { $0 + max(0, $1.hp) }
        let winner: BattleSide? = sumA == sumB ? nil : (sumA > sumB ? .a : .b)
        return BattleResult(winner: winner, rounds: round, log: log)
    }

    private static func attack(from: inout [Combatant], to: inout [Combatant],
                               attackerSide: BattleSide, round: Int,
                               log: inout [BattleEvent], rng: inout SeededRNG) {
        guard let ai = active(from), let di = active(to) else { return }
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
        let dmg = max(1, Int(raw.rounded()))

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
            defenderFainted: fainted
        ))
    }
}
