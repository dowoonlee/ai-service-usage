import XCTest
@testable import ClaudeUsage

/// 4번 — 겨울 관장. tier 오픈(보상 일수), 보상 1회 dedup, 칭호, 팀 구성, 스킨 렌더.
@MainActor
final class SeasonalBossTests: SandboxedTestCase {
    private var xmas: Season { SeasonRegistry.season(.xmas)! }
    private var boss: SeasonalBoss { xmas.boss! }
    private func kst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.kst.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testOpenTiersByRewardDays() {
        XCTAssertEqual(boss.openTiers(rewardDays: 0), [.localhost])
        XCTAssertEqual(boss.openTiers(rewardDays: 5), [.localhost])
        XCTAssertEqual(boss.openTiers(rewardDays: 6), [.localhost, .dev])
        XCTAssertEqual(boss.openTiers(rewardDays: 12), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(rewardDays: 17), [.localhost, .dev, .staging])
        XCTAssertEqual(boss.openTiers(rewardDays: 18), BadgeTier.allCases)
    }

    func testStageMapping() {
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 0, productionCleared: false), 0)
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 1, productionCleared: false), 1)
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 5, productionCleared: false), 1)
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 6, productionCleared: false), 2)
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 24, productionCleared: false), 2)   // 마지막 줄은 격파 뒤에만
        XCTAssertEqual(SeasonalBoss.stage(rewardDays: 0, productionCleared: true), 3)
    }

    func testRewardDayCountCountsOnlyDailyRowsOfThisSeasonYear() {
        let grants: Set<String> = ["advent-2026-12-01", "advent-2026-12-02", "advent-2026-complete",
                                   "advent-2025-12-24", "quiz-2026-12-01"]
        XCTAssertEqual(SeasonalBoss.rewardDayCount(season: xmas, claimedGrants: grants, now: kst(2026, 12, 10)), 2)
        XCTAssertEqual(SeasonalBoss.rewardDayCount(season: SeasonRegistry.season(.newYear)!,
                                                   claimedGrants: grants, now: kst(2026, 12, 28)), 0)
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
