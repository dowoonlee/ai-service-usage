import Foundation

// 아레나(PvP) 배틀 스탯 체계 — 순수 로직 (P0). 서버/UI/에셋 무의존.
// 렌더용 PetDefinition·게임 trait(PetTraits)과 분리된 "전투 파생" 계층.
// 설계 SSOT: docs/plans/pet-battle.md §2-3 / §2-4 / §10.
//
// 스탯 = base(rarity) × archetype(type) × 성장(숙련도+강화) × variant.
// 성장 두 축: 숙련도(progressUnits, 무손실) + 강화 레벨(도박, 서버 RNG — EnhanceEngine).

/// 배틀 속성(타입) — 6타입 육각형 상성. `PetCollection`(19)에서 파생.
/// 상성 사이클: machine → beast → chaos → arcane → mascot → warrior → (machine).
/// 각 타입은 정확히 하나를 강하게 이기고(×1.6), 하나에 약하게 진다(×0.625).
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

    /// attacker가 defender를 칠 때 타입 상성 배수 (1.6 / 1.0 / 0.625).
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
    static let variantBonus: [Double] = [0, 0.02, 0.04, 0.06, 0.10]

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

    /// 최종 배틀 스탯. rarity/type은 kind에서 파생, 성장/variant는 계정 상태에서.
    static func compute(kind: PetKind, variant: Int, enhanceLevel: Int, progressUnits: Double) -> BattleStats {
        let rarity = PetKind.rarityFor(kind) ?? .common
        let base = rarityBase(rarity)
        let a = kind.battleType.archetype
        let growth = growthMultiplier(enhanceLevel: enhanceLevel, progressUnits: progressUnits)
        let vb = 1.0 + variantMultiplier(variant: variant)
        func stat(_ arch: Double) -> Int { max(1, Int((base * arch * growth * vb).rounded())) }
        return BattleStats(hp: stat(a.hp), atk: stat(a.atk), def: stat(a.def), spd: stat(a.spd))
    }
}
