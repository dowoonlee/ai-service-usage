import Foundation

/// The interactive ruleset is deliberately separate from the shipped ATB simulator.
enum ManualBranch: String, Codable, CaseIterable, Identifiable {
    case original, alternate
    var id: String { rawValue }
    var label: String { self == .original ? "A" : "B" }
}

struct ManualMove: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var type: String
    var power: Double
    var maxPP: Int? // nil: unlimited, or ultimate (paid using charge)
    var effect: String?
    var chance: Double
    var selfTarget: Bool
    var ultimate: Bool
    var special: String?
    var summary: String
}

struct ManualEffect: Codable, Equatable {
    var id: String
    var applied: Int
    var expires: Int
    var sequence: Int
    var shield: Int = 0
}

struct ManualFighter: Codable, Equatable, Identifiable {
    var id: Int
    var pet: BattlePetSnapshot
    var stats: BattleStats
    var hp: Int
    var moves: [ManualMove]
    var pp: [String: Int]
    var branch: ManualBranch
    var effects: [ManualEffect] = []
    var immuneUntil: Int = 0
    var participated = false
    var ultimateUsed = false
    var alive: Bool { hp > 0 }
    var type: BattleType { pet.kind.battleType }
}

struct ManualTeam: Codable, Equatable {
    var fighters: [ManualFighter]
    var active: Int = 0
    var charge = 0
    var lastGuard = -1
    var lastSwitch = -1
    var alive: Bool { fighters.contains { $0.alive } }
    var needsReplacement: Bool { alive && !fighters[active].alive }
}

enum ManualCommand: Codable, Equatable {
    case move(String), swap(Int), guardMove, replacement(Int), surrender
}

struct ManualEvent: Codable, Equatable, Identifiable {
    var id: Int
    var turn: Int
    var side: Int
    var slot: Int
    var kind: String
    var text: String
    var hp: Int?
    var amount: Int?
    var moveID: String?
}

struct ManualOutcome: Codable, Equatable {
    var winner: Int?
    var reason: String
}

struct ManualBattleState: Codable, Equatable, Identifiable {
    static let version = 1
    var id: UUID
    var rulesVersion = version
    var turn = 1
    var revision = 0
    var teams: [ManualTeam]
    // Decimal strings preserve all 64 bits through JavaScript/JSON transports.
    var seed: String
    var randomState: String
    var events: [ManualEvent] = []
    var outcome: ManualOutcome?
    var committedAI: ManualCommand?
    var tutorial: Bool
    var effectSequence = 0
    var achievementsEligible: Bool? = nil // Server-owned eligibility, never inferred from client battle results.
    var finished: Bool { outcome != nil }
}

enum ManualBattleError: LocalizedError {
    case invalidTeam, invalidCommand, incompatibleVersion, corruptSave
    var errorDescription: String? {
        switch self {
        case .invalidTeam: return "서로 같은 수의 중복 없는 펫 1~5마리가 필요합니다."
        case .invalidCommand: return "현재 사용할 수 없는 명령입니다. 상태를 확인해 주세요."
        case .incompatibleVersion: return "다른 전투 규칙으로 저장된 경기입니다. 새 연습전을 시작해 주세요."
        case .corruptSave: return "저장된 연습전을 읽을 수 없습니다. 새 경기로 다시 시작할 수 있습니다."
        }
    }
}

enum ManualBattleRules {
    static func moves(for pet: BattlePetSnapshot, branch: ManualBranch) -> [ManualMove] {
        var moves = SkillCatalog.skills(kind: pet.kind, variant: pet.variant).map { skill -> ManualMove in
            let tactical = skill.tier == .typeShared
            let pp: Int? = skill.tier == .generic ? nil : (skill.tier == .unique ? 2 : 3)
            let effect = skill.rider?.effectId
            let chance = tactical ? 1.0 : (skill.rider?.chance ?? 0)
            let description = effect.map { effectSummary($0) } ?? "추가 효과 없음"
            return ManualMove(id: skill.id, name: skill.name, type: skill.type.rawValue,
                power: tactical ? 6 : skill.power, maxPP: pp, effect: effect,
                chance: chance, selfTarget: skill.rider?.selfTarget ?? false, ultimate: false,
                special: nil, summary: effect == nil ? description : "\(Int(chance * 100))% · \(description)")
        }
        if pet.variant >= PetOwnership.prestigeVariant { moves.append(ultimate(pet.kind.battleType, branch: branch)) }
        return moves
    }

    static func ultimate(_ type: BattleType, branch: ManualBranch) -> ManualMove {
        let skill = SkillCatalog.ultimate(for: type)
        var move = ManualMove(id: skill.id, name: skill.name, type: type.rawValue, power: 24,
            maxPP: nil, effect: nil, chance: 1, selfTarget: false, ultimate: true,
            special: nil, summary: "")
        if branch == .original {
            switch type {
            case .beast: move.special = "splash"; move.summary = "상대 벤치에 직접 피해의 30%"
            case .warrior: move.special = "pierce"; move.summary = "상대 방어력의 30%로 피해 계산"
            case .chaos: move.effect = "outage_stun"; move.summary = "다음 턴 행동불가"
            case .arcane: move.special = "critical"; move.summary = "확정 치명타 1.5배"
            case .machine: move.effect = "bsod_lag"; move.summary = "상대 속도 40% 감소 · 2턴"
            case .mascot: move.special = "healSelf"; move.summary = "공격 후 자신의 최대 HP 25% 회복"
            }
        } else {
            switch type {
            case .beast:
                move.id = "focused_debug"; move.name = "집중 디버깅"; move.power = 30
                move.summary = "광역 없이 한 상대에게 강한 공격"
            case .warrior:
                move.id = "rolling_deploy"; move.name = "롤링 배포"; move.power = 18
                move.effect = "firewall"; move.selfTarget = true; move.summary = "공격 후 자신의 방어력 30% 증가 · 3턴"
            case .chaos:
                move.id = "cascading_failure"; move.name = "장애 전파"; move.power = 16
                move.special = "spread"; move.summary = "상대 생존 전원에게 최대 HP 5% 지속 피해 · 2턴"
            case .arcane:
                move.id = "cache_invalidation"; move.name = "캐시 무효화"; move.power = 18
                move.special = "dispelShield"; move.summary = "상대 실드를 제거한 뒤 공격"
            case .machine:
                move.id = "safe_mode"; move.name = "세이프 모드"; move.power = 16
                move.effect = "safe_shield"; move.selfTarget = true; move.summary = "공격 후 최대 HP 30% 실드 · 3턴"
            case .mascot:
                move.id = "checkpoint"; move.name = "체크포인트"; move.power = 0
                move.special = "healTeam"; move.summary = "공격 없이 살아 있는 아군 전체 HP 15% 회복"
            }
        }
        return move
    }

    static func duration(_ id: String) -> Int {
        switch id {
        case "deadlock", "bsod_lag", "spread_dot": return 2
        case "rate_limited", "outage_stun": return 1
        case "hot_reload": return 0
        default: return 3
        }
    }
    static func isControl(_ id: String) -> Bool { ["deadlock", "rate_limited", "outage_stun"].contains(id) }
    static func isShield(_ id: String) -> Bool { ["load_balancer", "safe_shield"].contains(id) }
    static func isBuff(_ id: String) -> Bool {
        ["optimization", "firewall", "caching", "load_balancer", "autoscaling", "safe_shield"].contains(id)
    }
    static func magnitude(_ id: String) -> Double {
        switch id {
        case "mem_leak", "spread_dot": return 0.05
        case "infinite_loop": return 0.08
        case "autoscaling": return 0.06
        case "load_balancer": return 0.20
        case "safe_shield": return 0.30
        default: return 0
        }
    }
    static func effectName(_ id: String) -> String {
        if id == "spread_dot" { return "장애 전파" }
        if id == "safe_shield" { return "세이프 모드" }
        return EffectCatalog.displayName(id) ?? id
    }
    static func effectSummary(_ id: String) -> String {
        switch id {
        case "mem_leak": return "메모리 릭 · 최대 HP 5% 피해, 다음 3턴"
        case "infinite_loop": return "무한 루프 · 최대 HP 8% 피해, 다음 3턴"
        case "deadlock": return "데드락 · 다음 2턴 35% 확률 행동불가"
        case "rate_limited", "outage_stun": return "다음 1턴 행동불가"
        case "tech_debt": return "공격력 20% 감소 · 3턴"
        case "legacy": return "속도 25% 감소 · 3턴"
        case "optimization": return "공격력 25% 증가 · 3턴"
        case "firewall": return "방어력 30% 증가 · 3턴"
        case "caching": return "속도 25% 증가 · 3턴"
        case "load_balancer": return "최대 HP 20% 실드 · 3턴"
        case "autoscaling": return "최대 HP 6% 회복, 다음 3턴"
        case "hot_reload": return "자신의 디버프 해제"
        default: return effectName(id)
        }
    }
    static func stat(_ fighter: ManualFighter, _ key: StatKind) -> Int {
        let base: Int
        switch key { case .hp: base = fighter.stats.hp; case .atk: base = fighter.stats.atk
        case .def: base = fighter.stats.def; case .spd: base = fighter.stats.spd }
        var multiplier = 1.0
        for effect in fighter.effects {
            switch (key, effect.id) {
            case (.atk, "tech_debt"): multiplier *= 0.8
            case (.atk, "optimization"): multiplier *= 1.25
            case (.def, "firewall"): multiplier *= 1.3
            case (.spd, "legacy"): multiplier *= 0.75
            case (.spd, "bsod_lag"): multiplier *= 0.6
            case (.spd, "caching"): multiplier *= 1.25
            default: break
            }
        }
        return max(1, Int((Double(base) * multiplier).rounded()))
    }
    static func damage(_ move: ManualMove, from: ManualFighter, to: ManualFighter,
                       factor: Double = 0.95, guarded: Bool = false) -> Int {
        guard move.power > 0, let type = BattleType(rawValue: move.type) else { return 0 }
        let defense = Double(stat(to, .def)) * (move.special == "pierce" ? 0.3 : 1)
        let raw = Double(stat(from, .atk)) / max(1, defense) * move.power
            * SkillCatalog.skillEffectiveness(type, vs: to.type)
            * SkillCatalog.stab(skillType: type, petType: from.type)
            * PetSynergy.matchup(from.pet.kind.collection, vs: to.pet.kind.collection).mult
            * factor * (move.special == "critical" ? 1.5 : 1) * (guarded ? 0.5 : 1)
        return max(1, Int(raw.rounded()))
    }
}
