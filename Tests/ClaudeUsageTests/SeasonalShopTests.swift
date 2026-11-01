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
