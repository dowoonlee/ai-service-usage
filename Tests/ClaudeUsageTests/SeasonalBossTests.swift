import XCTest
@testable import ClaudeUsage

/// 4번 — 겨울 관장. 보스 기간(11/16~), tier 오픈(사용 일수 + 오픈일), 보상 1회 dedup, 칭호, 팀 구성, 스킨 렌더.
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

    /// 보스는 시즌(12/1~)보다 먼저 11/16에 열리고 12/26에 닫힌다.
    func testBossWindowOpensBeforeSeason() {
        SeasonRegistry.override = nil
        XCTAssertNil(SeasonRegistry.activeBoss(now: kst(2026, 11, 15)))
        XCTAssertEqual(SeasonRegistry.activeBoss(now: kst(2026, 11, 16))?.season.kind, .xmas)
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 11, 16)), "시즌 연출은 아직")
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

    /// 핵심 계약 — 사용 일수와 오픈일을 **둘 다** 채워야 열린다.
    func testTierNeedsBothUsageDaysAndOpenDate() {
        // 일수는 넘치지만 날짜가 안 됨: 11/22엔 dev(11/23)가 잠김.
        XCTAssertEqual(boss.openTiers(usageDays: 99, now: kst(2026, 11, 22)), [.localhost])
        XCTAssertEqual(boss.lock(tier: .dev, usageDays: 99, now: kst(2026, 11, 22)), .date(month: 11, day: 23))
        XCTAssertEqual(boss.openTiers(usageDays: 99, now: kst(2026, 11, 23)), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(usageDays: 99, now: kst(2026, 11, 30)), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usageDays: 99, now: kst(2026, 12, 6)), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usageDays: 99, now: kst(2026, 12, 7)), BadgeTier.allCases)
        // 날짜는 됐지만 일수가 모자람.
        XCTAssertEqual(boss.openTiers(usageDays: 0, now: kst(2026, 12, 20)), [.localhost])
        XCTAssertEqual(boss.openTiers(usageDays: 5, now: kst(2026, 12, 20)), [.localhost])
        XCTAssertEqual(boss.openTiers(usageDays: 6, now: kst(2026, 12, 20)), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(usageDays: 17, now: kst(2026, 12, 20)), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(usageDays: 18, now: kst(2026, 12, 20)), BadgeTier.allCases)
        XCTAssertEqual(boss.lock(tier: .production, usageDays: 17, now: kst(2026, 12, 20)), .usage(have: 17, need: 18))
        XCTAssertNil(boss.lock(tier: .localhost, usageDays: 0, now: kst(2026, 11, 16)))
        // 둘 다 모자라면 날짜를 먼저 알린다.
        XCTAssertEqual(boss.lock(tier: .production, usageDays: 2, now: kst(2026, 11, 20)), .date(month: 12, day: 7))
        // 오픈일 경계는 KST 0시.
        let midnight = Calendar.kst.date(from: DateComponents(year: 2026, month: 11, day: 23))!
        XCTAssertNotNil(boss.lock(tier: .dev, usageDays: 6, now: midnight.addingTimeInterval(-1)))
        XCTAssertNil(boss.lock(tier: .dev, usageDays: 6, now: midnight))
    }

    /// 오픈일은 낮은 tier부터 순서대로이고 전부 보스 기간 안이다. 매일 쓰면 오픈일에 일수 조건도 이미 차 있다.
    func testTierOpenDatesAreOrderedInsideWindowAndReachableByDailyUse() {
        var prev: Date?
        for tier in BadgeTier.allCases {
            let open = boss.openDate(tier: tier, now: kst(2026, 11, 20))!
            XCTAssertTrue(boss.window.contains(open), "\(tier) 오픈일이 보스 기간 밖")
            if let prev { XCTAssertGreaterThan(open, prev) }
            prev = open
            let daily = usage(from: kst(2026, 11, 16), days: 60)
            let days = boss.usageDayCount(dailyVP: daily, now: open)
            XCTAssertNil(boss.lock(tier: tier, usageDays: days, now: open), "\(tier): 매일 써도 오픈일에 안 열림")
        }
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
