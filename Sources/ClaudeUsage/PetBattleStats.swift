import Foundation

// 아레나(PvP) 배틀 스탯 체계 — 순수 로직 (P0). 서버/UI/에셋 무의존.
// 렌더용 PetDefinition·게임 trait(PetTraits)과 분리된 "전투 파생" 계층.
// 설계 SSOT: docs/plans/pet-battle.md §2-3 / §2-4 / §10.
//
// 스탯 = base(rarity) × archetype(type) × 성장(숙련도+강화) × variant.
// 성장 두 축: 숙련도(progressUnits, 무손실) + 강화 레벨(도박, 서버 RNG — EnhanceEngine).

/// 배틀 속성(타입) — 6타입 육각형 상성. `PetCollection`(19)에서 파생.
/// 상성 사이클: machine → beast → chaos → arcane → mascot → warrior → (machine).
/// 각 타입은 정확히 하나를 이기고 하나에 진다(사이클 = `beats`).
/// ⚠️ 실제 배틀 데미지 상성은 스킬 기반이다(`SkillCatalog.skillEffectiveness` ×2.0/×0.5 + STAB ×1.5).
/// 아래 `effectiveness`(패시브 ×1.6/0.625)는 스킬 전환(Phase A) 전 방식으로, 배틀 엔진은 더 이상 호출하지
/// 않는다(사이클 검증용 테스트만 참조). 사이클 자체(`beats`)는 스킬 상성이 재사용하는 SSOT다.
enum BattleType: String, CaseIterable, Codable, Hashable {
    case beast, warrior, chaos, arcane, machine, mascot

    /// 이 타입이 강하게(super-effective) 이기는 상대.
    var beats: BattleType {
        switch self {
        case .machine: return .beast
        case .beast:   return .chaos
        case .chaos:   return .arcane
        case .arcane:  return .mascot
        case .mascot:  return .warrior
        case .warrior: return .machine
        }
    }

    static let superMultiplier = 1.6
    static let weakMultiplier  = 0.625   // = 1 / 1.6

    /// [레거시 — 배틀 미사용] 패시브 타입 상성 배수 (1.6 / 1.0 / 0.625). 스킬 전환(Phase A) 이후
    /// 배틀은 `SkillCatalog.skillEffectiveness`(×2.0/×0.5)를 쓴다. 사이클 검증 테스트만 이 함수를 참조.
    static func effectiveness(_ attacker: BattleType, vs defender: BattleType) -> Double {
        if attacker.beats == defender { return superMultiplier }
        if defender.beats == attacker { return weakMultiplier }
        return 1.0
    }

    /// base를 4스탯(HP/ATK/DEF/SPD)으로 분배하는 archetype 배수. 합 ≈ 4.0에 근접.
    var archetype: (hp: Double, atk: Double, def: Double, spd: Double) {
        switch self {
        case .beast:   return (1.00, 1.05, 0.95, 1.10)
        case .warrior: return (1.00, 1.25, 0.95, 0.90)
        case .arcane:  return (0.85, 1.30, 0.80, 1.05)
        case .chaos:   return (0.90, 1.20, 0.85, 1.10)
        case .machine: return (1.05, 0.95, 1.35, 0.75)
        case .mascot:  return (1.35, 0.85, 1.10, 0.85)
        }
    }

    var displayName: String {
        switch self {
        case .beast:   return "Beast"
        case .warrior: return "Warrior"
        case .chaos:   return "Chaos"
        case .arcane:  return "Arcane"
        case .machine: return "Machine"
        case .mascot:  return "Mascot"
        }
    }
}

extension PetCollection {
    /// 컬렉션(19) → 배틀 타입(6). 밸런스 레버 — 종 편중 시 여기서 재배치.
    /// (docs/plans/pet-battle.md §2-4 매핑과 1:1)
    var battleType: BattleType {
        switch self {
        case .mainframe, .emotionalSupport, .npmInstall, .nodeModules, .dns, .deprecated:
            return .beast
        case .vibeCoders, .tenXEngineer, .onCall, .rustEvangelists, .noVerify:
            return .warrior
        case .wontfix, .oomKilled, .fridayDeploy:
            return .chaos
        case .tokenBurners, .todoSince2019:
            return .arcane
        case .ciRunners:
            return .machine
        case .happyPath, .helloWorld:
            return .mascot
        }
    }
}

extension PetKind {
    /// 이 펫의 배틀 타입 — 소속 컬렉션에서 파생. `collection`(PetTraits)과 동일 경로.
    var battleType: BattleType { collection.battleType }
}

/// 배틀 스탯 4종 (정수 — 데미지식 안정성).
struct BattleStats: Equatable, Codable, Hashable {
    var hp: Int
    var atk: Int
    var def: Int
    var spd: Int
    var total: Int { hp + atk + def + spd }
}

/// 스탯 파생 상수 + 계산기. 전부 pure/static — 서버 `_shared/pvp_policy.ts`(P1b 이식 예정)와 값 1:1이 목표.
enum PetBattleStats {
    /// 등급 기본치 (압축 곡선 — Common↔Mythic ≈ 2배, coinValue 곡선과 달리 완만).
    static func rarityBase(_ rarity: Rarity) -> Double {
        switch rarity {
        case .common:    return 40
        case .rare:      return 48
        case .epic:      return 56
        case .legendary: return 66
        case .mythic:    return 78
        }
    }

    /// 강화 레벨 +0…+15당 스탯 보너스(가속형). index = 강화 레벨.
    static let enhanceBonus: [Double] =
        [0, 0.04, 0.08, 0.13, 0.18, 0.25, 0.30, 0.36, 0.43, 0.51, 0.60, 0.70, 0.82, 0.95, 1.07, 1.20]

    /// variant(이로치) 보너스. index = variant (0 기본 / 1·2·3 이로치 / 4 레인보우).
    static let variantBonus: [Double] = [0, 0.03, 0.06, 0.10, 0.18]

    /// 숙련도(무손실 트랙) 최대 보너스.
    static let masteryMax: Double = 0.15

    /// 성장 배수 상한 (풀강 커먼 ≈ 중상위 등급 — 타입/조합이 여전히 승부를 가르게). 현 수치로는
    /// 이론 최대 성장(mastery .15 + enhance 1.20 = 2.35)이 이 값 미만이라 헤드룸 역할.
    static let statCapMult: Double = 2.6

    static let maxEnhanceLevel = 15

    /// progressUnits → 숙련도 보너스(0…masteryMax). 만렙 유닛(=overflowStartUnits, 8.0)에서 상한.
    static func masteryBonus(progressUnits: Double) -> Double {
        let cap = PetOwnership.overflowStartUnits   // 8.0
        guard cap > 0 else { return 0 }
        return masteryMax * min(1.0, max(0, progressUnits) / cap)
    }

    static func enhanceMultiplier(level: Int) -> Double {
        enhanceBonus[min(max(0, level), maxEnhanceLevel)]
    }

    static func variantMultiplier(variant: Int) -> Double {
        variantBonus[min(max(0, variant), variantBonus.count - 1)]
    }

    /// 최종 성장 배수 = min(cap, 1 + 숙련도 + 강화).
    static func growthMultiplier(enhanceLevel: Int, progressUnits: Double) -> Double {
        min(statCapMult, 1.0 + masteryBonus(progressUnits: progressUnits) + enhanceMultiplier(level: enhanceLevel))
    }

    /// 개체별 스탯 프로필 spread(±). 클수록 같은 rarity·type 펫 간 분배 차이가 커진다(총량은 유지).
    static let profileSpread: Double = 0.25

    /// FNV-1a 32비트 — kind rawValue(ASCII) 결정적 해시. 서버 pvp_policy.fnv1a32 와 bit-identical
    /// (UInt32 오버플로 곱 `&*` = JS `Math.imul(...)>>>0`, XOR는 비트연산이라 부호 무관). rawValue는 전부 ASCII.
    static func fnv1a32(_ s: String) -> UInt32 {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return h
    }

    /// 타입 archetype에 kind별 결정적 tilt를 곱하고 **합을 원래 archetype 합으로 정규화** → 총 전투력은
    /// rarity로 고정(밸런스 중립), 같은 rarity·type이라도 개체마다 분배(profile)만 달라진다. 자동·결정적이라
    /// 같은 kind는 항상 같은 프로필. 서버 pvp_policy.kindArchetype 와 1:1 (동일 해시·spread·정규화·연산 순서).
    static func profileArchetype(_ kind: PetKind) -> (hp: Double, atk: Double, def: Double, spd: Double) {
        let a = kind.battleType.archetype
        let raw = kind.rawValue
        func tilt(_ i: Int) -> Double {
            let n = Double(fnv1a32("\(raw)#\(i)")) / 4294967296.0 * 2.0 - 1.0   // [-1, 1)
            return 1.0 + profileSpread * n
        }
        let e0 = a.hp * tilt(0), e1 = a.atk * tilt(1), e2 = a.def * tilt(2), e3 = a.spd * tilt(3)
        let archSum = a.hp + a.atk + a.def + a.spd
        let effSum = e0 + e1 + e2 + e3
        let norm = effSum > 0 ? archSum / effSum : 1.0
        return (e0 * norm, e1 * norm, e2 * norm, e3 * norm)
    }

    /// 최종 배틀 스탯. rarity=base, type+kind=archetype 프로필, 성장/variant는 계정 상태에서.
    static func compute(kind: PetKind, variant: Int, enhanceLevel: Int, progressUnits: Double) -> BattleStats {
        let rarity = PetKind.rarityFor(kind) ?? .common
        let base = rarityBase(rarity)
        let a = profileArchetype(kind)
        let growth = growthMultiplier(enhanceLevel: enhanceLevel, progressUnits: progressUnits)
        let vb = 1.0 + variantMultiplier(variant: variant)
        func stat(_ arch: Double) -> Int { max(1, Int((base * arch * growth * vb).rounded())) }
        return BattleStats(hp: stat(a.hp), atk: stat(a.atk), def: stat(a.def), spd: stat(a.spd))
    }
}
