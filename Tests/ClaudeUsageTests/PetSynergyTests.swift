import XCTest
@testable import ClaudeUsage

/// 펫간 상성 3층 검증 (P0.5): 팀 시너지 / 밈 라이벌 / 컬렉션 상성망.
final class PetSynergyTests: XCTestCase {

    private func snap(_ k: PetKind) -> BattlePetSnapshot { BattlePetSnapshot(kind: k) }

    // ── A. 팀 시너지 ──

    // 모노 컬렉션 팀(전원 mainframe=beast): 컬렉션 3(전 스탯 ×1.10) + 타입 3(속도 +0.05).
    // → 속도 ×1.15, 나머지 ×1.10 (방향성).
    func testMonoCollectionTeamSynergy() {
        let b = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.bear)])
        XCTAssertEqual(b.collectionMult, 1.10, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)   // beast 대표 스탯
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.15, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .hp), 1.10, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .atk), 1.10, accuracy: 1e-9)
    }

    // 같은 타입(beast) 다른 컬렉션 3: 컬렉션 없음(×1.0) + 타입 3(속도 +0.05).
    func testSameTypeDifferentCollection() {
        let team = [snap(.fox), snap(.bat), snap(.tRex)]    // mainframe / dns / deprecated — 전부 beast
        XCTAssertEqual(team.map { $0.kind.battleType }, [.beast, .beast, .beast])
        let b = TeamSynergy.bonus(for: team)
        XCTAssertEqual(b.collectionMult, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.05, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .atk), 1.0, accuracy: 1e-9)
    }

    // 전원 다른 컬렉션·타입: 시너지 없음.
    func testNoSynergy() {
        let b = TeamSynergy.bonus(for: [snap(.fox), snap(.warrior), snap(.scrapBot)])
        XCTAssertEqual(b, .none)
        for s in [StatKind.hp, .atk, .def, .spd] {
            XCTAssertEqual(TeamSynergy.statMultiplier(b, s), 1.0, accuracy: 1e-9)
        }
    }

    // 2마리 동족(mainframe/beast): 컬렉션 2(전 스탯 ×1.05) + 타입 2(속도 +0.03).
    func testPairCollectionSynergy() {
        let b = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.scrapBot)])  // mainframe×2 + ciRunners
        XCTAssertEqual(b.collectionMult, 1.05, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.08, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .def), 1.05, accuracy: 1e-9)
    }

    // 타입별 대표 스탯 매핑 — 아키타입 성향.
    func testSignatureStats() {
        XCTAssertEqual(TeamSynergy.signatureStat(of: .beast), .spd)
        XCTAssertEqual(TeamSynergy.signatureStat(of: .warrior), .atk)
        XCTAssertEqual(TeamSynergy.signatureStat(of: .machine), .def)
        XCTAssertEqual(TeamSynergy.signatureStat(of: .mascot), .hp)
    }

    // ── B. 밈 라이벌 ──

    func testMemeRivalBonusAndQuip() {
        let m = PetSynergy.matchup(.noVerify, vs: .ciRunners)
        XCTAssertEqual(m.mult, PetSynergy.memeMultiplier, accuracy: 1e-9)
        XCTAssertNotNil(m.quip, "밈 라이벌은 배틀로그 대사가 있어야")
    }

    func testMemeRivalReverseWeakens() {
        let m = PetSynergy.matchup(.ciRunners, vs: .noVerify)   // 역방향 — 라이벌에게 공격
        XCTAssertEqual(m.mult, 1.0 / PetSynergy.memeMultiplier, accuracy: 1e-9)
        XCTAssertNil(m.quip)
    }

    // ── C. 컬렉션 상성망 ──

    func testNetworkEdge() {
        let strong = PetSynergy.matchup(.mainframe, vs: .deprecated)
        XCTAssertEqual(strong.mult, PetSynergy.networkMultiplier, accuracy: 1e-9)
        XCTAssertNil(strong.quip)
        let weak = PetSynergy.matchup(.deprecated, vs: .mainframe)
        XCTAssertEqual(weak.mult, 1.0 / PetSynergy.networkMultiplier, accuracy: 1e-9)
    }

    func testNeutralMatchup() {
        // mainframe vs emotionalSupport — 어느 방향으로도 밈/상성망 엣지가 없어 중립.
        // (주의: mainframe vs dns는 중립 아님 — dns▶mainframe 밈이라 역방향 약화됨)
        XCTAssertEqual(PetSynergy.matchup(.mainframe, vs: .emotionalSupport).mult, 1.0, accuracy: 1e-9)
        XCTAssertEqual(PetSynergy.matchup(.emotionalSupport, vs: .mainframe).mult, 1.0, accuracy: 1e-9)
        // dns▶mainframe 밈의 역방향은 약화되어야(중립 아님).
        XCTAssertLessThan(PetSynergy.matchup(.mainframe, vs: .dns).mult, 1.0)
    }

    // ── 무결성: 밈/상성망에 상호 모순(a▶d 이면서 d▶a) 없음 ──

    func testNoContradictoryEdges() {
        // 모든 밈 라이벌 (a→d)에 대해 역방향 밈(d→a)이 없어야.
        for (a, dict) in PetSynergy.memeRivals {
            for d in dict.keys {
                XCTAssertNil(PetSynergy.memeRivals[d]?[a], "밈 모순: \(a)↔\(d)")
            }
        }
        // 상성망도 상호 모순 없어야, 밈과도 충돌 없어야(순방향 배수가 항상 > 1이 되게).
        for (a, set) in PetSynergy.networkStrong {
            for d in set {
                XCTAssertFalse(PetSynergy.networkStrong[d]?.contains(a) == true, "상성망 모순: \(a)↔\(d)")
                XCTAssertNil(PetSynergy.memeRivals[d]?[a], "상성망 vs 밈 충돌: \(d)▶\(a)")
                // 순방향 배수는 반드시 우위(>1).
                XCTAssertGreaterThan(PetSynergy.matchup(a, vs: d).mult, 1.0)
            }
        }
    }

    // ── 통합: 팀 시너지가 실제 스탯을 올려 승률에 반영된다 ──

    func testTeamSynergyAffectsBattle() {
        // 1마리 = 시너지 없음.
        XCTAssertEqual(TeamSynergy.bonus(for: [snap(.fox)]), .none)
        // 모노 mainframe(beast): 전 스탯 ×1.10, 속도 ×1.15.
        let syn = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.bear)])
        XCTAssertGreaterThan(syn.collectionMult, 1.0)
        XCTAssertEqual(syn.typeStat, .spd)
        // finalStats가 방향성 시너지를 반영: 모노 팀 fox의 속도가 시너지 없는 fox보다 높다.
        let mono = BattleTeam([snap(.fox), snap(.wolf), snap(.bear)])
        let alone = BattleTeam([snap(.fox), snap(.warrior), snap(.scrapBot)])  // fox엔 시너지 없음
        let sMono = BattleEngine.finalStats(for: snap(.fox), in: mono)
        let sAlone = BattleEngine.finalStats(for: snap(.fox), in: alone)
        XCTAssertGreaterThan(sMono.spd, sAlone.spd, "모노 beast 팀은 속도 시너지로 SPD가 더 높아야")
        XCTAssertGreaterThan(sMono.hp, sAlone.hp, "동족 컬렉션 시너지로 HP도 소폭 더 높아야")
    }
}
