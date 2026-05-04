import XCTest
@testable import ClaudeUsage

final class BadgeRegistryTests: XCTestCase {
    // 임계값 단조성 — 모든 카테고리에서 t1 < t2 < t3 < t4.
    func testThresholdsAreMonotonic() {
        for cat in BadgeCategory.allCases {
            let t = cat.thresholds
            XCTAssertLessThan(t[.localhost]!, t[.dev]!,
                              "\(cat.rawValue): localhost < dev")
            XCTAssertLessThan(t[.dev]!,       t[.staging]!,
                              "\(cat.rawValue): dev < staging")
            XCTAssertLessThan(t[.staging]!,   t[.production]!,
                              "\(cat.rawValue): staging < production")
        }
    }

    // tier 코인 보상도 단조 증가 (production이 가장 큼).
    func testTierCoinRewardsMonotonic() {
        XCTAssertLessThan(BadgeTier.localhost.coinReward, BadgeTier.dev.coinReward)
        XCTAssertLessThan(BadgeTier.dev.coinReward,       BadgeTier.staging.coinReward)
        XCTAssertLessThan(BadgeTier.staging.coinReward,   BadgeTier.production.coinReward)
        XCTAssertLessThan(BadgeTier.production.coinReward, BadgeRegistry.championCoinReward)
    }

    // Region → 카테고리 매핑이 region.categories와 category.region이 정합한가.
    func testRegionCategoryRoundTrip() {
        for region in BadgeRegion.allCases {
            for cat in region.categories {
                XCTAssertEqual(cat.region, region,
                               "\(cat.rawValue) should belong to \(region.rawValue)")
            }
        }
    }

    // 8 카테고리 × 4 tier = 32. allBadges가 정확히 32개.
    func testAllBadgesCount() {
        XCTAssertEqual(BadgeRegistry.allBadges.count, 32)
    }

    // BadgeID.key 형식이 "category.tier"로 정확.
    func testBadgeIDKeyFormat() {
        let id = BadgeID(category: .standup, tier: .production)
        XCTAssertEqual(id.key, "standup.production")
    }

    // 4 region × 2 카테고리. region마다 정확히 2 카테고리.
    func testEachRegionHasTwoCategories() {
        for region in BadgeRegion.allCases {
            XCTAssertEqual(region.categories.count, 2,
                           "\(region.rawValue) should have 2 categories")
        }
    }

    // Tier 비교 연산자 — Comparable 구현 단조.
    func testTierComparable() {
        XCTAssertLessThan(BadgeTier.localhost, BadgeTier.dev)
        XCTAssertLessThan(BadgeTier.dev,       BadgeTier.staging)
        XCTAssertLessThan(BadgeTier.staging,   BadgeTier.production)
    }
}
