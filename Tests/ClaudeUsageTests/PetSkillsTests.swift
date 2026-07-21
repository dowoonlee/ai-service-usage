import XCTest
@testable import ClaudeUsage

/// 스킬 계층(Phase A) 검증 — 상성 ×2.0/×0.5, 자속 STAB, variant 해금 슬롯, 결정적 선택 AI.
/// 서버 pvp_policy.ts 스킬 계층과 값·규칙 1:1 (파리티는 pvp_engine.parity.test.ts 골든이 잠금).
final class PetSkillsTests: XCTestCase {

    // 스킬 상성 — 타입 6-사이클 재사용, 배수 ×2.0/×1.0/×0.5. 각 타입은 정확히 하나를 이기고 하나에 진다.
    func testSkillEffectivenessCycle() {
        XCTAssertEqual(SkillCatalog.skillSuper, 2.0, accuracy: 1e-9)
        XCTAssertEqual(SkillCatalog.skillWeak, 0.5, accuracy: 1e-9)
        for t in BattleType.allCases {
            let win = t.beats
            XCTAssertEqual(SkillCatalog.skillEffectiveness(t, vs: win), 2.0, accuracy: 1e-9)
            XCTAssertEqual(SkillCatalog.skillEffectiveness(win, vs: t), 0.5, accuracy: 1e-9)
            XCTAssertEqual(SkillCatalog.skillEffectiveness(t, vs: t), 1.0, accuracy: 1e-9)
            let supers = BattleType.allCases.filter { SkillCatalog.skillEffectiveness(t, vs: $0) > 1.0 }.count
            let weaks = BattleType.allCases.filter { SkillCatalog.skillEffectiveness(t, vs: $0) < 1.0 }.count
            XCTAssertEqual(supers, 1)
            XCTAssertEqual(weaks, 1)
        }
    }

    // 자속(STAB) — 스킬 타입 == 펫 타입이면 ×1.5, 아니면 ×1.0.
    func testStab() {
        XCTAssertEqual(SkillCatalog.stabMult, 1.5, accuracy: 1e-9)
        XCTAssertEqual(SkillCatalog.stab(skillType: .beast, petType: .beast), 1.5, accuracy: 1e-9)
        XCTAssertEqual(SkillCatalog.stab(skillType: .beast, petType: .warrior), 1.0, accuracy: 1e-9)
    }

    // variant 해금: 0 → generic만, 1+ → generic + typeShared. generic/typeShared는 항상 펫 자기 타입(자속).
    func testVariantUnlockSlots() {
        let s0 = SkillCatalog.skills(kind: .fox, variant: 0)   // fox = beast
        XCTAssertEqual(s0.count, 1)
        XCTAssertEqual(s0[0].id, "hotfix")
        XCTAssertEqual(s0[0].type, .beast)
        XCTAssertEqual(s0[0].tier, .generic)

        let s1 = SkillCatalog.skills(kind: .fox, variant: 1)
        XCTAssertEqual(s1.count, 2)
        XCTAssertEqual(s1[0].id, "hotfix")           // 슬롯0 유지(선택 tie-break 기준)
        XCTAssertEqual(s1[1].id, "mem_leak")         // beast typeShared
        XCTAssertEqual(s1[1].type, .beast)
        XCTAssertEqual(s1[1].tier, .typeShared)

        // 레인보우(4)도 Phase A에선 typeShared까지만.
        XCTAssertEqual(SkillCatalog.skills(kind: .fox, variant: 4).count, 2)
    }

    // 6타입 전부 typeShared가 정의돼 있고 self-type·power 11.
    func testTypeSharedTableComplete() {
        for t in BattleType.allCases {
            let s = SkillCatalog.typeShared(for: t)
            XCTAssertEqual(s.type, t)
            XCTAssertEqual(s.power, 11.0, accuracy: 1e-9)
            XCTAssertEqual(s.tier, .typeShared)
            XCTAssertNotNil(SkillCatalog.displayName(id: s.id))
        }
    }

    // 결정적 선택 AI — 점수 최대. Phase A는 두 스킬 다 자기 타입이라 power 큰 typeShared를 항상 채택.
    func testSelectPicksHigherPower() {
        let skills = SkillCatalog.skills(kind: .fox, variant: 1)   // [hotfix(8), mem_leak(11)]
        // 방어자 타입 무관하게(둘 다 self-type이라 eff·stab 동일) power 큰 쪽.
        for d in BattleType.allCases {
            let pick = SkillCatalog.select(from: skills, attackerType: .beast, defenderType: d)
            XCTAssertEqual(pick.id, "mem_leak", "defender=\(d)에서 typeShared 채택돼야")
        }
    }

    // 동점(power 동일)이면 슬롯 인덱스 낮은 것(strict >).
    func testSelectTieBreaksToLowestSlot() {
        let a = Skill(id: "a", name: "A", type: .beast, power: 10, tier: .generic)
        let b = Skill(id: "b", name: "B", type: .beast, power: 10, tier: .typeShared)
        let pick = SkillCatalog.select(from: [a, b], attackerType: .beast, defenderType: .chaos)
        XCTAssertEqual(pick.id, "a")
    }

    // variant 0 펫은 generic 하나뿐 → 항상 hotfix.
    func testVariantZeroAlwaysHotfix() {
        let skills = SkillCatalog.skills(kind: .scrapBot, variant: 0)   // machine
        let pick = SkillCatalog.select(from: skills, attackerType: .machine, defenderType: .beast)
        XCTAssertEqual(pick.id, "hotfix")
    }

    // 선택 점수식 = power × skillEff × stab.
    func testScoreFormula() {
        let s = SkillCatalog.typeShared(for: .beast)   // power 11, beast
        // beast 스킬 vs chaos(=beast가 이김) : 11 × 2.0 × 1.5(자속) = 33
        XCTAssertEqual(SkillCatalog.score(s, attackerType: .beast, defenderType: .chaos), 33.0, accuracy: 1e-9)
        // beast 스킬 vs machine(=beast가 짐) : 11 × 0.5 × 1.5 = 8.25
        XCTAssertEqual(SkillCatalog.score(s, attackerType: .beast, defenderType: .machine), 8.25, accuracy: 1e-9)
    }
}
