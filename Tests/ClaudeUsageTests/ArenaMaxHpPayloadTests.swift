import XCTest
@testable import ClaudeUsage

// #175 회귀 가드 — PvP 응답/저장로그의 HP 실링(maxHpA/maxHpB) payload 하위호환.
// 이 PR의 존재 이유가 "엔진 버전 스큐 시 안전 폴백"이므로, (a) 구서버/구로그(키 없음)가 nil로
// 디코딩되고 (b) serverMaxHpDict가 nil/길이불일치 시 nil을 반환해 로컬 finalStats 폴백으로
// 떨어지는지 잠근다. (CodexDecodingTests의 필드 드리프트 회귀 가드와 동일 방식.)
@MainActor   // ArenaView(@MainActor)의 static serverMaxHpDict를 동기 호출하기 위함.
final class ArenaMaxHpPayloadTests: XCTestCase {

    // ChallengeResponse: maxHpA/maxHpB 키가 없는 구서버 응답 → 두 필드 nil, 나머지 정상 디코딩.
    func testChallengeResponseOldShapeDecodesMaxHpAsNil() throws {
        let json = """
        {"winner":"me","ratingDelta":12,"newRating":1012,"coinReward":30,"opponentNickname":"T",
         "myTeam":[],"oppTeam":[],"log":[],"rounds":0,"dailyUsed":1,"dailyLimit":10}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(RankingAPI.ChallengeResponse.self, from: json)
        XCTAssertNil(resp.maxHpA, "구서버 응답엔 maxHpA 없음 → nil")
        XCTAssertNil(resp.maxHpB)
        XCTAssertEqual(resp.winner, "me")   // 나머지 필드는 정상
        XCTAssertEqual(resp.newRating, 1012)
    }

    // ChallengeResponse: 신서버 응답 → maxHpA/maxHpB 채워짐(팀 순서).
    func testChallengeResponseNewShapeDecodesMaxHp() throws {
        let json = """
        {"winner":"opp","ratingDelta":-8,"newRating":992,"coinReward":5,"opponentNickname":"T",
         "myTeam":[],"oppTeam":[],"maxHpA":[120,130,140],"maxHpB":[110,115],
         "log":[],"rounds":3,"dailyUsed":2,"dailyLimit":10}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(RankingAPI.ChallengeResponse.self, from: json)
        XCTAssertEqual(resp.maxHpA, [120, 130, 140])
        XCTAssertEqual(resp.maxHpB, [110, 115])
    }

    // PvpMatch: 구 저장로그(키 없음) → nil, 신규 → 채워짐.
    func testPvpMatchMaxHpBackwardCompat() throws {
        let old = """
        {"id":"x","createdAt":"2026-01-01T00:00:00Z","iAmChallenger":true,"opponentNickname":"T",
         "result":"me","ratingDelta":5,"teamA":[],"teamB":[],"events":[]}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(RankingAPI.PvpMatch.self, from: old)
        XCTAssertNil(m.maxHpA); XCTAssertNil(m.maxHpB)

        let new = """
        {"id":"y","createdAt":"2026-01-02T00:00:00Z","iAmChallenger":false,"opponentNickname":"T",
         "result":"opp","ratingDelta":-3,"teamA":[],"teamB":[],"events":[],"maxHpA":[200],"maxHpB":[190]}
        """.data(using: .utf8)!
        let m2 = try JSONDecoder().decode(RankingAPI.PvpMatch.self, from: new)
        XCTAssertEqual(m2.maxHpA, [200]); XCTAssertEqual(m2.maxHpB, [190])
    }

    // serverMaxHpDict: nil 배열/길이 불일치 → nil(로컬 폴백), 일치 → kind→maxHP 매핑.
    func testServerMaxHpDictFallbackAndMapping() {
        let snaps = [BattlePetSnapshot(kind: .fox), BattlePetSnapshot(kind: .wolf)]
        XCTAssertNil(ArenaView.serverMaxHpDict(snaps, nil), "배열 없으면 nil → 로컬 폴백")
        XCTAssertNil(ArenaView.serverMaxHpDict(snaps, [120]), "길이 불일치면 nil → 로컬 폴백")
        XCTAssertEqual(ArenaView.serverMaxHpDict(snaps, [120, 130]), [.fox: 120, .wolf: 130])
    }
}
