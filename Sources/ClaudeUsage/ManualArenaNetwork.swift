import Foundation

struct ManualArenaAPIError: LocalizedError {
    let code: String
    var errorDescription: String? {
        switch code {
        case "active_battle": return "진행 중인 서버 대전이 있습니다. 서버 상태를 새로고침해 이어서 진행하세요."
        case "daily_limit": return "오늘 서버 수동 도전 10회를 모두 사용했습니다."
        case "team_not_full": return "서버 도전에는 5마리 팀이 필요합니다."
        case "team_changed": return "등록 팀이 변경되었습니다. 편성을 확인한 뒤 다시 도전해 주세요."
        case "no_opponent": return "같은 테넌트에 등록된 5마리 상대 팀이 없습니다."
        case "revision_conflict": return "다른 화면에서 전투가 진행되었습니다. 서버 상태를 새로고침해 주세요."
        case "request_conflict": return "이전 명령과 요청 정보가 다릅니다. 서버 상태를 새로고침해 주세요."
        case "battle_closed": return "종료되거나 만료된 대전입니다. 서버 상태를 새로고침해 주세요."
        case "not_enabled": return "서버 수동 도전이 아직 활성화되지 않았습니다. 연습전은 사용할 수 있습니다."
        default: return "수동 도전 오류: \(code)"
        }
    }
}

struct ManualPendingRequest: Codable {
    let id: UUID
    let owner: String
    let action: String
    let battleID: UUID?
    let revision: Int
    let commandJSON: String
    let branchesJSON: String
}

@MainActor
protocol ManualArenaTransport {
    func status(owner: String, hmac: String) async throws -> RankingAPI.ManualArenaStatus
    func send(_ pending: ManualPendingRequest, hmac: String) async throws -> RankingAPI.ManualArenaResponse
    func register(team: [BattlePetSnapshot], owner: String, hmac: String) async throws
}

struct RankingManualArenaTransport: ManualArenaTransport {
    func status(owner: String, hmac: String) async throws -> RankingAPI.ManualArenaStatus {
        try await RankingAPI.shared.manualArenaStatus(deviceId: owner, hmac: hmac)
    }
    func send(_ p: ManualPendingRequest, hmac: String) async throws -> RankingAPI.ManualArenaResponse {
        try await RankingAPI.shared.manualArenaAction(deviceId: p.owner, hmac: hmac, action: p.action,
            requestID: p.id, battleID: p.battleID, revision: p.revision, commandJSON: p.commandJSON, branchesJSON: p.branchesJSON)
    }
    func register(team: [BattlePetSnapshot], owner: String, hmac: String) async throws {
        _ = try await RankingAPI.shared.registerBattleTeam(deviceId: owner, hmacKeyBase64: hmac,
            team: team.map { (kind: $0.kind.rawValue, variant: $0.variant, progressUnits: $0.progressUnits) })
    }
}
