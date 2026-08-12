import XCTest
@testable import ClaudeUsage

/// variant(이로치) 해금 평가 검증 (PetOwnership 순수 함수).
/// 진행도가 한 번에 여러 임계를 넘겼을 때 **전부** 해금되는지가 핵심 — 예전엔 첫 임계 하나만
/// 열고 반환해서, 백업 복원처럼 진행도가 크게 점프하는 경우 나머지가 다음 폴링·다음 뽑기까지
/// 밀렸고 variant 3을 요구하는 조각 적립도 함께 밀렸다.
final class PetVariantUnlockTests: XCTestCase {
    // 임계 순차 통과 — 한 단계씩 넘을 땐 그 단계만 열린다(기존 동작 보존).
    func testSequentialUnlockOpensOneAtATime() {
        var o = PetOwnership(count: 1, unlockedVariants: [0])
        // 1.0 유닛 = variant 1 (사용시간 단독으로 4일).
        XCTAssertEqual(o.registerUsage(totalSeconds: 4 * 86400), 1)
        XCTAssertEqual(o.unlockedVariants, [0, 1])
        // 같은 진행도 재평가 → 새 해금 없음.
        XCTAssertNil(o.registerUsage(totalSeconds: 4 * 86400))
    }

    // 진행도가 한 번에 세 임계(1.0/3.0/8.0)를 모두 넘으면 세 variant가 전부 열리고
    // 반환값은 그중 최고(3)다.
    func testBigJumpUnlocksAllCrossedThresholds() {
        var o = PetOwnership(count: 1, unlockedVariants: [0])
        // 40 중복 상당 = 8.0 유닛 → variant 1·2·3 동시 통과.
        let eightUnitsSec = 8.0 * 4 * 86400
        XCTAssertEqual(o.registerUsage(totalSeconds: eightUnitsSec), 3, "최고 variant를 반환")
        XCTAssertEqual(o.unlockedVariants, [0, 1, 2, 3], "통과한 임계를 전부 해금")
    }

    // 위 점프 직후 곧바로 오버플로우 조각이 적립된다 — variant 3 해금이 밀리면
    // claimOverflowShards가 0을 반환해 조각도 함께 밀렸다(회귀 가드).
    func testShardsAccrueImmediatelyAfterBigJump() {
        var o = PetOwnership(count: 1, unlockedVariants: [0])
        // 10 유닛 → variant 3까지 해금 + 오버플로우 2유닛.
        let tenUnitsSec = 10.0 * 4 * 86400
        _ = o.registerUsage(totalSeconds: tenUnitsSec)
        XCTAssertTrue(o.unlockedVariants.contains(3))
        XCTAssertEqual(o.claimOverflowShards(usageSeconds: tenUnitsSec),
                       2 * PetOwnership.shardsPerOverflowUnit)
    }

    // 가챠 중복 경로도 동일 — count 급증(10연차 등)이 여러 임계를 넘기면 전부 해금.
    func testPullPathUnlocksAllCrossedThresholds() {
        // count 14 → 2.8 유닛(variant 1만). 여기서 한 번 더 뽑아 3.0 유닛 도달.
        var o = PetOwnership(count: 14, unlockedVariants: [0])
        XCTAssertEqual(o.registerPull(usageSeconds: 0), 2, "1.0·3.0 임계를 함께 통과")
        XCTAssertEqual(o.unlockedVariants, [0, 1, 2])
    }

    // 이미 해금된 variant는 다시 반환하지 않는다(중복 하이라이트·로그 방지).
    func testAlreadyUnlockedVariantsAreNotReported() {
        var o = PetOwnership(count: 1, unlockedVariants: [0, 1, 2])
        XCTAssertNil(o.registerUsage(totalSeconds: 3.0 * 4 * 86400), "새로 열린 것 없음")
        XCTAssertEqual(o.registerUsage(totalSeconds: 8.0 * 4 * 86400), 3, "남은 임계만 보고")
    }
}
