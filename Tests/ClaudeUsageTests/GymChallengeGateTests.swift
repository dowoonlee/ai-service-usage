import XCTest
@testable import ClaudeUsage

/// 관장 도전 게이트는 v0.17.23부터 **합산 진행률** 방식이다.
///
/// 예전엔 지역의 모든 카테고리가 각자 임계를 넘어야 했는데(allSatisfy), `vibe` 지역이
/// [claude, cursor, codex]라 세 도구를 다 쓰지 않으면 영영 열리지 않았다. 실제로 셋을 모두
/// 쓰는 사용자는 거의 없다 — 한 도구만 깊게 파는 경로도 성립해야 한다.
final class GymChallengeGateTests: XCTestCase {
    /// 개방 판정만 검증하는 순수 계산 — Settings 전역 상태에 의존하지 않도록 규칙을 재현한다.
    /// (BadgeRegistry.nextChallenge는 @MainActor Settings를 읽어 단위 테스트에서 격리가 어렵다.)
    private func progress(_ ratios: [Double]) -> Double {
        let capped = ratios.map { min(BadgeRegistry.challengeCategoryCap, $0) }
        return capped.reduce(0, +) / Double(ratios.count)
    }

    private func isOpen(_ ratios: [Double]) -> Bool {
        progress(ratios) >= BadgeRegistry.challengeProgressRatio
    }

    // 셋을 고루 쓰면 각자 임계의 60%씩으로 열린다 (전부 100% 채울 필요 없음).
    func testEvenUsageOpensAtSixtyPercent() {
        XCTAssertTrue(isOpen([0.6, 0.6, 0.6]))
        XCTAssertFalse(isOpen([0.59, 0.59, 0.59]))
    }

    // 핵심 회귀: 한 도구만 깊게 쓰는 사용자도 혼자서 열 수 있어야 한다.
    // 상한이 1.0이면 3개짜리 지역에서 최대 33%라 영영 못 넘는다 — 그래서 cap이 2.0이다.
    func testSingleToolDeepUseCanOpenAlone() {
        XCTAssertTrue(isOpen([1.8, 0, 0]), "임계의 1.8배면 혼자서도 개방")
        XCTAssertFalse(isOpen([1.0, 0, 0]), "만점 하나로는 부족 (33%)")
    }

    // 초과분은 상한까지만 인정 — 임계의 99배를 써도 2배와 같은 취급이다.
    func testOverflowIsCapped() {
        XCTAssertEqual(progress([99.0, 0, 0]), progress([2.0, 0, 0]), accuracy: 0.0001)
        XCTAssertEqual(progress([99.0, 99.0]), progress([2.0, 2.0]), accuracy: 0.0001)
    }

    // 카테고리가 많을수록 한 지표만으로는 열기 어려워진다(cap이 상대적으로 작아짐).
    func testCapLimitsSingleMetricInLargerRegions() {
        // 4개 지역: cap 2.0 하나만으론 2/4 = 50% < 60% → 못 연다.
        XCTAssertFalse(isOpen([99.0, 0, 0, 0]))
        // 두 지표가 상한이면 4/4 = 100% → 열린다.
        XCTAssertTrue(isOpen([99.0, 99.0, 0, 0]))
    }

    // 2개짜리 지역(대부분): 한쪽이 임계의 1.2배면 열린다.
    func testTwoCategoryRegion() {
        XCTAssertTrue(isOpen([1.2, 0]))
        XCTAssertFalse(isOpen([1.1, 0]))
        XCTAssertTrue(isOpen([0.6, 0.6]))
    }

    // 상수 계약 — 값을 바꾸면 난이도가 전 지역에서 동시에 움직인다는 걸 명시적으로 고정.
    func testGateConstants() {
        XCTAssertEqual(BadgeRegistry.challengeProgressRatio, 0.6)
        XCTAssertEqual(BadgeRegistry.challengeCategoryCap, 2.0)
        // cap이 ratio보다 크지 않으면 "한 지표 깊게" 경로가 아예 성립하지 않는다.
        XCTAssertGreaterThan(BadgeRegistry.challengeCategoryCap,
                             BadgeRegistry.challengeProgressRatio)
    }

    // vibe 지역이 여전히 3개 카테고리인지 — 이 구성이 바뀌면 위 계산 전제가 흔들린다.
    func testVibeRegionShape() {
        XCTAssertEqual(BadgeRegion.vibe.categories, [.claude, .cursor, .codex])
    }
}
