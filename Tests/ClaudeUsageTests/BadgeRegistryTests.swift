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

    // 카테고리마다 **서로 다른** sprite를 써야 한다. 예전엔 클라우드 제도 8종이 본토 보석을
    // 재활용해서(arenaWins·heartbeat 둘 다 Ruby) 트레이너 카드에 같은 보석이 나란히 떴다.
    // 카테고리를 새로 추가할 때 기존 파일을 재사용하면 여기서 걸린다.
    func testJewelSpritesAreUniquePerCategory() {
        let names = BadgeCategory.allCases.map(\.jewelSpriteName)
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        XCTAssertTrue(dupes.isEmpty, "여러 카테고리가 같은 sprite를 씀: \(Array(dupes).sorted())")
        XCTAssertEqual(Set(names).count, BadgeCategory.allCases.count)
    }

    // 매핑된 sprite가 실제로 번들에 있어야 한다 — 없으면 조용히 폴백(색 박스)으로 떨어진다.
    @MainActor
    func testJewelSpritesExistInBundle() {
        for cat in BadgeCategory.allCases {
            XCTAssertNotNil(NSImage.gymJewel(named: cat.jewelSpriteName),
                            "\(cat.rawValue) → \(cat.jewelSpriteName).png 누락")
        }
    }
}
