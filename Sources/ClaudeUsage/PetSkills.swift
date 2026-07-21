import Foundation

// 펫 스킬 시스템 (Phase A) — 순수 로직. 서버 `_shared/pvp_policy.ts` 스킬 계층과 규칙 1:1.
// 설계 SSOT: docs/plans/pet-skills.md.
//
// 이로치(variant) 단계마다 스킬을 얻는다: variant 0 = generic("핫픽스"), variant 1 = typeShared(타입 6종).
// (Phase B에서 variant 2 collectionShared / variant 3 unique / variant 4 궁극기 추가 예정.)
// 데미지식은 "스킬 타입 vs 방어자 타입" 상성(×2.0/×0.5)과 자속(STAB ×1.5)으로 전환 — 패시브 ×1.6/0.625 대체.
// generic/typeShared 는 펫 타입에서 **규칙 파생**이라 per-kind 데이터가 없고, 양측 동일 로직으로 재현된다.

enum SkillTier: String, Codable, Equatable {
    case generic, typeShared, collectionShared, unique, ultimate
}

/// 한 개의 스킬. `type`은 6배틀타입 중 하나, `power`는 데미지 계수, `tier`는 획득 계층.
struct Skill: Equatable {
    let id: String
    let name: String
    let type: BattleType
    let power: Double
    let tier: SkillTier
}

enum SkillCatalog {
    // 스킬 상성 — 타입 6-사이클(`BattleType.beats`)을 재사용하고 배수만 ×2.0/×0.5로 전환(패시브 ×1.6/0.625 대체).
    static let skillSuper = 2.0
    static let skillWeak = 0.5

    /// 스킬 타입이 방어자 타입을 이기면 ×2.0, 지면 ×0.5, 중립 ×1.0. 서버 pvp_policy.skillEffectiveness 1:1.
    static func skillEffectiveness(_ skillType: BattleType, vs defender: BattleType) -> Double {
        if skillType.beats == defender { return skillSuper }
        if defender.beats == skillType { return skillWeak }
        return 1.0
    }

    /// 자속(STAB) — 스킬 타입 == 펫 타입이면 ×1.5(자기 타입 스킬 보상).
    static let stabMult = 1.5
    static func stab(skillType: BattleType, petType: BattleType) -> Double {
        skillType == petType ? stabMult : 1.0
    }

    static let genericPower = 8.0
    static let typeSharedPower = 11.0

    /// generic — 전 펫 공용(variant 0). 항상 펫 자기 타입(자속). id "hotfix".
    static func generic(for type: BattleType) -> Skill {
        Skill(id: "hotfix", name: "핫픽스", type: type, power: genericPower, tier: .generic)
    }

    /// typeShared — 같은 배틀 타입끼리 공유(variant 1). 자기 타입, power 11.
    static let typeSharedTable: [BattleType: (id: String, name: String)] = [
        .beast:   ("mem_leak", "메모리 릭"),
        .warrior: ("force_push", "강제 푸시"),
        .chaos:   ("friday_deploy", "금요일 배포"),
        .arcane:  ("context_overflow", "컨텍스트 폭발"),
        .machine: ("regression_sweep", "회귀 스윕"),
        .mascot:  ("onboarding", "온보딩"),
    ]
    static func typeShared(for type: BattleType) -> Skill {
        let e = typeSharedTable[type]!   // 6타입 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: type, power: typeSharedPower, tier: .typeShared)
    }

    /// 이 펫이 variant까지 해금한 정규 스킬 목록. 슬롯 인덱스 순(선택 AI tie-break 기준).
    /// 서버 pvp_policy.skillsFor 1:1.
    static func skills(kind: PetKind, variant: Int) -> [Skill] {
        let t = kind.battleType
        var out = [generic(for: t)]                         // 슬롯0 — 항상 보유
        if variant >= 1 { out.append(typeShared(for: t)) }  // 슬롯1 — 이로치1 해금
        // Phase B: variant>=2 collectionShared, variant>=3 unique, variant>=4 ultimate
        return out
    }

    /// 스킬 기대 데미지 점수 = power × skillEff × stab (결정적, RNG 없음).
    static func score(_ s: Skill, attackerType: BattleType, defenderType: BattleType) -> Double {
        s.power * skillEffectiveness(s.type, vs: defenderType) * stab(skillType: s.type, petType: attackerType)
    }

    /// 결정적 선택 AI — 점수 최대, 동점이면 슬롯 인덱스 낮은 것(strict >). 서버 selectSkill 1:1.
    static func select(from skills: [Skill], attackerType: BattleType, defenderType: BattleType) -> Skill {
        var best = skills[0]
        var bestScore = score(best, attackerType: attackerType, defenderType: defenderType)
        for s in skills.dropFirst() {
            let sc = score(s, attackerType: attackerType, defenderType: defenderType)
            if sc > bestScore { bestScore = sc; best = s }
        }
        return best
    }

    /// 스킬 id → 표시명(로그 UI). 구 로그의 "basic"/"signature"는 없음(호출부에서 레거시 폴백).
    static let nameById: [String: String] = {
        var m: [String: String] = ["hotfix": "핫픽스"]
        for (_, e) in typeSharedTable { m[e.id] = e.name }
        return m
    }()
    static func displayName(id: String) -> String? { nameById[id] }
}
