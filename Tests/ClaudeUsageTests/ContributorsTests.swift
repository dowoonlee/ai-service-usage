import XCTest
@testable import ClaudeUsage

final class ContributorsTests: XCTestCase {
    typealias PRTuple = (number: Int, title: String, mergedAt: String?, login: String?, avatar: String?)

    // owner login은 외부 기여자가 아니라 표시 대상에서 제외.
    func testOwnerExcluded() {
        let prs: [PRTuple] = [
            (1, "owner pr", "2026-01-01T00:00:00Z", "dowoonlee", nil),
            (2, "guest pr", "2026-01-02T00:00:00Z", "alice", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "dowoonlee")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.login, "alice")
    }

    // merged_at이 nil이면(닫혔지만 머지 안 됨) 무시.
    func testUnmergedExcluded() {
        let prs: [PRTuple] = [
            (1, "rejected", nil, "alice", nil),
            (2, "merged",   "2026-01-02T00:00:00Z", "alice", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.first?.prs.count, 1)
        XCTAssertEqual(result.first?.prs.first?.number, 2)
    }

    // login이 nil인 PR도 무시 (deleted user 등).
    func testNilLoginExcluded() {
        let prs: [PRTuple] = [
            (1, "ghost", "2026-01-01T00:00:00Z", nil, nil),
            (2, "ok",    "2026-01-02T00:00:00Z", "bob", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.login, "bob")
    }

    // 같은 login의 여러 PR이 한 entry로 묶이고, PR은 mergedAt 내림차순.
    func testGrouping() {
        let prs: [PRTuple] = [
            (1, "first",  "2026-01-01T00:00:00Z", "alice", "a.png"),
            (2, "second", "2026-02-01T00:00:00Z", "alice", "a.png"),
            (3, "third",  "2026-03-01T00:00:00Z", "alice", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.prs.count, 3)
        XCTAssertEqual(result.first?.prs.map(\.number), [3, 2, 1])
    }

    // 기여자 정렬: PR 개수 내림차순 (1차) → 동점이면 최근 머지 (2차).
    func testContributorOrderingByPRCount() {
        let prs: [PRTuple] = [
            // alice: 3 PR
            (1, "a1", "2026-01-01T00:00:00Z", "alice", nil),
            (2, "a2", "2026-01-02T00:00:00Z", "alice", nil),
            (3, "a3", "2026-01-03T00:00:00Z", "alice", nil),
            // bob: 1 PR (alice보다 최근이지만 개수 적음)
            (4, "b1", "2026-03-01T00:00:00Z", "bob", nil),
            // carol: 2 PR
            (5, "c1", "2026-02-01T00:00:00Z", "carol", nil),
            (6, "c2", "2026-02-15T00:00:00Z", "carol", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.map(\.login), ["alice", "carol", "bob"])
    }

    // 동점이면 최근 머지가 위.
    func testContributorOrderingTiebreakByRecent() {
        let prs: [PRTuple] = [
            (1, "old", "2026-01-01T00:00:00Z", "alice", nil),
            (2, "new", "2026-03-01T00:00:00Z", "bob",   nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.map(\.login), ["bob", "alice"])
    }

    // 순위 → rarity 매핑.
    func testRankingRarity() {
        XCTAssertEqual(ContributorRanking.rarity(forRank: 0), .legendary)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 1), .epic)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 2), .rare)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 3), .common)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 99), .common)
    }

    // stableHash는 process/플랫폼 무관하게 같은 입력에 같은 출력.
    func testStableHashDeterministic() {
        let h1 = ContributorRanking.stableHash("alice")
        let h2 = ContributorRanking.stableHash("alice")
        XCTAssertEqual(h1, h2)
        XCTAssertNotEqual(ContributorRanking.stableHash("alice"),
                          ContributorRanking.stableHash("bob"))
    }

    // 같은 login에서 첫 번째로 발견한 avatar URL 유지 (한 명이 avatar 바꿀 일 거의 없음).
    func testAvatarPreserved() {
        let prs: [PRTuple] = [
            (1, "with avatar", "2026-01-01T00:00:00Z", "alice", "https://x/a.png"),
            (2, "no avatar",   "2026-02-01T00:00:00Z", "alice", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.first?.avatarURL, "https://x/a.png")
    }

    // ISO8601 with fractional seconds도 파싱.
    func testFractionalSecondsParsed() {
        let prs: [PRTuple] = [
            (1, "frac", "2026-01-01T12:34:56.789Z", "alice", nil),
        ]
        let result = Contributors.aggregate(prs: prs, ownerLogin: "x")
        XCTAssertEqual(result.count, 1)
    }
}
