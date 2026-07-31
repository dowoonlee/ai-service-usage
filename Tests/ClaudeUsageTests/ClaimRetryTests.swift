import XCTest
@testable import ClaudeUsage

// claim 응답 유실 복구(#191) — 에러 분류와 디스크립터 직렬화 검증.
final class ClaimRetryTests: XCTestCase {

    // 4xx(no_pending_reward 등)는 서버의 확정 거절 — 재시도해도 결과가 같으므로 폐기.
    func testDefinitive4xxDrops() {
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.http(404, "no_pending_reward")), .drop)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.http(400, "invalid_period")), .drop)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.banned), .drop)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.notRegistered), .drop)
    }

    // 전송 실패는 서버 도달 여부 불명 — 오프라인 중 복구 기회를 지키기 위해 무기한 유지.
    func testNetworkKeeps() {
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.network("offline")), .keep)
    }

    // 응답 수신형 실패(5xx·rate limit·디코딩)는 일시적일 수 있음 — 캡까지 재시도.
    func testTransientBumps() {
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.http(500, "claim_failed")), .bump)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.http(503, nil)), .bump)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.rateLimited(retryAfterSec: 60)), .bump)
        XCTAssertEqual(ViewModel.claimRetryAction(for: RankingAPI.RankingError.decoding("bad json")), .bump)
    }

    // UserDefaults 영속을 위한 Codable 왕복 — attempts 포함 전 필드 보존.
    func testDescriptorCodableRoundtrip() throws {
        var d = RankingAPI.PendingClaimRetry(
            rewardType: "rp", period: "2026-W30", rank: 5,
            periodType: "weekly", currency: "rp", amount: 60,
            dedupKey: "weekly.2026-W30.5")
        d.attempts = 3
        let decoded = try JSONDecoder().decode(
            RankingAPI.PendingClaimRetry.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(decoded, d)

        // grant 트랙 — periodType nil 왕복.
        let g = RankingAPI.PendingClaimRetry(
            rewardType: "grant", period: "quiz-2026-07-31", rank: 1,
            periodType: nil, currency: "coin", amount: 1000,
            dedupKey: "quiz-2026-07-31")
        let gDecoded = try JSONDecoder().decode(
            RankingAPI.PendingClaimRetry.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(gDecoded, g)
    }

    // race에서 진 duplicate claim 응답(!won 분기)에는 claimedAt이 없다 — optional 디코딩 확인.
    // non-optional이면 여기서 throw돼 불필요한 재시도를 유발한다.
    func testClaimResponseWithoutClaimedAtDecodes() throws {
        let json = #"{"alreadyClaimed":true,"rewardType":"rp","rp":60}"#
        let resp = try JSONDecoder().decode(
            RankingAPI.ClaimRewardResponse.self, from: Data(json.utf8))
        XCTAssertTrue(resp.alreadyClaimed)
        XCTAssertEqual(resp.rp, 60)
        XCTAssertNil(resp.claimedAt)
    }
}
