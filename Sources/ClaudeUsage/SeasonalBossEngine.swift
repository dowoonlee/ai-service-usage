import Foundation
import SwiftUI

// ============================================================================
// 시즌 보스 — 판정·보상 + 도장 배틀 상대 추상화 (cf. docs/plans/seasonal-events.md §24~26)
// ============================================================================
//
// 보스는 뱃지·지역과 무관하다. tier는 오픈일 AND (사용 일수 OR 누적 VP)로 열리고, 보상은 시즌 인스턴스·tier당 1회
// (`seasonalFlags` "boss:<instanceID>:<tier>"). 팀은 지역 관장과 같은 EP 솔버라 같은 tier면 같은 난이도.
// 완전 로컬 — 서버 의존 0.

extension SeasonalBoss {
    /// 보스가 열린 뒤 AI를 쓴 날 수 — `dailyVP`(KST 날짜 → VP)에서 창 시작일~오늘 사이, 값이 있는 날.
    /// 로컬 기록이라 랭킹 미등록 사용자도 센다. 시작일 전 사용분은 치지 않는다.
    nonisolated func usageDayCount(dailyVP: [String: Double], now: Date, calendar: Calendar = .kst) -> Int {
        guard case .yearly(let start, _) = window.rule else { return 0 }
        let year = window.instanceYear(for: now, calendar: calendar)
        let from = UsageGrassModel.dayKey(year: year, month: start.month, day: start.day)
        let to = UsageGrassModel.dayKey(now)
        return dailyVP.filter { $0.value > 0 && $0.key >= from && $0.key <= to }.count
    }

    /// tier 오픈일(KST 00:00). 지정이 없으면 nil = 날짜 조건 없음.
    nonisolated func openDate(tier: BadgeTier, now: Date, calendar: Calendar = .kst) -> Date? {
        guard let md = tierOpenDates[tier] else { return nil }
        let year = window.instanceYear(for: now, calendar: calendar)
        return calendar.date(from: DateComponents(year: year, month: md.month, day: md.day))
    }

    /// 보스가 열린 뒤 누적 VP — 같은 구간의 `dailyVP` 합(내림).
    nonisolated func usageVP(dailyVP: [String: Double], now: Date, calendar: Calendar = .kst) -> Int {
        guard case .yearly(let start, _) = window.rule else { return 0 }
        let year = window.instanceYear(for: now, calendar: calendar)
        let from = UsageGrassModel.dayKey(year: year, month: start.month, day: start.day)
        let to = UsageGrassModel.dayKey(now)
        return Int(dailyVP.filter { $0.key >= from && $0.key <= to }.reduce(0) { $0 + max(0, $1.value) })
    }

    /// 보스 오픈 뒤의 참여량 — 일수와 VP.
    struct Usage: Equatable {
        var days: Int
        var vp: Int
    }

    nonisolated func usage(dailyVP: [String: Double], now: Date, calendar: Calendar = .kst) -> Usage {
        Usage(days: usageDayCount(dailyVP: dailyVP, now: now, calendar: calendar),
              vp: usageVP(dailyVP: dailyVP, now: now, calendar: calendar))
    }

    /// tier가 잠겨 있는 이유. 열려 있으면 nil. 날짜가 먼저다 — 날짜 전엔 참여량을 채워도 소용없으니.
    enum TierLock: Equatable {
        case date(month: Int, day: Int)
        /// 일수·VP 둘 다 모자람(하나만 채우면 열린다).
        case usage(have: Usage, needDays: Int, needVP: Int)
    }

    /// 오픈일 AND (사용 일수 OR 누적 VP).
    nonisolated func lock(tier: BadgeTier, usage: Usage, now: Date, calendar: Calendar = .kst) -> TierLock? {
        if let open = openDate(tier: tier, now: now, calendar: calendar), now < open,
           let md = tierOpenDates[tier] {
            return .date(month: md.month, day: md.day)
        }
        let needDays = tierThresholds[tier] ?? .max
        let needVP = tierUsageVP[tier] ?? .max
        if usage.days >= needDays || usage.vp >= needVP { return nil }
        return .usage(have: usage, needDays: needDays, needVP: needVP)
    }

    /// 열린 tier들(낮은 순).
    nonisolated func openTiers(usage: Usage, now: Date, calendar: Calendar = .kst) -> [BadgeTier] {
        BadgeTier.allCases.filter { lock(tier: $0, usage: usage, now: now, calendar: calendar) == nil }
    }

    /// 대사 단계 — 0(미참여) / 1~5 / 6+ / production 격파. 마지막 줄("인정")은 격파 뒤에만 나온다.
    nonisolated static func stage(usageDays: Int, productionCleared: Bool) -> Int {
        if productionCleared { return 3 }
        switch usageDays {
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
        case .boss:   return "패배… 파티를 정비해 다시 도전하세요"
        }
    }
}
