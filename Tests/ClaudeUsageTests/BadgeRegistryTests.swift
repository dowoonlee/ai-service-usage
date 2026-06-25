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

    // allBadges = 카테고리 × tier 전수. 매직넘버 대신 소스에서 파생해 카테고리 확장 시 안 깨지게 하고,
    // 동시에 중복/누락 없이 (category,tier) 한 쌍당 정확히 하나임을 키 유일성으로 검증한다.
    func testAllBadgesCount() {
        let expected = BadgeCategory.allCases.count * BadgeTier.allCases.count
        XCTAssertEqual(BadgeRegistry.allBadges.count, expected)
        XCTAssertEqual(Set(BadgeRegistry.allBadges.map(\.key)).count, expected,
                       "allBadges에 중복 키가 없어야 함")
    }

    // BadgeID.key 형식이 "category.tier"로 정확.
    func testBadgeIDKeyFormat() {
        let id = BadgeID(category: .standup, tier: .production)
        XCTAssertEqual(id.key, "standup.production")
    }

    // region들이 전체 카테고리를 빠짐·중복 없이 분할한다 (region마다 개수가 같진 않음 — 예: vibe는 3).
    func testRegionsPartitionAllCategories() {
        let fromRegions = BadgeRegion.allCases.flatMap(\.categories)
        XCTAssertEqual(fromRegions.count, BadgeCategory.allCases.count,
                       "region 카테고리 합이 전체와 같아야 함 (중복/누락 없음)")
        XCTAssertEqual(Set(fromRegions), Set(BadgeCategory.allCases),
                       "region 카테고리 합집합이 전체 카테고리와 일치해야 함")
        // 분할만으론 빈 region(다른 region이 몫을 흡수)을 못 잡는다 — GymView가 빈 카드를 렌더하므로
        // region마다 최소 1개 카테고리를 별도로 보장한다(과거 "정확히 2" 불변식의 핵심을 유지).
        for region in BadgeRegion.allCases {
            XCTAssertFalse(region.categories.isEmpty,
                           "\(region.rawValue) region은 비어있으면 안 됨")
        }
    }

    // Tier 비교 연산자 — Comparable 구현 단조.
    func testTierComparable() {
        XCTAssertLessThan(BadgeTier.localhost, BadgeTier.dev)
        XCTAssertLessThan(BadgeTier.dev,       BadgeTier.staging)
        XCTAssertLessThan(BadgeTier.staging,   BadgeTier.production)
    }
}
