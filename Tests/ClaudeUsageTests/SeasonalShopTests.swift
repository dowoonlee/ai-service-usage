import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 2번 — 한정 코스메틱. 노출은 시즌·보유로만, 가격·case는 상시와 같은 규칙.
@MainActor
final class SeasonalShopTests: SandboxedTestCase {

    func testEverySeasonalItemPointsAtAnExistingSeasonKind() {
        let acc = CardAccessory.allCases.compactMap(\.season)
        let eff = EffectKind.allCases.compactMap(\.season)
        let thm = PetTheme.allCases.compactMap(\.season)
        let ttl = CardTitle.allCases.compactMap(\.season)
        XCTAssertFalse(acc.isEmpty); XCTAssertFalse(eff.isEmpty); XCTAssertFalse(thm.isEmpty); XCTAssertFalse(ttl.isEmpty)
        for k in acc + eff + thm + ttl {
            XCTAssertNotNil(SeasonRegistry.season(k), "\(k) 시즌이 레지스트리에 없음")
        }
    }

    func testAccessoryRawValuesAreUniqueAndMufflerAvoidsScarf() {
        let raws = CardAccessory.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raws).count, raws.count)
        XCTAssertEqual(CardAccessory.tshirt.rawValue, "scarf")       // v0.7.0 호환 — 바꾸면 저장값 깨짐
        XCTAssertNotEqual(CardAccessory.muffler.rawValue, "scarf")
        XCTAssertEqual(CardAccessory.allCases.count, 11)
    }

    func testShopVisibleHidesSeasonalOutsideSeasonUnlessOwned() {
        let s = Settings.shared
        SeasonRegistry.override = Override.none
        XCTAssertTrue(s.shopVisible(CardAccessory.glasses, owned: false))       // 상시
        XCTAssertFalse(s.shopVisible(CardAccessory.santaHat, owned: false))
        XCTAssertTrue(s.shopVisible(CardAccessory.santaHat, owned: true))       // 보유하면 시즌 밖에도
        XCTAssertFalse(s.shopVisible(EffectKind.snowfall, owned: false))
        XCTAssertFalse(s.shopVisible(PetTheme.winterNight, owned: false))
        XCTAssertFalse(s.shopVisible(CardTitle.freezeViolator, owned: false))

        SeasonRegistry.override = .season(.xmas)
        XCTAssertTrue(s.shopVisible(CardAccessory.santaHat, owned: false))
        XCTAssertTrue(s.shopVisible(EffectKind.snowfall, owned: false))
        XCTAssertTrue(s.shopVisible(PetTheme.winterNight, owned: false))

        SeasonRegistry.override = .season(.newYear)                           // 다른 시즌엔 숨김
        XCTAssertFalse(s.shopVisible(CardAccessory.santaHat, owned: false))
    }

    /// 오피스 데코도 같은 판정을 탄다. 서버엔 kind 문자열로 남으므로, 시즌이 끝나도 카탈로그 조회는 살아 있어야
    /// 이미 놓인 트리가 그려진다.
    func testSeasonalDecorHidesFromShopOutsideSeasonButStaysResolvable() throws {
        let s = Settings.shared
        let tree = try XCTUnwrap(OfficeLayout.decorItem(kind: "CHRISTMAS_TREE"))
        XCTAssertEqual(tree.season, .xmas)
        XCTAssertEqual(tree.category, .floor)
        XCTAssertNotNil(OfficeLayout.officeImage(tree.imageName), "CHRISTMAS_TREE.png이 번들에 없음")
        for item in OfficeLayout.decorCatalog {
            if let k = item.season { XCTAssertNotNil(SeasonRegistry.season(k), "\(item.kind) 시즌이 레지스트리에 없음") }
        }

        SeasonRegistry.override = Override.none
        XCTAssertFalse(s.shopVisible(tree, owned: false))
        XCTAssertNotNil(OfficeLayout.decorItem(kind: tree.kind))                // 배치분 렌더 경로
        SeasonRegistry.override = .season(.xmas)
        XCTAssertTrue(s.shopVisible(tree, owned: false))
        SeasonRegistry.override = .season(.newYear)
        XCTAssertFalse(s.shopVisible(tree, owned: false))
    }

    func testTrainerBackgroundHidesSeasonalThemeOutsideSeason() {
        let s = Settings.shared
        SeasonRegistry.override = Override.none
        XCTAssertFalse(TrainerBackground.unlocked(in: s).contains(.theme(.winterNight)))
        s.ownedThemes.insert(PetTheme.winterNight.rawValue)
        XCTAssertTrue(TrainerBackground.unlocked(in: s).contains(.theme(.winterNight)))
    }

    func testSeasonalPricesMatchRegularTiers() {
        XCTAssertEqual(CardAccessory.santaHat.price, CardAccessory.strawHat.price)
        XCTAssertEqual(CardAccessory.muffler.price, CardAccessory.gift.price)
        XCTAssertEqual(EffectKind.snowfall.price, EffectKind.petal.price)
        XCTAssertEqual(EffectKind.snowfall.category, .particle)
        XCTAssertEqual(PetTheme.winterNight.price, PetTheme.aurora.price)
        XCTAssertTrue(PetTheme.winterNight.isDynamic)
        XCTAssertEqual(CardTitle.freezeViolator.purchasePrice, 1500)
        XCTAssertNil(CardTitle.codedOnChristmas.purchasePrice)
    }

    func testWinterNightStopsStayMonotonicAcrossUsage() {
        for pct in [0.0, 20, 50, 80, 100] {
            let stops = PetTheme.winterNight.fillStops(pct: pct, threshold: 0.3)
            XCTAssertGreaterThanOrEqual(stops.count, 2, "pct=\(pct)")
            var prev = -1.0
            for st in stops {
                XCTAssertGreaterThanOrEqual(st.location, prev, "pct=\(pct)")
                prev = st.location
            }
        }
        XCTAssertEqual(PetTheme.winterNight.motif, .bulb)
    }

    func testCodedOnChristmasFlagAndTitle() {
        let s = Settings.shared
        func ev(_ key: String) -> UsageEvent {
            let d = SajuEngine.kstDayFormatter.date(from: key)!.addingTimeInterval(12 * 3600)
            return UsageEvent(timestamp: d, source: .claudeFiveHour,
                              context: UsageContext(planName: nil, coinFactor: 1, vpFactor: 1), pureValue: 1)
        }
        SeasonFlagLedger.shared.consume(ev("2026-12-24"))
        XCTAssertTrue(s.seasonalFlags.isEmpty)
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.codedOnChristmas))
        SeasonFlagLedger.shared.consume(ev("2026-12-25"))
        XCTAssertEqual(s.seasonalFlags, ["codedOn:2026-12-25"])
        XCTAssertTrue(CardTitle.unlocked(in: s).contains(.codedOnChristmas))
        // 시즌 밖에서도 해금된 칭호는 목록에 남는다(보유 = 노출).
        SeasonRegistry.override = Override.none
        XCTAssertTrue(s.shopVisible(CardTitle.codedOnChristmas, owned: true))
    }

    func testSeasonalAccessorySpriteExistsForSantaHat() {
        XCTAssertNotNil(PetSprite.image(named: CardAccessory.santaHat.resourceName))
    }
}

/// 3번 — 잔디 보상 마크·완주 칭호·알림 문구. 서버 grant_key 규칙(`advent-<y>-12-<DD>`)과의 합의가 깨지면 여기서 잡힌다.
@MainActor
final class SeasonRewardTests: SandboxedTestCase {
    private func kst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.kst.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testRewardGrantPrefixMatchesServerRule() {
        let xmas = SeasonRegistry.season(.xmas)!
        XCTAssertEqual(xmas.rewardGrantPrefix(now: kst(2026, 12, 5)), "advent-2026-12-")
        XCTAssertEqual(xmas.rewardCompleteKey(now: kst(2026, 12, 5)), "advent-2026-complete")
        XCTAssertNil(SeasonRegistry.season(.newYear)!.rewardGrantPrefix(now: kst(2026, 12, 28)))
    }

    func testRewardMarksReceivedPendingNoneFuture() {
        let xmas = SeasonRegistry.season(.xmas)!
        let marks = UsageGrassModel.rewardMarks(
            season: xmas,
            dailyVP: ["2026-12-01": 100, "2026-12-02": 50, "2026-12-04": 10, "2026-12-20": 999],
            claimedGrants: ["advent-2026-12-01", "quiz-2026-12-02"],
            now: kst(2026, 12, 4))
        XCTAssertEqual(marks["2026-12-01"], .received)
        XCTAssertEqual(marks["2026-12-02"], .pending)      // 썼지만 grant 아직
        XCTAssertNil(marks["2026-12-03"])                  // 안 쓴 날
        XCTAssertEqual(marks["2026-12-04"], .pending)      // 오늘
        XCTAssertNil(marks["2026-12-20"])                  // 미래는 값이 있어도 없음
    }

    func testRewardMarksEmptyOutsideRewardMonthOrSeason() {
        let ny = SeasonRegistry.season(.newYear)!
        XCTAssertTrue(UsageGrassModel.rewardMarks(season: ny, dailyVP: ["2026-12-28": 1],
                                                  claimedGrants: [], now: kst(2026, 12, 28)).isEmpty)
        XCTAssertTrue(UsageGrassModel.rewardMarks(season: nil, dailyVP: ["2026-12-05": 1],
                                                  claimedGrants: [], now: kst(2026, 12, 5)).isEmpty)
    }

    func testDecemberFinisherNeedsTwentyDailyGrantsInOneYear() {
        let s = Settings.shared
        var grants: Set<String> = []
        for d in 1...19 { grants.insert(String(format: "advent-2026-12-%02d", d)) }
        grants.insert("advent-2026-complete")          // 완주 행은 일일 행이 아니다
        grants.insert("advent-2025-12-24")             // 다른 해 1개 — 합산하지 않는다
        s.claimedGrants = grants
        XCTAssertFalse(CardTitle.hasDecemberFinish(claimedGrants: s.claimedGrants))
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.decemberFinisher))
        s.claimedGrants.insert("advent-2026-12-20")
        XCTAssertTrue(CardTitle.unlocked(in: s).contains(.decemberFinisher))
    }

    func testGrantNotificationCopy() {
        XCTAssertEqual(NotificationManager.grantCopy(currency: "coin", amount: 50, grantKey: "advent-2026-12-07").title,
                       "🎄 12월 7일 보상")
        XCTAssertEqual(NotificationManager.grantCopy(currency: "coin", amount: 500, grantKey: "advent-2026-complete").title,
                       "🎄 12월 완주")
        XCTAssertEqual(NotificationManager.grantCopy(currency: "coin", amount: 300, grantKey: "quiz-2026-12-07").title,
                       "🎁 보상 도착")
        XCTAssertEqual(NotificationManager.grantCopy(currency: "rp", amount: 10, grantKey: "pvp-season-3").title,
                       "🏆 아레나 시즌 보상")
    }
}
