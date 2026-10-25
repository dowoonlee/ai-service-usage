import Foundation

enum ManualAchievement: String, Codable, CaseIterable, Identifiable {
    case firstCommand = "first_command"
    case typeExpert = "type_expert"
    case switchCounter = "switch_counter"
    case speedPlanner = "speed_planner"
    case ultimateReserve = "ultimate_reserve"
    case dualUltimate = "dual_ultimate"
    case lastStand = "last_stand"
    case teamRecovery = "team_recovery"
    var id: String { rawValue }
    var hidden: Bool { self == .lastStand || self == .teamRecovery }
    var target: Int { self == .typeExpert ? 10 : 1 }
    var name: String {
        switch self {
        case .firstCommand: return "첫 지휘"
        case .typeExpert: return "효과는 굉장했다"
        case .switchCounter: return "선수 교체"
        case .speedPlanner: return "계획대로"
        case .ultimateReserve: return "아직 한 발 남았다"
        case .dualUltimate: return "두 가지 해답"
        case .lastStand: return "마지막까지"
        case .teamRecovery: return "함께 이룬 승리"
        }
    }
    var condition: String {
        switch self {
        case .firstCommand: return "수동 전투에서 처음 승리하세요."
        case .typeExpert: return "유리한 상성의 직접 공격으로 상대 10마리를 처치하세요."
        case .switchCounter: return "교체한 펫이 반감 공격을 받고 바로 다음 턴 직접 공격으로 상대를 처치하세요."
        case .speedPlanner: return "속도 감소로 실제 선후공을 뒤집은 턴에 선공으로 상대를 처치하세요."
        case .ultimateReserve: return "궁극기 준비 상태에서 일반기로 처치하고, 이후 궁극기로 다른 상대를 처치하세요."
        case .dualUltimate: return "같은 레인보우 펫으로 궁극기 A·B를 각각 유효하게 사용한 경기에서 승리하세요."
        case .lastStand: return "내 생존 펫 1마리·상대 3마리 이상인 상황에서 역전승하세요."
        case .teamRecovery: return "체크포인트 한 번으로 아군 3마리 이상을 실제 회복시키고 승리하세요."
        }
    }
    var rewardName: String {
        switch self {
        case .firstCommand: return "첫 지휘관"
        case .typeExpert: return "상성 전문가"
        case .switchCounter: return "교대의 명수"
        case .speedPlanner: return "전술 설계자"
        case .ultimateReserve: return "한 발의 여유"
        case .dualUltimate: return "양면의 지휘관"
        case .lastStand: return "역전의 지휘관"
        case .teamRecovery: return "팀의 수호자"
        }
    }
    var rewardTitle: CardTitle {
        switch self {
        case .firstCommand: return .manualCommander
        case .typeExpert: return .manualTypeExpert
        case .switchCounter: return .manualSwitcher
        case .speedPlanner: return .manualPlanner
        case .ultimateReserve: return .manualReserve
        case .dualUltimate: return .manualDual
        case .lastStand: return .manualComeback
        case .teamRecovery: return .manualSupport
        }
    }
    static func forTitle(_ title: CardTitle) -> ManualAchievement? { allCases.first { $0.rewardTitle == title } }
}

struct ManualAchievementProgress: Codable, Equatable {
    var progress: [String: Int] = [:]
    var unlocked: [String] = []
    func contains(_ achievement: ManualAchievement) -> Bool { unlocked.contains(achievement.rawValue) }
    func value(_ achievement: ManualAchievement) -> Int { min(achievement.target, progress[achievement.rawValue, default: 0]) }

    /// Caller deduplicates by battle ID. This evaluator is shared by practice previews and test vectors.
    mutating func apply(_ state: ManualBattleState, mastery: [String: ManualMasteryRecord]) {
        guard !state.tutorial, let outcome = state.outcome, ["knockout", "turnLimit"].contains(outcome.reason) else { return }
        for a in ManualAchievement.allCases {
            let increment: Int
            switch a {
            case .firstCommand: increment = outcome.winner == 0 ? 1 : 0
            case .dualUltimate:
                increment = mastery.values.contains { $0.originalWins > 0 && $0.alternateWins > 0 } ? 1 : 0
            case .lastStand:
                increment = outcome.winner == 0 && state.events.contains { $0.kind == "comebackWindow" && $0.side == 0 } ? 1 : 0
            case .teamRecovery:
                increment = outcome.winner == 0 && state.events.contains { $0.kind == "achievementFact" && $0.moveID == a.rawValue && $0.side == 0 } ? 1 : 0
            default:
                increment = min(a == .typeExpert ? 5 : 1,
                    state.events.filter { $0.kind == "achievementFact" && $0.moveID == a.rawValue && $0.side == 0 }.count)
            }
            progress[a.rawValue] = min(a.target, progress[a.rawValue, default: 0] + increment)
            if progress[a.rawValue, default: 0] >= a.target && !contains(a) { unlocked.append(a.rawValue) }
        }
    }
}
