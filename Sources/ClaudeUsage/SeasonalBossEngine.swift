import Foundation
import SwiftUI

// ============================================================================
// 시즌 보스 — 판정·보상 + 도장 배틀 상대 추상화 (cf. docs/plans/seasonal-events.md §24~26)
// ============================================================================
//
// 보스는 뱃지·지역과 무관하다. tier는 3번 보상 진행도(일)로 열리고, 보상은 시즌 인스턴스·tier당 1회
// (`seasonalFlags` "boss:<instanceID>:<tier>"). 팀은 지역 관장과 같은 EP 솔버라 같은 tier면 같은 난이도.
// 완전 로컬 — 서버 의존 0.

extension SeasonalBoss {
    /// 3번 보상 수령 일수 — `claimedGrants`에서 이 시즌의 일일 grant 접두 행을 센다.
    nonisolated static func rewardDayCount(season: Season, claimedGrants: Set<String>, now: Date,
                                           calendar: Calendar = .kst) -> Int {
        guard let prefix = season.rewardGrantPrefix(now: now, calendar: calendar) else { return 0 }
        return claimedGrants.filter { $0.hasPrefix(prefix) && Int($0.dropFirst(prefix.count)) != nil }.count
    }

    /// 보상 일수로 열린 tier들(낮은 순).
    nonisolated func openTiers(rewardDays: Int) -> [BadgeTier] {
        BadgeTier.allCases.filter { (tierThresholds[$0] ?? Int.max) <= rewardDays }
    }

    /// 대사 단계 — 0(미참여) / 1~5 / 6+ / production 격파. 마지막 줄("인정")은 격파 뒤에만 나온다.
    nonisolated static func stage(rewardDays: Int, productionCleared: Bool) -> Int {
        if productionCleared { return 3 }
        switch rewardDays {
        case ..<1: return 0
        case 1...5: return 1
        default: return 2
        }
    }

    nonisolated func dialogue(stage: Int) -> String {
        guard stage >= 0, stage < dialogues.count else { return "" }
        return dialogues[stage]
    }

    nonisolated func team(tier: BadgeTier) -> BattleTeam {
        GymLeader.team(lead: lead.kind, supports: supports.map(\.kind), tier: tier)
    }

    /// 재생·시트용 렌더 스킨 맵.
    nonisolated var skins: [PetKind: SkinnedPet] {
        var out: [PetKind: SkinnedPet] = [lead.kind: lead]
        for s in supports { out[s.kind] = s }
        return out
    }

    nonisolated static func flagKey(instanceID: String, tier: BadgeTier) -> String {
        "boss:\(instanceID):\(tier.rawValue)"
    }

    @MainActor
    func isCleared(tier: BadgeTier, season: Season, now: Date = Date(), settings: Settings? = nil) -> Bool {
        (settings ?? Settings.shared).seasonalFlags
            .contains(Self.flagKey(instanceID: season.instanceID(now: now), tier: tier))
    }

    /// 격파 보상 지급 — 인스턴스·tier당 1회. 이미 받았으면 nil. 코인은 ledger, 티켓은 로컬 재화.
    @MainActor
    @discardableResult
    func claimReward(tier: BadgeTier, season: Season, now: Date = Date()) -> BossReward? {
        let s = Settings.shared
        let key = Self.flagKey(instanceID: season.instanceID(now: now), tier: tier)
        guard !s.seasonalFlags.contains(key), let r = rewards[tier] else { return nil }
        s.seasonalFlags.insert(key)
        if r.coins > 0 { CoinLedger.shared.creditBonus(r.coins, reason: "season.\(key)") }
        if r.premiumTickets > 0 { s.premiumTickets += r.premiumTickets }
        DebugLog.log("SeasonalBoss: \(key) 격파 보상 +\(r.coins) coin, 프리미엄권 +\(r.premiumTickets)")
        return r
    }
}

/// 도장 배틀 시트의 상대 — 지역 관장 또는 시즌 보스. `GymBattleView`는 이것만 보고 지역을 모른다.
enum GymOpponent: Identifiable {
    case region(BadgeRegion, BadgeTier)
    case boss(Season, SeasonalBoss, BadgeTier)

    var id: String {
        switch self {
        case .region(let r, let t): return "region.\(r.rawValue).\(t.rawValue)"
        case .boss(let s, _, let t): return "boss.\(s.kind.rawValue).\(t.rawValue)"
        }
    }

    var tier: BadgeTier {
        switch self {
        case .region(_, let t), .boss(_, _, let t): return t
        }
    }

    var name: String {
        switch self {
        case .region(let r, _): return GymLeader.leader(for: r).name
        case .boss(_, let b, _): return b.name
        }
    }

    var subtitle: String {
        switch self {
        case .region(let r, let t): return "\(r.displayName) · \(t.displayName) 도장전"
        case .boss(let s, let b, let t): return "\(s.displayName) 관장 · \(t.displayName) · \(b.title)"
        }
    }

    var region: BadgeRegion? {
        if case .region(let r, _) = self { return r }
        return nil
    }

    var lead: SkinnedPet {
        switch self {
        case .region(let r, _): return SkinnedPet(kind: GymLeader.leader(for: r).kind)
        case .boss(_, let b, _): return b.lead
        }
    }

    var skins: [PetKind: SkinnedPet] {
        if case .boss(_, let b, _) = self { return b.skins }
        return [:]
    }

    func team() -> BattleTeam {
        switch self {
        case .region(let r, let t): return GymLeader.leader(for: r).team(tier: t)
        case .boss(_, let b, let t): return b.team(tier: t)
        }
    }

    func dialogue(stage: Int) -> String {
        switch self {
        case .region(let r, _): return GymLeader.leader(for: r).dialogue(stage: stage)
        case .boss(_, let b, _): return b.dialogue(stage: stage)
        }
    }

    struct WinOutcome {
        let coins: Int
        let premiumTickets: Int
        var isFirst: Bool { coins > 0 || premiumTickets > 0 }
    }

    /// 승리 처리 — 지역은 뱃지 클리어+코인(`defeatLeader`), 보스는 시즌 보상. 재승리는 0.
    @MainActor
    func onWin() -> WinOutcome {
        switch self {
        case .region(let r, let t):
            return WinOutcome(coins: BadgeRegistry.defeatLeader(region: r, tier: t), premiumTickets: 0)
        case .boss(let s, let b, let t):
            let r = b.claimReward(tier: t, season: s)
            return WinOutcome(coins: r?.coins ?? 0, premiumTickets: r?.premiumTickets ?? 0)
        }
    }

    /// 승리 배너 문구.
    func winHeadline(_ o: WinOutcome) -> String {
        switch self {
        case .region(let r, let t):
            return o.isFirst ? "🏅 \(r.displayName) · \(t.displayName) 도장 획득!" : "승리 — 이미 획득한 도장"
        case .boss(_, _, let t):
            return o.isFirst ? "❄️ 겨울 관장 \(t.displayName) 격파!" : "승리 — 이미 받은 보상"
        }
    }

    var loseText: String {
        switch self {
        case .region: return "패배… 관장을 이겨야 도장을 얻습니다"
        case .boss:   return "패배… 보상 일수를 더 채우면 낮은 tier부터 열립니다"
        }
    }
}
