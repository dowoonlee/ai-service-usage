import XCTest
@testable import ClaudeUsage

/// 아레나 배틀 스탯 파생 + 타입 상성 검증 (P0 순수 로직).
final class PetBattleStatsTests: XCTestCase {

    // 19개 컬렉션이 모두 타입에 매핑되고, 6타입 전부 사용된다.
    func testAllCollectionsMapAndAllTypesUsed() {
        var used = Set<BattleType>()
        for c in PetCollection.allCases { used.insert(c.battleType) }
        XCTAssertEqual(used.count, BattleType.allCases.count, "6타입 전부 최소 1개 컬렉션에 매핑돼야 함")
    }

    // 펫 → 타입은 컬렉션 경로와 일치.
    func testPetKindTypeMatchesCollection() {
        XCTAssertEqual(PetKind.fox.battleType, PetKind.fox.collection.battleType)
        XCTAssertEqual(PetKind.scrapBot.battleType, .machine)   // ciRunners
        XCTAssertEqual(PetKind.fox.battleType, .beast)          // mainframe
    }

    // 6-사이클 상성: 각 타입은 정확히 하나를 이기고(1.6) 하나에 진다(0.625), 그 외 1.0.
    func testEffectivenessCycle() {
        for t in BattleType.allCases {
            let win = t.beats
            XCTAssertEqual(BattleType.effectiveness(t, vs: win), 1.6, accuracy: 1e-9)
            XCTAssertEqual(BattleType.effectiveness(win, vs: t), 0.625, accuracy: 1e-9)
            XCTAssertEqual(BattleType.effectiveness(t, vs: t), 1.0, accuracy: 1e-9)

            // 정확히 하나만 이기고 하나만 진다.
            let beatsCount = BattleType.allCases.filter { BattleType.effectiveness(t, vs: $0) > 1.0 }.count
            let losesCount = BattleType.allCases.filter { BattleType.effectiveness(t, vs: $0) < 1.0 }.count
            XCTAssertEqual(beatsCount, 1)
            XCTAssertEqual(losesCount, 1)
        }
        // 사이클 폐합.
        XCTAssertEqual(BattleType.machine.beats, .beast)
        XCTAssertEqual(BattleType.beast.beats, .chaos)
        XCTAssertEqual(BattleType.chaos.beats, .arcane)
        XCTAssertEqual(BattleType.arcane.beats, .mascot)
        XCTAssertEqual(BattleType.mascot.beats, .warrior)
        XCTAssertEqual(BattleType.warrior.beats, .machine)
    }

    // 등급 기본치는 단조 증가 (압축 곡선).
    func testRarityBaseMonotonic() {
        let order: [Rarity] = [.common, .rare, .epic, .legendary, .mythic]
        for i in 1..<order.count {
            XCTAssertGreaterThan(PetBattleStats.rarityBase(order[i]), PetBattleStats.rarityBase(order[i-1]))
        }
        // 압축 — Mythic/Common ≈ 2배 (25~50배 아님).
        let ratio = PetBattleStats.rarityBase(.mythic) / PetBattleStats.rarityBase(.common)
        XCTAssertLessThan(ratio, 2.2)
        XCTAssertGreaterThan(ratio, 1.7)
    }

    // 성장 배수: 강화·숙련도에 대해 단조 증가, 상한 준수, 무투자면 1.0.
    func testGrowthMultiplier() {
        XCTAssertEqual(PetBattleStats.growthMultiplier(enhanceLevel: 0, progressUnits: 0), 1.0, accuracy: 1e-9)
        let g5 = PetBattleStats.growthMultiplier(enhanceLevel: 5, progressUnits: 0)
        let g10 = PetBattleStats.growthMultiplier(enhanceLevel: 10, progressUnits: 0)
        let g15 = PetBattleStats.growthMultiplier(enhanceLevel: 15, progressUnits: 0)
        XCTAssertLessThan(g5, g10)
        XCTAssertLessThan(g10, g15)
        // 숙련도가 더해지면 증가.
        XCTAssertGreaterThan(PetBattleStats.growthMultiplier(enhanceLevel: 5, progressUnits: 8),
                             PetBattleStats.growthMultiplier(enhanceLevel: 5, progressUnits: 0))
        // 상한 준수.
        XCTAssertLessThanOrEqual(PetBattleStats.growthMultiplier(enhanceLevel: 15, progressUnits: 999),
                                 PetBattleStats.statCapMult)
        // 숙련도 상한.
        XCTAssertEqual(PetBattleStats.masteryBonus(progressUnits: 999), PetBattleStats.masteryMax, accuracy: 1e-9)
    }

    // 최종 스탯: 강화가 오르면 총합 증가, 모든 스탯 ≥ 1.
    func testComputeStatsMonotonicInEnhance() {
        let k = PetKind.fox
        let s0 = PetBattleStats.compute(kind: k, variant: 0, enhanceLevel: 0, progressUnits: 0)
        let s10 = PetBattleStats.compute(kind: k, variant: 0, enhanceLevel: 10, progressUnits: 0)
        XCTAssertGreaterThan(s10.total, s0.total)
        XCTAssertGreaterThanOrEqual(min(s0.hp, s0.atk, s0.def, s0.spd), 1)
    }

    // 밸런스 의도: 풀강 커먼의 스탯 총합이 무강 에픽을 넘어설 수 있다(등급이 전부가 아님).
    func testBalanceEnhancedCommonRivalsEpic() {
        // fox=common(mainframe). 무강 에픽 표본을 찾아 비교.
        guard let epicKind = PetKind.allCases.first(where: { PetKind.rarityFor($0) == .epic }) else {
            return XCTFail("에픽 표본 없음")
        }
        let commonMaxed = PetBattleStats.compute(kind: .fox, variant: 0, enhanceLevel: 15, progressUnits: 8)
        let epicBase = PetBattleStats.compute(kind: epicKind, variant: 0, enhanceLevel: 0, progressUnits: 0)
        XCTAssertGreaterThan(commonMaxed.total, epicBase.total,
                             "풀강 커먼이 무강 에픽을 총합으로 넘어설 수 있어야 함(강화가 경쟁 경로)")
    }

    // 개체별 스탯 프로필 — 결정적 + 같은 타입이라도 kind마다 분배 상이.
    func testPerKindProfileDeterministicAndDistinct() {
        let a1 = PetBattleStats.compute(kind: .scrapBot, variant: 0, enhanceLevel: 10, progressUnits: 4)
        let a2 = PetBattleStats.compute(kind: .scrapBot, variant: 0, enhanceLevel: 10, progressUnits: 4)
        XCTAssertEqual(a1, a2, "같은 kind는 항상 같은 스탯(결정적)")
        let beasts: [PetKind] = [.fox, .wolf, .bear, .bat, .tRex]   // 전부 beast
        let profiles = Set(beasts.map { k -> String in
            let s = PetBattleStats.compute(kind: k, variant: 0, enhanceLevel: 15, progressUnits: 8)
            return "\(s.hp),\(s.atk),\(s.def),\(s.spd)"
        })
        XCTAssertGreaterThan(profiles.count, 1, "같은 rarity·type이라도 개체마다 스탯 프로필이 달라야")
    }

    // 밸런스 중립 — 프로필(profileArchetype)은 분배만 바꾸고 archetype 합은 보존한다.
    // (compute()의 총합은 HP ×1.5 스케일이 별도로 곱해져 보존되지 않음 — 그건 의도된 TTK 조정이므로
    //  balance-neutral 불변식은 스케일 전 단계인 profileArchetype에서 검증한다.)
    func testPerKindProfileSumPreserving() {
        for kind in [PetKind.fox, .scrapBot, .warrior] {
            let a = kind.battleType.archetype
            let p = PetBattleStats.profileArchetype(kind)
            let pureSum = a.hp + a.atk + a.def + a.spd
            let profSum = p.hp + p.atk + p.def + p.spd
            XCTAssertEqual(profSum, pureSum, accuracy: 1e-9,
                           "\(kind): 프로필 합은 순수 archetype 합을 보존해야(밸런스 중립)")
        }
    }

    // 이로치 버프 — 단계가 높을수록 전 스탯↑. 레인보우(4)>이로치3(3)>기본(0).
    func testVariantBuffMonotonic() {
        let v0 = PetBattleStats.compute(kind: .fox, variant: 0, enhanceLevel: 5, progressUnits: 0)
        let v3 = PetBattleStats.compute(kind: .fox, variant: 3, enhanceLevel: 5, progressUnits: 0)
        let v4 = PetBattleStats.compute(kind: .fox, variant: 4, enhanceLevel: 5, progressUnits: 0)
        XCTAssertGreaterThan(v3.total, v0.total)
        XCTAssertGreaterThan(v4.total, v3.total, "레인보우(+18%)가 이로치3(+10%)보다 총합 높아야")
    }
}
