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

/// 효과 이벤트 (E2) — 공격 로그(`log`)와 **분리된 스트림**. 이유: 구 클라이언트는 미지의 최상위 필드를
/// 통째로 무시하므로(Codable), 공격 이벤트 fold 로직이 오염되지 않는다(틱/스플래시를 공격으로 오해 X).
/// `at`은 연관된 액션 인덱스(BattleEvent.round와 동일 축) — tick/skip은 그 액션 "직전" 발생분.
struct EffectEvent: Codable, Equatable {
    var at: Int
    var side: BattleSide        // 대상 펫의 소속
    var petKind: PetKind
    var kind: String            // "tick" | "skip" | "grant" | "heal" | "splash"
    var effectId: String?       // tick/skip/grant — EffectCatalog id
    var hpDelta: Int?           // tick(±) / heal(+) / splash(−) — UI HP 재구성용(실제 적용량)
    var fainted: Bool?          // splash로 기절 시 true
}

struct BattleResult: Codable, Equatable {
    var winner: BattleSide?     // nil = 무승부 (max turn 타이브레이크에서 잔여 HP 동률)
    var rounds: Int
    var log: [BattleEvent]
    var effectEvents: [EffectEvent]? = nil   // E2 — 효과 없으면 nil(구 로그와 JSON 동일). 구 클라 호환 Optional.
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

    /// 궁극기 충전 비용 — 게이지는 ①행동 시 +1 ②피격 시 +1 로 차고, 기절 시 잔여 게이지가 다음 생존
    /// 펫에게 승계된다(개인 게이지 → 사실상 **팀 게이지**). 이 값 도달 시 **그 행동**이 궁극기(정규 스킬
    /// 대체) 후 게이지 리셋 → 장기전 다회 발동. **전부 이벤트 기반 = RNG 불필요·완전 결정적**(파리티 안전).
    /// 서버 battle_engine 1:1.
    ///
    /// 가시성 패치(6 행동만 → 10 행동+피격+승계): 패자 측이 게이지 6이 차기 전에(펫당 1.5~3.3행동) 죽어
    /// 궁극기를 못 보던 문제 해소 — 패자 궁 발동률 62/61/14% → 100/100/91%(동급/소폭/대폭 우위 각 500판
    /// 실측), 승률·라운드 수 불변(가시성 전용). docs/plans/pet-skills.md §5.
    static let ultChargeCost = 10

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

    // MARK: 효과 레이어 (E1 프레임 + E2 스킬 연동) — 상태이상/버프. 설계: docs/plans/pet-effects.md.
    // E2부터 활성: typeShared rider 6종 + happyPath 버프 + 궁극기 특수효과(§7.5)가 효과를 부여한다.
    // 부여 스킬이 전혀 안 나오는 배틀(v0 팀 등)은 여전히 전 경로 no-op — RNG 스트림·구 골든 불변.
    // 서버 battle_engine 1:1 (모델·틱 순서·반올림·슬롯 규칙·draw 순서 전부).

    /// 효과 종류 6종 — pet-effects.md §1.
    enum EffectKind: Equatable {
        case dot                 // 매 자기 턴 시작 HP -= magnitude(% of maxHP)
        case regen               // 매 자기 턴 시작 HP += magnitude(% of maxHP), maxHP 상한
        case statMod(StatKind)   // 지속 중 atk/def/spd × magnitude (hp는 비대상)
        case controlFixed        // duration 동안 무조건 턴 스킵
        case controlChance       // 매 턴 chance 확률로 스킵 (rng draw는 보유 시에만 — 스트림 보존)
        case shield              // flat HP 흡수막 — 피해를 실드에서 먼저 차감, 소진 시 제거
        case cleanse             // 즉시 — 자기 디버프 전부 제거 (지속 아님, 부여 시점 처리)
    }

    /// 효과 정의 (카탈로그 상수 — E2에서 스킬 `effect` 필드로 연결).
    struct BattleEffect: Equatable {
        let id: String
        let kind: EffectKind
        let magnitude: Double   // dot/regen/shield: maxHP 비율, statMod: 배수, control: 미사용(0)
        let duration: Int       // 지속 자기 턴 수 (cleanse는 0)
        let chance: Double?     // controlChance 스킵 확률. (부여 확률은 스킬 쪽 — E2)
    }

    /// 전투원이 보유 중인 효과 인스턴스.
    struct ActiveEffect: Equatable {
        let effect: BattleEffect
        var remaining: Int
        var shieldHP: Int   // shield 전용 잔여 흡수량(부여 시 maxHP×magnitude 반올림) — 그 외 0
    }

    /// 효과 슬롯 상한 — 초과 부여 시 remaining 최소(동률이면 앞 인덱스)부터 밀어냄. pet-effects.md §5.
    static let effectSlotCap = 4

    /// 전투용 인스턴스 (스탯 + 현재 HP).
    private struct Combatant {
        let kind: PetKind
        let type: BattleType
        let stats: BattleStats
        var hp: Int
        let isRainbow: Bool   // 최종 이로치(레인보우) — 크리 특수효과 대상
        let skills: [Skill]   // variant까지 해금한 정규 스킬(슬롯 순) — 선택 AI 후보
        let ultimate: Skill?  // 레인보우만 보유(타입 궁극기). 충전 게이지가 차면 발동.
        var charge: Int = 0   // 궁극기 충전 게이지 — 행동/피격마다 +1·기절 시 승계, ultChargeCost 도달 시 발동·리셋.
        var effects: [ActiveEffect] = []   // 활성 효과(상한 effectSlotCap). rider/궁극기 grant로 부여(E2).
        var alive: Bool { hp > 0 }
    }

    /// StatMod 반영 스탯 — base × Π(해당 스탯 statMod magnitude), away-from-zero 반올림(파리티 명세).
    private static func effStat(_ base: Int, _ stat: StatKind, _ effects: [ActiveEffect]) -> Int {
        var v = Double(base)
        for e in effects {
            if case .statMod(let s) = e.effect.kind, s == stat { v *= e.effect.magnitude }
        }
        return max(1, Int(v.rounded()))
    }

    /// 자기 턴 시작 효과 틱 — ①DoT/Regen(% of maxHP, ≥1 보장) ②remaining-- ③만료 제거.
    /// DoT로 자멸 가능(hp ≤ 0) — 호출부가 행동 전에 alive 재확인. RNG 불요(결정적).
    /// hpDelta는 **실제 적용량**(regen은 maxHP 클램프 후)을 기록 — UI HP fold가 그대로 더하면 일치.
    private static func tickEffects(_ c: inout Combatant, side: BattleSide, round: Int,
                                    events: inout [EffectEvent]) {
        guard !c.effects.isEmpty else { return }   // 미부여 배틀 상시 경로 — no-op
        for e in c.effects {
            let amt = max(1, Int((Double(c.stats.hp) * e.effect.magnitude).rounded()))
            switch e.effect.kind {
            case .dot:
                c.hp -= amt
                events.append(EffectEvent(at: round, side: side, petKind: c.kind, kind: "tick",
                                          effectId: e.effect.id, hpDelta: -amt, fainted: nil))
            case .regen:
                let healed = min(c.stats.hp - c.hp, amt)
                if healed > 0 {
                    c.hp += healed
                    events.append(EffectEvent(at: round, side: side, petKind: c.kind, kind: "tick",
                                              effectId: e.effect.id, hpDelta: healed, fainted: nil))
                }
            default: break
            }
        }
        for i in c.effects.indices { c.effects[i].remaining -= 1 }
        c.effects.removeAll { $0.remaining <= 0 }
    }

    /// Control 체크 — 고정형이면 무조건 스킵, 확률형이면 rng draw < chance 스킵(효과 배열 순 draw).
    /// draw는 **확률형 보유 시에만** 소비(비보유 배틀의 RNG 스트림 불변 — 레인보우 크리와 동일 패턴).
    /// 스킵 턴은 행동이 아니므로 궁극기 게이지도 적립하지 않는다.
    private static func shouldSkipTurn(_ c: inout Combatant, side: BattleSide, round: Int,
                                       events: inout [EffectEvent], rng: inout SeededRNG) -> Bool {
        for e in c.effects {
            switch e.effect.kind {
            case .controlFixed:
                events.append(EffectEvent(at: round, side: side, petKind: c.kind, kind: "skip",
                                          effectId: e.effect.id, hpDelta: nil, fainted: nil))
                return true
            case .controlChance:
                if rng.uniform01() < (e.effect.chance ?? 0) {
                    events.append(EffectEvent(at: round, side: side, petKind: c.kind, kind: "skip",
                                              effectId: e.effect.id, hpDelta: nil, fainted: nil))
                    return true
                }
            default: break
            }
        }
        return false
    }

    /// 실드 흡수 — 피해를 shield 효과들에서 앞 인덱스부터 차감, 소진 실드 제거. HP로 갈 잔여 피해 반환.
    /// ⚠️ E2에서 BattleEvent에 흡수량 필드를 추가해야 UI HP 재구성(damage fold)이 어긋나지 않는다.
    private static func absorbShield(_ c: inout Combatant, _ dmg: Int) -> Int {
        guard c.effects.contains(where: { $0.effect.kind == .shield }) else { return dmg }   // E1 상시 경로
        var left = dmg
        for i in c.effects.indices where left > 0 {
            guard c.effects[i].effect.kind == .shield else { continue }
            let absorb = min(c.effects[i].shieldHP, left)
            c.effects[i].shieldHP -= absorb
            left -= absorb
        }
        c.effects.removeAll { $0.effect.kind == .shield && $0.shieldHP <= 0 }
        return left
    }

    /// 디버프 판정 — dot / control 계열 / statMod(배수 < 1). cleanse 제거 대상 + 선택 AI(hasDebuff) 공용.
    static func isDebuff(_ e: BattleEffect) -> Bool {
        switch e.kind {
        case .dot, .controlFixed, .controlChance: return true
        case .statMod: return e.magnitude < 1
        default: return false
        }
    }

    /// 효과 부여 — 동일 id 재부여는 duration/shield **refresh**(중첩 없음). cleanse는 즉시 디버프 제거.
    /// 슬롯 초과 시 remaining 최소(동률: 앞 인덱스)를 밀어냄. attack의 rider/궁극기 grant 경로가 호출.
    /// 반환: 실제로 적용됐는지 — cleanse는 **지운 게 있을 때만** true(무의미한 grant 이벤트 방지, 양측 1:1).
    @discardableResult
    private static func grant(_ effect: BattleEffect, to c: inout Combatant) -> Bool {
        if effect.kind == .cleanse {
            let before = c.effects.count
            c.effects.removeAll { isDebuff($0.effect) }
            return c.effects.count < before
        }
        let shieldHP = effect.kind == .shield ? max(1, Int((Double(c.stats.hp) * effect.magnitude).rounded())) : 0
        if let i = c.effects.firstIndex(where: { $0.effect.id == effect.id }) {
            c.effects[i] = ActiveEffect(effect: effect, remaining: effect.duration, shieldHP: shieldHP)
            return true
        }
        if c.effects.count >= effectSlotCap {
            var evict = 0
            for i in c.effects.indices where c.effects[i].remaining < c.effects[evict].remaining { evict = i }
            c.effects.remove(at: evict)
        }
        c.effects.append(ActiveEffect(effect: effect, remaining: effect.duration, shieldHP: shieldHP))
        return true
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
            let rainbow = m.variant >= rainbowVariant
            return Combatant(kind: m.kind, type: m.kind.battleType, stats: s, hp: s.hp,
                             isRainbow: rainbow,
                             skills: SkillCatalog.skills(kind: m.kind, variant: m.variant),
                             ultimate: rainbow ? SkillCatalog.ultimate(for: m.kind.battleType) : nil)
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
        var fx: [EffectEvent] = []   // 효과 이벤트 스트림(E2) — log와 분리(구 클라 호환)
        func cd(_ spd: Int) -> Double { speedBase / Double(max(1, spd)) }
        func fxOrNil() -> [EffectEvent]? { fx.isEmpty ? nil : fx }

        guard let ai0 = active(a), let bi0 = active(b) else {
            let w: BattleSide? = active(a) != nil ? .a : (active(b) != nil ? .b : nil)
            return BattleResult(winner: w, rounds: 0, log: [])
        }
        var aNext = cd(effStat(a[ai0].stats.spd, .spd, a[ai0].effects))
        var bNext = cd(effStat(b[bi0].stats.spd, .spd, b[bi0].effects))
        var actions = 0

        while actions < maxRounds {
            guard let ai = active(a), let bi = active(b) else { break }
            // spd는 StatMod 효과 반영(effective) — ATB 주기·동시 tie-break 모두. E1에선 base와 동일.
            let aSpd = effStat(a[ai].stats.spd, .spd, a[ai].effects)
            let bSpd = effStat(b[bi].stats.spd, .spd, b[bi].effects)
            let aGoes: Bool
            if abs(aNext - bNext) < 1e-6 {
                aGoes = aSpd != bSpd ? aSpd > bSpd : (rng.next() & 1 == 0)
            } else {
                aGoes = aNext < bNext
            }
            actions += 1
            let t = aGoes ? aNext : bNext
            if aGoes {
                let fainted = attack(from: &a, to: &b, attackerSide: .a, round: actions, log: &log, events: &fx, rng: &rng)
                // DoT 자멸로 공격자 선봉이 바뀌었으면 새 선봉 주기로 재스케줄(죽은 펫 spd로 스케줄 방지).
                if let cur = active(a) { aNext = t + cd(cur == ai ? aSpd : effStat(a[cur].stats.spd, .spd, a[cur].effects)) }
                if fainted, let nb = active(b) { bNext = t + cd(effStat(b[nb].stats.spd, .spd, b[nb].effects)) }   // 새 방어자 재스케줄
            } else {
                let fainted = attack(from: &b, to: &a, attackerSide: .b, round: actions, log: &log, events: &fx, rng: &rng)
                if let cur = active(b) { bNext = t + cd(cur == bi ? bSpd : effStat(b[cur].stats.spd, .spd, b[cur].effects)) }
                if fainted, let na = active(a) { aNext = t + cd(effStat(a[na].stats.spd, .spd, a[na].effects)) }
            }
            if active(a) == nil { return BattleResult(winner: .b, rounds: actions, log: log, effectEvents: fxOrNil()) }
            if active(b) == nil { return BattleResult(winner: .a, rounds: actions, log: log, effectEvents: fxOrNil()) }
        }

        // backstop 도달 — 잔여 HP 합으로 타이브레이크.
        let sumA = a.reduce(0) { $0 + max(0, $1.hp) }
        let sumB = b.reduce(0) { $0 + max(0, $1.hp) }
        let winner: BattleSide? = sumA == sumB ? nil : (sumA > sumB ? .a : .b)
        return BattleResult(winner: winner, rounds: actions, log: log, effectEvents: fxOrNil())
    }

    /// 공격 1회 수행. 방어자가 기절하면 true.
    /// RNG draw 순서(파리티 고정): (controlChance 스킵) → rngFactor → (레인보우 크리) → 패링 → (rider chance).
    @discardableResult
    private static func attack(from: inout [Combatant], to: inout [Combatant],
                               attackerSide: BattleSide, round: Int,
                               log: inout [BattleEvent], events: inout [EffectEvent],
                               rng: inout SeededRNG) -> Bool {
        guard let ai = active(from), let di = active(to) else { return false }
        // 1) 효과 틱(자기 턴 시작) — DoT/Regen·만료 제거. DoT 자멸 시 행동 없이 종료하되,
        //    게이지는 기절 승계 규칙 그대로 다음 생존 펫에게 이전(팀 게이지 일관성).
        tickEffects(&from[ai], side: attackerSide, round: round, events: &events)
        if !from[ai].alive {
            if let ni = active(from) { from[ni].charge += from[ai].charge }
            return false
        }
        // 2) Control 체크 — 스킵 턴은 행동이 아니므로 게이지 적립 없음. (draw는 확률형 보유 시에만 — 스트림 보존)
        if shouldSkipTurn(&from[ai], side: attackerSide, round: round, events: &events, rng: &rng) { return false }
        // 3) 행동
        from[ai].charge += 1                     // 궁극기 게이지 — 행동마다 +1(결정적).
        let attacker = from[ai]                  // 값복사(Swift)/참조(TS) — charge 판정은 리셋 前이라 양측 동일.
        let defender = to[di]
        // ⚠️ 파리티: 리셋(from[ai].charge=0) 이후 `attacker.charge`를 절대 읽지 말 것 — Swift는 복사본이라 옛값,
        //    TS는 참조라 0으로 갈린다. 마찬가지로 effStat/rider 등 효과 관련 읽기·쓰기는 아래 부여 지점
        //    이전에 복사본으로 끝내고, **변이는 전부 배열 원소(from[ai]/to[di])로만** — TS 참조와 갈리지 않게.

        // 스킬 선택 — 레인보우가 충전 완료면 궁극기(정규 스킬 대체) 후 게이지 리셋, 아니면 결정적 선택 AI.
        // 스킬 타입 상성(×2.0/×0.5) + 자속(STAB ×1.5) 데미지식은 궁극기에도 동일 적용.
        let skill: Skill
        if let ult = attacker.ultimate, attacker.charge >= ultChargeCost {
            skill = ult
            from[ai].charge = 0
        } else {
            // E3 선택 AI — 자기버프 우선(미보유 버프·디버프 있을 때 cleanse). 상태는 시전 시점의 것.
            let activeIds = Set(attacker.effects.map { $0.effect.id })
            let hasDebuff = attacker.effects.contains { isDebuff($0.effect) }
            skill = SkillCatalog.select(from: attacker.skills, attackerType: attacker.type, defenderType: defender.type,
                                        activeEffectIds: activeIds, hasDebuff: hasDebuff)
        }
        let eff = SkillCatalog.skillEffectiveness(skill.type, vs: defender.type)   // 로그 effectiveness = 스킬 상성
        let stab = SkillCatalog.stab(skillType: skill.type, petType: attacker.type)
        // B/C. 컬렉션 상성(밈 라이벌 + 상성망) — 그대로 곱해진다.
        let synergy = PetSynergy.matchup(attacker.kind.collection, vs: defender.kind.collection)

        // 궁극기 특수효과(E2, §7.5) — 히트 변형은 아래 계산에, 부여/자힐은 히트 해소 후에 적용.
        let ultFx: SkillCatalog.UltimateEffect? = skill.tier == .ultimate ? SkillCatalog.ultimateEffectTable[skill.id] : nil

        let rngFactor = 0.9 + 0.1 * rng.uniform01()   // [0.9, 1.0)
        let rage = rageMultiplier(action: round)      // 장기전 데미지 점증(격노)
        // atk/def는 StatMod 효과 반영(effective). rm_rf 방어무시는 defEff에 ultDefIgnoreMult를 곱해 계산.
        let atkEff = effStat(attacker.stats.atk, .atk, attacker.effects)
        let defEff = effStat(defender.stats.def, .def, defender.effects)
        let defCalc = ultFx == .defIgnore ? max(1, Int((Double(defEff) * SkillCatalog.ultDefIgnoreMult).rounded())) : defEff
        let raw = (Double(atkEff) / Double(defCalc)) * skill.power * eff * stab * synergy.mult * rngFactor * rage
        let baseDmg = max(1, Int(raw.rounded()))

        // 레인보우(최종 이로치) 크리 — 공격자가 레인보우면 확률적 ×critMult. 조건부 draw라 비-레인보우
        // 배틀의 RNG 스트림·기존 골든은 불변. 순서: rngFactor → (레인보우면 크리) → 패링 (서버와 1:1).
        // 확정 크리(context_window_exceeded): 궁극기 시전자는 항상 레인보우라 draw가 반드시 소비되고,
        // **결과만 강제 true** — RNG 스트림이 forceCrit 유무와 무관하게 동일(§7.5 명세).
        var critDmg = baseDmg
        var crit = false
        if attacker.isRainbow {
            crit = rng.uniform01() < rainbowCritChance
            if ultFx == .forceCrit { crit = true }
            if crit { critDmg = max(1, Int((Double(baseDmg) * rainbowCritMult).rounded())) }
        }

        // 패링(퍼펙트 가드) — 방어자 SPD+DEF 조합 확률로 데미지 대폭 경감. 입력도 effective stat.
        let pc = parryChance(defSPD: effStat(defender.stats.spd, .spd, defender.effects), defDEF: defEff,
                             atkSPD: effStat(attacker.stats.spd, .spd, attacker.effects), atkDEF: effStat(attacker.stats.def, .def, attacker.effects))
        let parried = rng.uniform01() < pc
        let dmg = parried ? max(1, Int((Double(critDmg) * parryDamageMult).rounded())) : critDmg

        // Shield 흡수 — 실드부터 차감, 잔여만 HP로. (E1: 실드 미부여라 hpDmg == dmg 항상.
        //  E2에서 BattleEvent에 흡수량 필드 추가와 함께 UI HP fold 정합 처리.)
        let hpDmg = absorbShield(&to[di], dmg)
        to[di].hp -= hpDmg
        let fainted = to[di].hp <= 0
        // 피격 충전 — 맞은 쪽도 게이지 +1(막타 피격분 포함, 아래 승계로 이전됨). 지고 있어도 맞으면서
        // 차기 때문에 양측 충전 속도가 거의 대칭 → 패자 측도 궁극기를 보게 된다(격투게임 미터 방식).
        to[di].charge += 1
        // 게이지 승계 — 기절 시 잔여 게이지를 다음 생존 펫에게 이전(개인 게이지 → 팀 게이지).
        // ⚠️ 파리티: 반드시 배열 원소 to[di].charge를 읽고 쓸 것 — 지역 복사본 defender는 위 +1 이전의
        //    옛값이라(TS는 참조로 최신값) 양측이 갈린다. 순서 고정: HP 차감 → 피격 +1 → 승계.
        if fainted, let ni = active(to) {
            to[ni].charge += to[di].charge
        }

        let defenderSide: BattleSide = attackerSide == .a ? .b : .a

        // 광역(kernel_panic) — 후열 생존 전원에 최종 데미지 × ultSplashMult(개별 실드 흡수 적용).
        // 배열 앞 인덱스부터 순차(결정적) — 스플래시 기절도 피격 충전·게이지 승계 규칙 동일 적용.
        if ultFx == .splash {
            for j in to.indices where j != di && to[j].alive {
                let sdmg = max(1, Int((Double(dmg) * SkillCatalog.ultSplashMult).rounded()))
                let sHp = absorbShield(&to[j], sdmg)
                to[j].hp -= sHp
                to[j].charge += 1
                let sFaint = !to[j].alive
                events.append(EffectEvent(at: round, side: defenderSide, petKind: to[j].kind, kind: "splash",
                                          effectId: nil, hpDelta: -sHp, fainted: sFaint))
                if sFaint, let ni = active(to) { to[ni].charge += to[j].charge }
            }
        }

        // 궁극기 부여/자힐(§7.5) — 부여는 적 활성 대상(막타로 기절이면 생략), 자힐은 실제 회복량만 기록.
        switch ultFx {
        case .grant(let fxId):
            if to[di].alive, let def = EffectCatalog.effect(fxId) {
                grant(def, to: &to[di])
                events.append(EffectEvent(at: round, side: defenderSide, petKind: to[di].kind, kind: "grant",
                                          effectId: fxId, hpDelta: nil, fainted: nil))
            }
        case .selfHeal(let frac):
            let amt = max(1, Int((Double(from[ai].stats.hp) * frac).rounded()))
            let healed = min(from[ai].stats.hp - from[ai].hp, amt)
            if healed > 0 {
                from[ai].hp += healed
                events.append(EffectEvent(at: round, side: attackerSide, petKind: from[ai].kind, kind: "heal",
                                          effectId: skill.id, hpDelta: healed, fainted: nil))
            }
        default: break
        }

        // 스킬 부수효과(rider, §3) — chance 1.0은 확정(draw 없음), 확률형은 draw < chance.
        // 적 대상 rider는 막타로 기절 시 **draw까지 생략**(스트림 규칙 — 결정적, 양측 동일 판정).
        // grant가 false면(예: cleanse인데 지울 디버프가 없음) 이벤트 미기록 — 무의미한 로그 방지.
        if let r = skill.rider, let def = EffectCatalog.effect(r.effectId) {
            if r.selfTarget {
                if r.chance >= 1.0 || rng.uniform01() < r.chance {
                    if grant(def, to: &from[ai]) {
                        events.append(EffectEvent(at: round, side: attackerSide, petKind: from[ai].kind, kind: "grant",
                                                  effectId: r.effectId, hpDelta: nil, fainted: nil))
                    }
                }
            } else if to[di].alive {
                if r.chance >= 1.0 || rng.uniform01() < r.chance {
                    if grant(def, to: &to[di]) {
                        events.append(EffectEvent(at: round, side: defenderSide, petKind: to[di].kind, kind: "grant",
                                                  effectId: r.effectId, hpDelta: nil, fainted: nil))
                    }
                }
            }
        }

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
