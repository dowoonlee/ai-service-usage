import XCTest
@testable import ClaudeUsage

/// 기여자 수집(오너 제외·미머지 제외·그룹핑)은 v0.17.21부터 서버(`contributors` Edge Function)가
/// 맡는다 — 클라가 GitHub을 직접 치던 경로가 IP rate limit과 `/pulls` 100개 창 문제로 깨졌기 때문.
/// 따라서 여기 남는 클라 책임은 **표시 순서**와 **응답 디코딩**뿐이다.
final class ContributorsTests: XCTestCase {
    private func pr(_ number: Int, _ iso: String) -> PullRequest {
        PullRequest(number: number, title: "pr\(number)",
                    mergedAt: Date.parseISO8601(iso) ?? .distantPast)
    }

    // 표시 순서: PR 개수 내림차순 (1차).
    func testOrderingByPRCount() {
        let list = [
            Contributor(login: "bob", avatarURL: nil, prs: [pr(4, "2026-03-01T00:00:00Z")]),
            Contributor(login: "alice", avatarURL: nil, prs: [
                pr(3, "2026-01-03T00:00:00Z"), pr(2, "2026-01-02T00:00:00Z"), pr(1, "2026-01-01T00:00:00Z"),
            ]),
            Contributor(login: "carol", avatarURL: nil, prs: [
                pr(6, "2026-02-15T00:00:00Z"), pr(5, "2026-02-01T00:00:00Z"),
            ]),
        ]
        XCTAssertEqual(Contributors.sorted(list).map(\.login), ["alice", "carol", "bob"])
    }

    // 동점이면 최근 머지가 위 (2차).
    func testOrderingTiebreakByRecent() {
        let list = [
            Contributor(login: "alice", avatarURL: nil, prs: [pr(1, "2026-01-01T00:00:00Z")]),
            Contributor(login: "bob", avatarURL: nil, prs: [pr(2, "2026-03-01T00:00:00Z")]),
        ]
        XCTAssertEqual(Contributors.sorted(list).map(\.login), ["bob", "alice"])
    }

    // PR이 없는 기여자가 섞여도 크래시 없이 맨 뒤로.
    func testEmptyPRsSortsLast() {
        let list = [
            Contributor(login: "ghost", avatarURL: nil, prs: []),
            Contributor(login: "alice", avatarURL: nil, prs: [pr(1, "2026-01-01T00:00:00Z")]),
        ]
        XCTAssertEqual(Contributors.sorted(list).map(\.login), ["alice", "ghost"])
    }

    // 순위 → rarity 매핑.
    func testRankingRarity() {
        XCTAssertEqual(ContributorRanking.rarity(forRank: 0), .legendary)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 1), .epic)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 2), .rare)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 3), .common)
        XCTAssertEqual(ContributorRanking.rarity(forRank: 99), .common)
    }

    // 서버 응답 디코딩 — 필드명(avatarURL/mergedAt)이 서버와 어긋나면 목록이 통째로 빈다.
    func testResponseDecoding() throws {
        let json = """
        {
          "contributors": [
            {"login": "alice", "avatarURL": "https://x/a.png",
             "prs": [{"number": 45, "title": "fix: facing", "mergedAt": "2026-06-24T01:02:03Z"}]},
            {"login": "bob", "avatarURL": null, "prs": []}
          ],
          "syncedAt": "2026-08-11T09:00:00Z"
        }
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = Date.parseISO8601(s) else {
                throw DecodingError.dataCorruptedError(in: try d.singleValueContainer(),
                                                       debugDescription: "bad date \(s)")
            }
            return date
        }
        let resp = try decoder.decode(RankingAPI.ContributorsResponse.self, from: json)
        XCTAssertEqual(resp.contributors.count, 2)
        XCTAssertEqual(resp.contributors[0].login, "alice")
        XCTAssertEqual(resp.contributors[0].avatarURL, "https://x/a.png")
        XCTAssertEqual(resp.contributors[0].prs.first?.number, 45)
        XCTAssertNil(resp.contributors[1].avatarURL)
        XCTAssertTrue(resp.contributors[1].prs.isEmpty)
        XCTAssertNotNil(resp.syncedAt)
    }
}
