import XCTest
@testable import ClaudeUsage

/// 펫간 상성 3층 검증 (P0.5): 팀 시너지 / 밈 라이벌 / 컬렉션 상성망.
final class PetSynergyTests: XCTestCase {

    private func snap(_ k: PetKind) -> BattlePetSnapshot { BattlePetSnapshot(kind: k) }

    // ── A. 팀 시너지 ──

    // 모노 컬렉션 팀(전원 mainframe=beast): 컬렉션 3(전 스탯 ×1.10) + 타입 3(속도 +0.06).
    // → 속도 ×1.16, 나머지 ×1.10 (방향성).
    func testMonoCollectionTeamSynergy() {
        let b = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.bear)])
        XCTAssertEqual(b.collectionMult, 1.10, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)   // beast 대표 스탯
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.16, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .hp), 1.10, accuracy: 1e-9)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .atk), 1.10, accuracy: 1e-9)
    }

    // 같은 타입(beast) 다른 컬렉션 3: 컬렉션 없음(×1.0) + 타입 3(속도 +0.06).
    func testSameTypeDifferentCollection() {
        let team = [snap(.fox), snap(.bat), snap(.tRex)]    // mainframe / dns / deprecated — 전부 beast
        XCTAssertEqual(team.map { $0.kind.battleType }, [.beast, .beast, .beast])
        let b = TeamSynergy.bonus(for: team)
        XCTAssertEqual(b.collectionMult, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.06, accuracy: 1e-9)
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
        // 모노 mainframe(beast): 전 스탯 ×1.10, 속도 ×1.16 (컬렉션3 0.10 + 타입3 0.06).
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

    // ── 5마리 확장: 누진 티어 + 결정적 tie-break ──

    // 티어 값 + 가속형(증가폭이 갈수록 커짐). 서버 pvp_policy 와 1:1.
    func testSynergyTiersAccelerate() {
        XCTAssertEqual(TeamSynergy.collectionBonus[4], 0.17)
        XCTAssertEqual(TeamSynergy.collectionBonus[5], 0.26)
        XCTAssertEqual(TeamSynergy.typeBonus[4], 0.10)
        XCTAssertEqual(TeamSynergy.typeBonus[5], 0.15)
        let c = TeamSynergy.collectionBonus
        // 한계 증가폭 비감소(가속): (3-2) ≤ (4-3) ≤ (5-4).
        XCTAssertLessThanOrEqual(c[3]! - c[2]!, c[4]! - c[3]! + 1e-9)
        XCTAssertLessThanOrEqual(c[4]! - c[3]!, c[5]! - c[4]! + 1e-9)
    }

    // 5마리 전원 beast: 타입 5 → +0.15. 컬렉션 최대 mainframe 3(fox/wolf/bear) → +0.10 → spd ×1.25.
    func testFivePetTypeTier() {
        let team = [snap(.fox), snap(.wolf), snap(.bear), snap(.bat), snap(.tRex)]
        XCTAssertEqual(team.map { $0.kind.battleType }, Array(repeating: .beast, count: 5))
        let b = TeamSynergy.bonus(for: team)
        XCTAssertEqual(b.collectionMult, 1.10, accuracy: 1e-9)
        XCTAssertEqual(b.typeStat, .spd)
        XCTAssertEqual(TeamSynergy.statMultiplier(b, .spd), 1.25, accuracy: 1e-9)
    }

    // 타입 동수(beast×2 + warrior×2 + machine×1)는 팀 순서 first-max로 확정 — 순서 바꾸면 대표도 바뀐다.
    // Swift Dictionary 비결정 순서 대신 팀 순서로 결정(서버 파리티). warrior/lancer=warrior, scrapBot=machine.
    func testTypeTieBreakByTeamOrder() {
        let beastFirst = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.warrior), snap(.lancer), snap(.scrapBot)])
        XCTAssertEqual(beastFirst.typeStat, .spd, "beast가 먼저 등장 → beast 대표(spd)")
        let warriorFirst = TeamSynergy.bonus(for: [snap(.warrior), snap(.lancer), snap(.fox), snap(.wolf), snap(.scrapBot)])
        XCTAssertEqual(warriorFirst.typeStat, .atk, "warrior가 먼저 등장 → warrior 대표(atk)")
        // 결정성: 같은 입력은 항상 같은 결과(비결정 순서 회귀 방지).
        for _ in 0..<20 {
            XCTAssertEqual(TeamSynergy.bonus(for: [snap(.fox), snap(.wolf), snap(.warrior), snap(.lancer), snap(.scrapBot)]).typeStat, .spd)
        }
    }

    // ── 컬렉션별·타입별 배수 차등 ──

    // 가중치 맵 값 (서버 pvp_policy 와 1:1).
    func testSynergyWeightsDifferentiated() {
        XCTAssertEqual(TeamSynergy.typeWeight[.arcane], 1.25)
        XCTAssertEqual(TeamSynergy.typeWeight[.mascot], 0.80)
        XCTAssertEqual(TeamSynergy.collectionWeight[.ciRunners], 1.20)   // S
        XCTAssertEqual(TeamSynergy.collectionWeight[.vibeCoders], 0.85)  // B
        XCTAssertNil(TeamSynergy.collectionWeight[.mainframe])           // A = default(미등록 → 1.0)
    }

    // 타입 가중치: 같은 count라도 warrior(1.10)가 beast(1.00)보다 대표 스탯 시너지가 크다.
    func testTypeWeightAppliesToBonus() {
        let warrior = TeamSynergy.bonus(for: [snap(.warrior), snap(.lancer)])   // warrior×2, ×1.10
        let beast = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf)])           // beast×2, ×1.00
        XCTAssertGreaterThan(warrior.typeAdd, beast.typeAdd)
        XCTAssertEqual(warrior.typeAdd, 0.03 * 1.10, accuracy: 1e-9)
        XCTAssertEqual(beast.typeAdd, 0.03 * 1.00, accuracy: 1e-9)
    }

    // 컬렉션 가중치: 같은 count라도 S티어(ciRunners 1.20)가 A티어(mainframe 1.00)보다 collMult가 크다.
    func testCollectionWeightAppliesToBonus() {
        let sTier = TeamSynergy.bonus(for: [snap(.scrapBot), snap(.antennaBot)])  // ciRunners×2 (S)
        let aTier = TeamSynergy.bonus(for: [snap(.fox), snap(.wolf)])             // mainframe×2 (A)
        XCTAssertGreaterThan(sTier.collectionMult, aTier.collectionMult)
        XCTAssertEqual(sTier.collectionMult, 1.0 + 0.05 * 1.20, accuracy: 1e-9)
        XCTAssertEqual(aTier.collectionMult, 1.0 + 0.05 * 1.00, accuracy: 1e-9)
    }
}
