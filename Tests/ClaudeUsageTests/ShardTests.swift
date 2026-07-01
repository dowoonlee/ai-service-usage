import XCTest
@testable import ClaudeUsage

/// 이로치 조각 오버플로우 적립 로직 검증 (PetOwnership 순수 함수).
final class ShardTests: XCTestCase {
    // 만렙(variant 3, 40중복=8유닛)에서 사용시간 오버플로우가 정수 유닛당 3조각으로 적립되고,
    // 같은 진행도로 재호출 시 중복 지급되지 않는다.
    func testOverflowShardAccrual() {
        var o = PetOwnership(count: 40, unlockedVariants: [0, 1, 2, 3])  // 정확히 8.0 유닛
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: 0), 0, "오버플로우 0이면 조각 0")

        // +2 유닛 오버플로우 (1유닛 = 4*86400초). 2 * 3 = 6조각.
        let twoUnitsSec = 2.0 * 4 * 86400
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: twoUnitsSec), 6)
        // 같은 진행도 재호출 → 중복 지급 없음.
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: twoUnitsSec), 0)
        // +1 유닛 더 → 3조각.
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: 3.0 * 4 * 86400), 3)
    }

    // variant 3 미해금 펫은 오버플로우 계산에서 제외(조각 0).
    func testNonMaxedPetEarnsNoShards() {
        var o = PetOwnership(count: 5, unlockedVariants: [0, 1])
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: 999_999_999), 0)
    }

    // 마이그레이션 시드는 현재 오버플로우를 '이미 지급됨'으로 표시해 과거분 소급을 막는다.
    func testSeedPreventsBackfill() {
        var o = PetOwnership(count: 50, unlockedVariants: [0, 1, 2, 3])  // 10유닛 → 오버플로우 2
        o.seedCreditedShardUnits(usageSeconds: 0)
        XCTAssertEqual(o.creditedShardUnits, 2)
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: 0), 0, "시드 이후 과거분 소급 없음")
    }

    // 구버전 저장 데이터(creditedShardUnits 키 없음)도 안전 디코딩되어 기본 0.
    func testLegacyDecodeDefaultsShardUnits() throws {
        let legacyJSON = #"{"count": 3, "unlockedVariants": [0, 1]}"#.data(using: .utf8)!
        let o = try JSONDecoder().decode(PetOwnership.self, from: legacyJSON)
        XCTAssertEqual(o.count, 3)
        XCTAssertEqual(o.creditedShardUnits, 0)
    }
}
