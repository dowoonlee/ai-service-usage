import XCTest
@testable import ClaudeUsage

/// 3v3 결정적 배틀 시뮬 검증 (P0).
final class BattleEngineTests: XCTestCase {

    private func team(_ kinds: [PetKind], enh: Int = 0, pu: Double = 0) -> BattleTeam {
        BattleTeam(kinds.map { BattlePetSnapshot(kind: $0, variant: 0, enhanceLevel: enh, progressUnits: pu) })
    }

    private let weak: [PetKind] = [.fox, .wolf, .bear]           // common
    private let strong: [PetKind] = [.warrior, .archer, .monk]   // mythic (onCall)

    // 같은 두 팀 + 같은 시드 → 완전히 동일한 결과(승자·라운드·로그).
    func testDeterministic() {
        let a = team(weak), b = team(strong)
        let r1 = BattleEngine.simulate(teamA: a, teamB: b, seed: 12345)
        let r2 = BattleEngine.simulate(teamA: a, teamB: b, seed: 12345)
        XCTAssertEqual(r1, r2)
        XCTAssertFalse(r1.log.isEmpty)
    }

    // 다른 시드 → 결과 분포가 갈린다(거울 팀은 선공/데미지 rng로 승자가 양쪽 모두 등장).
    func testMirrorTeamsVaryBySeed() {
        let a = team([.fox, .wolf, .bear])
        let b = team([.fox, .wolf, .bear])
        var winners = Set<BattleSide?>()
        for seed in 0..<300 {
            winners.insert(BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64(seed)).winner)
        }
        XCTAssertTrue(winners.contains(.a), "거울 매치에서 A가 이기는 시드가 있어야")
        XCTAssertTrue(winners.contains(.b), "거울 매치에서 B가 이기는 시드가 있어야")
    }

    // 강한 팀이 약한 팀을 압도(승률 매우 높음).
    func testStrongerBeatsWeaker() {
        let a = team(strong, enh: 15, pu: 8)
        let b = team(weak, enh: 0)
        var aWins = 0
        let n = 200
        for seed in 0..<n {
            if BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64(seed)).winner == .a { aWins += 1 }
        }
        XCTAssertGreaterThan(Double(aWins) / Double(n), 0.95)
    }

    // 결정적 매치는 max round 이전에 전멸로 끝난다(교착 없음).
    func testDecisiveMatchEndsByElimination() {
        let a = team(strong, enh: 15, pu: 8)
        let b = team(weak, enh: 0)
        for seed in 0..<50 {
            let r = BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64(seed))
            XCTAssertLessThan(r.rounds, BattleEngine.maxRounds, "압도적 매치는 타임아웃 전 종결")
            XCTAssertEqual(r.winner, .a)
        }
    }

    // 어떤 팀 조합·시드에서도 항상 maxRounds 이내에 종료(무한 루프 없음).
    func testAlwaysTerminates() {
        let combos: [([PetKind], [PetKind])] = [
            (weak, strong), (strong, weak), (weak, weak), (strong, strong),
            ([.fox], [.warrior]), ([.scrapBot, .fox], [.wolf, .bear, .warrior])
        ]
        for (ka, kb) in combos {
            for seed in 0..<40 {
                let r = BattleEngine.simulate(teamA: team(ka), teamB: team(kb), seed: UInt64(seed))
                XCTAssertLessThanOrEqual(r.rounds, BattleEngine.maxRounds)
            }
        }
    }

    // 로그 이벤트의 데미지는 항상 ≥ 1, 상성 배수는 유효 3값 중 하나.
    func testLogInvariants() {
        let r = BattleEngine.simulate(teamA: team(weak), teamB: team(strong), seed: 777)
        for e in r.log {
            XCTAssertGreaterThanOrEqual(e.damage, 1)
            XCTAssertTrue([0.625, 1.0, 1.6].contains(e.effectiveness))
        }
    }
}
