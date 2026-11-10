import XCTest
@testable import ClaudeUsage

/// 4번 — 겨울 관장. 보스 기간(11/16~), tier 오픈(오픈일 AND (사용 일수 OR 누적 VP)), 보상 1회 dedup, 칭호, 팀 구성, 스킨 렌더.
@MainActor
final class SeasonalBossTests: SandboxedTestCase {
    private var xmas: Season { SeasonRegistry.season(.xmas)! }
    private var boss: SeasonalBoss { xmas.boss! }
    private func kst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.kst.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    /// `days`일치 사용 기록(시작일부터 연속).
    private func usage(from start: Date, days: Int) -> [String: Double] {
        var m: [String: Double] = [:]
        for i in 0..<days {
            m[UsageGrassModel.dayKey(Calendar.kst.date(byAdding: .day, value: i, to: start)!)] = 100
        }
        return m
    }

    /// 보스는 11/16에 열리고 12/26에 닫힌다. 올해는 시즌 창과 같다(눈·모자·상점도 11/16부터).
    func testBossWindowOpensWithSeason() {
        SeasonRegistry.override = nil
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 11, 15)))
        XCTAssertEqual(SeasonRegistry.activeBoss(now: kst(2026, 11, 16))?.season.kind, .xmas)
        XCTAssertEqual(SeasonRegistry.active(now: kst(2026, 11, 16))?.kind, .xmas, "시즌 연출도 같은 날 켜진다")
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 11, 15)))
        XCTAssertNotNil(SeasonRegistry.activeBoss(now: kst(2026, 12, 25)))
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 12, 26)))
        // 보상 dedup 키의 연도는 11월에도 같은 인스턴스.
        XCTAssertEqual(xmas.instanceID(now: kst(2026, 11, 20)), xmas.instanceID(now: kst(2026, 12, 20)))
        // 스위치는 시즌과 같다.
        let s = Settings.shared
        s.seasonalEffectsEnabled = false
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 11, 20)))
        s.seasonalEffectsEnabled = true
        s.disabledSeasons = ["xmas"]
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 11, 20)))
        s.disabledSeasons = []
        SeasonRegistry.override = Override.none
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 11, 20)))
        SeasonRegistry.override = .season(.xmas)
        XCTAssertNotNil(SeasonRegistry.activeBoss(now: kst(2026, 7, 1)))
    }

    /// 사용 일수는 보스 오픈일(11/16)부터 오늘까지, 값이 있는 날만.
    func testUsageDayCountStartsAtBossOpen() {
        var m = usage(from: kst(2026, 11, 10), days: 10)        // 11/10~11/19 — 오픈 전 6일은 안 친다
        XCTAssertEqual(boss.usageDayCount(dailyVP: m, now: kst(2026, 11, 19)), 4)
        m["2026-11-20"] = 0                                     // 0 VP인 날은 사용일이 아니다
        m["2026-11-25"] = 50                                    // 미래 키(시계 되돌림)는 오늘까지만
        XCTAssertEqual(boss.usageDayCount(dailyVP: m, now: kst(2026, 11, 21)), 4)
        XCTAssertEqual(boss.usageDayCount(dailyVP: m, now: kst(2026, 11, 25)), 5)
        m["2025-12-01"] = 50                                    // 작년 인스턴스는 무관
        XCTAssertEqual(boss.usageDayCount(dailyVP: m, now: kst(2026, 11, 25)), 5)
        XCTAssertEqual(boss.usageDayCount(dailyVP: [:], now: kst(2026, 12, 1)), 0)
    }

    private typealias U = SeasonalBoss.Usage

    /// 핵심 계약 — 오픈일 AND (사용 일수 OR 누적 VP).
    func testTierNeedsOpenDateAndEitherDaysOrVP() {
        let lots = U(days: 99, vp: 99_999)
        // 참여량은 넘치지만 날짜가 안 됨: 11/22엔 dev(11/23)가 잠김.
        XCTAssertEqual(boss.openTiers(usage: lots, now: kst(2026, 11, 22)), [.localhost])
        XCTAssertEqual(boss.lock(tier: .dev, usage: lots, now: kst(2026, 11, 22)), .date(month: 11, day: 23))
        XCTAssertEqual(boss.openTiers(usage: lots, now: kst(2026, 11, 23)), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(usage: lots, now: kst(2026, 11, 30)), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usage: lots, now: kst(2026, 12, 6)), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usage: lots, now: kst(2026, 12, 7)), BadgeTier.allCases)

        let late = kst(2026, 12, 20)        // 날짜는 전부 지남
        // 일수만으로.
        XCTAssertEqual(boss.openTiers(usage: U(days: 0, vp: 0), now: late), [.localhost])
        XCTAssertEqual(boss.openTiers(usage: U(days: 5, vp: 0), now: late), [.localhost])
        XCTAssertEqual(boss.openTiers(usage: U(days: 6, vp: 0), now: late), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(usage: U(days: 17, vp: 0), now: late), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usage: U(days: 18, vp: 0), now: late), BadgeTier.allCases)
        // VP만으로 — 늦게 시작해 일수가 모자라도 몰아 쓰면 열린다.
        XCTAssertEqual(boss.openTiers(usage: U(days: 1, vp: 399), now: late), [.localhost])
        XCTAssertEqual(boss.openTiers(usage: U(days: 1, vp: 400), now: late), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(usage: U(days: 1, vp: 800), now: late), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usage: U(days: 3, vp: 1_200), now: late), BadgeTier.allCases)
        // 한쪽씩 다른 tier를 열 수도 있다.
        XCTAssertEqual(boss.openTiers(usage: U(days: 6, vp: 800), now: late), [.localhost, .dev, .staging])
        // 둘 다 모자라면 양쪽 기준을 알려 준다.
        XCTAssertEqual(boss.lock(tier: .production, usage: U(days: 17, vp: 1_199), now: late),
                       .usage(have: U(days: 17, vp: 1_199), needDays: 18, needVP: 1_200))
        XCTAssertNil(boss.lock(tier: .localhost, usage: U(days: 0, vp: 0), now: kst(2026, 11, 16)))
        // 날짜도 참여량도 모자라면 날짜를 먼저 알린다.
        XCTAssertEqual(boss.lock(tier: .production, usage: U(days: 2, vp: 10), now: kst(2026, 11, 20)),
                       .date(month: 12, day: 7))
        // 오픈일 경계는 KST 0시.
        let midnight = Calendar.kst.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        XCTAssertNotNil(boss.lock(tier: .dev, usage: U(days: 6, vp: 0), now: midnight.addingTimeInterval(-1)))
        XCTAssertNil(boss.lock(tier: .dev, usage: U(days: 6, vp: 0), now: midnight))
    }

    /// 누적 VP도 일수와 같은 구간(11/16~오늘)만 더한다.
    func testUsageVPSumsSameWindowAsDays() {
        let m: [String: Double] = ["2026-11-15": 500, "2026-11-16": 120.6, "2026-11-20": 80.5,
                                   "2026-11-21": 0, "2026-12-30": 999, "2025-11-20": 999]
        XCTAssertEqual(boss.usage(dailyVP: m, now: kst(2026, 11, 25)), U(days: 2, vp: 201))
        XCTAssertEqual(boss.usageVP(dailyVP: m, now: kst(2026, 11, 16)), 120)
    }

    /// 오픈일은 낮은 tier부터 순서대로이고 전부 보스 기간 안이다. 기준도 tier 순으로 커진다.
    /// 매일 쓰면 오픈일에 일수 조건이 이미 차 있고, 12/20에 시작해도 VP로 production에 닿을 수 있다(월 2,000 VP 플랜 기준).
    func testTierOpenDatesAreOrderedInsideWindowAndReachable() {
        var prev: Date?
        for tier in BadgeTier.allCases {
            let open = boss.openDate(tier: tier, now: kst(2026, 11, 20))!
            XCTAssertTrue(boss.window.contains(open), "\(tier) 오픈일이 보스 기간 밖")
            if let prev { XCTAssertGreaterThan(open, prev) }
            prev = open
            let daily = usage(from: kst(2026, 11, 16), days: 60).mapValues { _ in 1.0 }   // VP는 거의 없이 일수만
            XCTAssertNil(boss.lock(tier: tier, usage: boss.usage(dailyVP: daily, now: open), now: open),
                         "\(tier): 매일 써도 오픈일에 안 열림")
        }
        for (a, b) in zip(BadgeTier.allCases, BadgeTier.allCases.dropFirst()) {
            XCTAssertLessThan(boss.tierThresholds[a]!, boss.tierThresholds[b]!)
            XCTAssertLessThan(boss.tierUsageVP[a]!, boss.tierUsageVP[b]!)
        }
        XCTAssertLessThanOrEqual(boss.tierUsageVP[.production]!, 2_000, "Pro 한 달 최대 VP 안이어야 저가 플랜도 VP로 닿는다")
    }

    func testStageMapping() {
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 0, productionCleared: false), 0)
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 1, productionCleared: false), 1)
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 5, productionCleared: false), 1)
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 6, productionCleared: false), 2)
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 24, productionCleared: false), 2)   // 마지막 줄은 격파 뒤에만
        XCTAssertEqual(SeasonalBoss.stage(usageDays: 0, productionCleared: true), 3)
    }

    func testClaimRewardOncePerInstanceAndTier() {
        let s = Settings.shared
        let coins0 = s.coins, tickets0 = s.premiumTickets
        let now = kst(2026, 12, 20)
        let r1 = boss.claimReward(tier: .production, season: xmas, now: now)
        XCTAssertEqual(r1?.coins, 15_000)
        XCTAssertEqual(r1?.premiumTickets, 1)
        XCTAssertEqual(s.coins, coins0 + 15_000)
        XCTAssertEqual(s.premiumTickets, tickets0 + 1)
        XCTAssertTrue(boss.isCleared(tier: .production, season: xmas, now: now, settings: s))
        // 재승리 — 0
        XCTAssertNil(boss.claimReward(tier: .production, season: xmas, now: now))
        XCTAssertEqual(s.coins, coins0 + 15_000)
        XCTAssertEqual(s.premiumTickets, tickets0 + 1)
        // 다른 tier는 별도
        XCTAssertEqual(boss.claimReward(tier: .localhost, season: xmas, now: now)?.coins, 1_000)
        // 내년 인스턴스는 다시
        XCTAssertEqual(boss.claimReward(tier: .production, season: xmas, now: kst(2027, 12, 20))?.coins, 15_000)
        XCTAssertEqual(s.seasonalFlags.filter { $0.hasPrefix("boss:xmas-") }.count, 3)
    }

    func testProductionClearUnlocksSnowDeployerTitle() {
        let s = Settings.shared
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.snowDeployer))
        boss.claimReward(tier: .staging, season: xmas, now: kst(2026, 12, 20))
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.snowDeployer))
        boss.claimReward(tier: .production, season: xmas, now: kst(2026, 12, 20))
        XCTAssertTrue(CardTitle.unlocked(in: s).contains(.snowDeployer))
    }

    func testBossTeamSharesRegionLeaderSolver() {
        let team = boss.team(tier: .production)
        XCTAssertEqual(team.members.count, 5)
        XCTAssertEqual(team.members.first?.kind, .deer)
        XCTAssertEqual(team.members.first?.variant, BattleEngine.rainbowVariant)
        for m in team.members.dropFirst() {
            XCTAssertEqual(m.variant, 0)
            XCTAssertEqual(PetKind.rarityFor(m.kind), .common, "\(m.kind) 서포터는 common")
        }
        // 같은 솔버: 같은 선봉·서포터로 지역식 호출과 결과가 동일
        let viaStatic = GymLeader.team(lead: .deer, supports: boss.supports.map(\.kind), tier: .production)
        XCTAssertEqual(team, viaStatic)
        // 스냅샷 인코딩에 스킨이 끼지 않는다(파리티 보호).
        let data = try? JSONEncoder().encode(team)
        XCTAssertFalse(String(data: data ?? Data(), encoding: .utf8)?.contains("skin") ?? true)
    }

    func testOpponentWinOutcomeForBoss() {
        let o = GymOpponent.boss(xmas, boss, .dev)
        XCTAssertEqual(o.tier, .dev)
        XCTAssertNil(o.region)
        XCTAssertEqual(o.skins.count, 5)
        XCTAssertEqual(o.lead.headwear, "santa_hat")
        let w = o.onWin()
        XCTAssertEqual(w.coins, 3_000)
        XCTAssertTrue(o.winHeadline(w).contains("격파"))
        let again = o.onWin()
        XCTAssertFalse(again.isFirst)
    }

    func testSnowSkinRendersAndIsCached() {
        let a = PetSprite.image(for: .bear, action: .walk, frameIndex: 0, skin: .snow)
        let b = PetSprite.image(for: .bear, action: .walk, frameIndex: 0, skin: .snow)
        XCTAssertNotNil(a)
        XCTAssertTrue(a === b, "캐시된 같은 인스턴스")
        XCTAssertNotNil(PetSprite.composedImage(for: .deer, action: .scan, frameIndex: 0, skin: nil, headwear: "santa_hat"))
    }
}
