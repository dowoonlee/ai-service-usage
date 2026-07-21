import Foundation

// 5v5 ATB 자동전투 결정적 시뮬레이터 (P0) — 순수 로직.
// 설계 SSOT: docs/plans/pet-battle.md §2-5 / §10.
//
// 랭크전은 서버가 이 규칙으로 시뮬레이션해 승패를 확정하고(authoritative), 클라는 로그를 재생만 한다.
// 서버 `_shared/battle_engine.ts`(이식 완료·운영 중)와 규칙 1:1 — 동일 (두 팀 스냅샷 + 시드) →
// 동일 로그·승자. `rng.uniform01()`(EnhanceEngine.swift)과 `.rounded()`(away-from-zero,
// JS `Math.round`와 다름)를 명세대로 재현해 비트 단위로 일치한다.

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

/// 배틀 팀 — 최대 5마리, `members[0]`가 리드(선봉).
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
    var move: String            // 스킬 id ("hotfix"/"mem_leak"…). 구 로그엔 "basic"/"signature"
    var damage: Int             // 최종 데미지 (패링 반영 후)
    var effectiveness: Double   // 스킬 타입 상성 2.0 / 1.0 / 0.5 (구 로그엔 1.6 / 1.0 / 0.625)
    var collectionMult: Double  // 컬렉션 상성(밈/상성망) 배수
    var quip: String?           // 밈 라이벌 발동 시 배틀로그 대사
    var parried: Bool           // 방어자 퍼펙트 가드(패링) 발동 여부
    var crit: Bool?             // 레인보우 크리 발동(구 로그엔 없어 Optional)
    var defenderFainted: Bool
}

struct BattleResult: Codable, Equatable {
    var winner: BattleSide?     // nil = 무승부 (max turn 타이브레이크에서 잔여 HP 동률)
    var rounds: Int
    var log: [BattleEvent]
}

enum BattleEngine {
    /// 최대 행동 수 backstop (ATB라 "라운드"가 아니라 누적 행동 수). 초과 시 잔여 HP 타이브레이크.
    static let maxRounds = 180   // 5v5는 총 HP가 늘어 상향(조기 타이브레이크 방지). rage 램프가 장기전 수렴.
    /// ATB 행동 주기 = speedBase / SPD. SPD 2배 → 주기 절반 → 2배 자주 행동(연속 공격 가능).
    static let speedBase = 1000.0

    /// 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적으로 데미지 ×critMult. 서버 battle_engine 1:1.
    static let rainbowVariant = 4
    static let rainbowCritChance = 0.20
    static let rainbowCritMult = 1.5

    // MARK: 격노 램프 — 데미지식은 성장이 atk/def에 동시 곱해져 비율 불변이라 TTK가 HP(성장 비례)만큼
    // 선형으로 늘어난다. 풀강 탱커 미러전은 maxRounds를 상시 초과해 "KO 없는 HP 총량 타이브레이크"로
    // 메타가 수렴 → 막타/역전이 사라진다. 일정 액션 이후 데미지를 점증시켜 리플레이 길이에 자연 상한을
    // 두고, 결판이 KO로 나게 한다. (오토배틀러 표준 해법.) rageStart 이전엔 배수 1.0이라 결정적
    // 매치(강 vs 약, ~수십 액션 내 종결)엔 영향 없음.
    static let rageStart = 40
    static let rageStep = 0.07

    /// 누적 액션 수 → 데미지 배수. rageStart까지 1.0, 이후 액션당 rageStep 선형 가산.
    static func rageMultiplier(action: Int) -> Double {
        1.0 + Double(max(0, action - rageStart)) * rageStep
    }

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
        let isRainbow: Bool   // 최종 이로치(레인보우) — 크리 특수효과 대상
        let skills: [Skill]   // variant까지 해금한 정규 스킬(슬롯 순) — 선택 AI 후보
        var alive: Bool { hp > 0 }
    }

    /// 팀 시너지까지 반영한 한 마리의 최종 전투 스탯. **관전 UI의 HP 바가 엔진과 어긋나지 않도록**
    /// (팀 시너지 배수를 UI가 빠뜨리면 3~15% 먼저 0 HP에 도달 → 파티 아이콘/활성 펫 desync)
    /// 엔진과 UI가 공유하는 단일 소스. makeCombatants와 ArenaView가 이 함수만 호출한다.
    static func finalStats(for member: BattlePetSnapshot, in team: BattleTeam) -> BattleStats {
        let syn = TeamSynergy.bonus(for: team.members)   // 동족=전 스탯 / 동타입=대표 스탯 방향성
        let base = PetBattleStats.compute(kind: member.kind, variant: member.variant,
                                          enhanceLevel: member.enhanceLevel, progressUnits: member.progressUnits)
        func s(_ v: Int, _ k: StatKind) -> Int {
            max(1, Int((Double(v) * TeamSynergy.statMultiplier(syn, k)).rounded()))
        }
        return BattleStats(hp: s(base.hp, .hp), atk: s(base.atk, .atk), def: s(base.def, .def), spd: s(base.spd, .spd))
    }

    private static func makeCombatants(_ team: BattleTeam) -> [Combatant] {
        // A. 팀 시너지 — 같은 컬렉션/타입 팀원 버프를 팀 전체 스탯에 곱한다.
        team.members.map { m in
            let s = finalStats(for: m, in: team)
            return Combatant(kind: m.kind, type: m.kind.battleType, stats: s, hp: s.hp,
                             isRainbow: m.variant >= rainbowVariant,
                             skills: SkillCatalog.skills(kind: m.kind, variant: m.variant))
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

        // 스킬 선택(결정적 AI) → 스킬 타입 상성(×2.0/×0.5) + 자속(STAB ×1.5)으로 데미지식 전환.
        let skill = SkillCatalog.select(from: attacker.skills, attackerType: attacker.type, defenderType: defender.type)
        let eff = SkillCatalog.skillEffectiveness(skill.type, vs: defender.type)   // 로그 effectiveness = 스킬 상성
        let stab = SkillCatalog.stab(skillType: skill.type, petType: attacker.type)
        // B/C. 컬렉션 상성(밈 라이벌 + 상성망) — 그대로 곱해진다.
        let synergy = PetSynergy.matchup(attacker.kind.collection, vs: defender.kind.collection)

        let rngFactor = 0.9 + 0.1 * rng.uniform01()   // [0.9, 1.0)
        let rage = rageMultiplier(action: round)      // 장기전 데미지 점증(격노)
        let raw = (Double(attacker.stats.atk) / Double(defender.stats.def)) * skill.power * eff * stab * synergy.mult * rngFactor * rage
        let baseDmg = max(1, Int(raw.rounded()))

        // 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적 ×critMult. 조건부 draw라 비-레인보우
        // 배틀의 RNG 스트림·기존 골든은 불변. 순서: rngFactor → (레인보우면 크리) → 패링 (서버와 1:1).
        var critDmg = baseDmg
        var crit = false
        if attacker.isRainbow {
            crit = rng.uniform01() < rainbowCritChance
            if crit { critDmg = max(1, Int((Double(baseDmg) * rainbowCritMult).rounded())) }
        }

        // 패링(퍼펙트 가드) — 방어자 SPD+DEF 조합 확률로 데미지 대폭 경감.
        let pc = parryChance(defSPD: defender.stats.spd, defDEF: defender.stats.def,
                             atkSPD: attacker.stats.spd, atkDEF: attacker.stats.def)
        let parried = rng.uniform01() < pc
        let dmg = parried ? max(1, Int((Double(critDmg) * parryDamageMult).rounded())) : critDmg

        to[di].hp -= dmg
        let fainted = to[di].hp <= 0

        log.append(BattleEvent(
            round: round,
            attacker: attackerSide,
            attackerKind: attacker.kind,
            defenderKind: defender.kind,
            move: skill.id,
            damage: dmg,
            effectiveness: eff,
            collectionMult: synergy.mult,
            quip: synergy.quip,
            parried: parried,
            crit: crit,
            defenderFainted: fainted
        ))
        return fainted
    }
}
