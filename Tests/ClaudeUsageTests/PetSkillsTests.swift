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

        // 레인보우(4)는 하위 슬롯 누적 → generic+typeShared+collectionShared 3개(Phase B1 기준).
        XCTAssertEqual(SkillCatalog.skills(kind: .fox, variant: 4).count, 3)
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

    // ── collectionShared (Phase B1) ──────────────────────────────────────────

    // **모든** PetCollection 케이스가 collectionShared 매핑을 가진다(소진성). count 매직넘버가 아니라
    // allCases를 순회 → 향후 컬렉션 추가 시 테이블 갱신을 깜빡하면 여기서 fail-closed(강제언랩 크래시 예방).
    func testCollectionSharedCoversAllCollections() {
        for c in PetCollection.allCases {
            XCTAssertNotNil(SkillCatalog.collectionSharedTable[c], "\(c) collectionShared 매핑 누락")
            let skill = SkillCatalog.collectionShared(for: c)   // 매핑 없으면 강제언랩 크래시 → 테스트가 먼저 잡음
            XCTAssertEqual(skill.power, 12.0, accuracy: 1e-9)
            XCTAssertNotNil(SkillCatalog.displayName(id: skill.id))
        }
    }

    // **핵심 불변식**: 모든 collectionShared는 컬렉션의 자기 배틀타입과 다른 타입(오프타입) — 커버리지 활성화 근거.
    func testCollectionSharedIsOffType() {
        for (collection, e) in SkillCatalog.collectionSharedTable {
            XCTAssertNotEqual(e.type, collection.battleType,
                              "\(collection) collectionShared는 오프타입이어야(자기타입=\(collection.battleType))")
            XCTAssertEqual(SkillCatalog.collectionShared(for: collection).tier, .collectionShared)
        }
    }

    // variant 2 해금: [generic, typeShared, collectionShared] 3슬롯, 슬롯2가 collectionShared.
    func testVariant2UnlocksCollectionShared() {
        let s = SkillCatalog.skills(kind: .fox, variant: 2)   // fox = mainframe/beast
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[2].tier, .collectionShared)
        XCTAssertEqual(s[2].id, "mainframe_overload")
        XCTAssertEqual(s[2].type, .machine)   // 오프타입
    }

    // 커버리지: variant2 beast가 machine 방어자 상대로 약한 자기타입 대신 오프타입 collectionShared 선택.
    func testCoveragePicksOffTypeVsResistantDefender() {
        let s = SkillCatalog.skills(kind: .fox, variant: 2)
        // vs machine: 자기타입(beast) ×0.5라 typeShared 손해 → 오프타입 machine 무브(중립) 채택.
        let vsMachine = SkillCatalog.select(from: s, attackerType: .beast, defenderType: .machine)
        XCTAssertEqual(vsMachine.id, "mainframe_overload")
        // vs chaos: 자기타입 super(×2.0)+STAB라 typeShared가 오프타입을 이김 → 커버리지 안 씀.
        let vsChaos = SkillCatalog.select(from: s, attackerType: .beast, defenderType: .chaos)
        XCTAssertEqual(vsChaos.id, "mem_leak")
    }

    // ── unique (Phase B2) ────────────────────────────────────────────────────

    // **불변식(양방향)**: 모든 Epic+ 펫이 고유기를 갖고, 저레어(Common/Rare)는 갖지 않는다.
    // gen_pet_meta.py의 Epic+ 검증과 대칭 — 여기가 클라 쪽 fail-closed 가드.
    func testUniqueTableCoversExactlyEpicPlus() {
        let epicPlus: Set<Rarity> = [.epic, .legendary, .mythic]
        for k in PetKind.allCases {
            let rarity = PetKind.rarityFor(k) ?? .common
            let hasUnique = SkillCatalog.uniqueTable[k] != nil
            XCTAssertEqual(hasUnique, epicPlus.contains(rarity),
                           "\(k) rarity=\(rarity): unique 보유(\(hasUnique)) ≠ Epic+(\(epicPlus.contains(rarity)))")
        }
    }

    // 고유기는 자기타입 시그니처 · power 14 · 표시명 존재.
    func testUniqueIsSelfTypeSignature() {
        for (kind, _) in SkillCatalog.uniqueTable {
            let u = SkillCatalog.unique(for: kind)!
            XCTAssertEqual(u.type, kind.battleType, "\(kind) 고유기는 자기타입이어야")
            XCTAssertEqual(u.power, 14.0, accuracy: 1e-9)
            XCTAssertEqual(u.tier, .unique)
            XCTAssertNotNil(SkillCatalog.displayName(id: u.id))
        }
    }

    // 스킬 id는 계층(generic/typeShared/collectionShared/unique) 전역에서 유일해야 한다 —
    // nameById가 5테이블(generic/typeShared/collectionShared/unique/ultimate)을 병합하며 id로 override하므로,
    // 충돌하면 표시명이 조용히 덮인다.
    func testAllSkillIdsAreUnique() {
        var ids = ["hotfix"]
        ids += SkillCatalog.typeSharedTable.values.map { $0.id }
        ids += SkillCatalog.collectionSharedTable.values.map { $0.id }
        ids += SkillCatalog.uniqueTable.values.map { $0.id }
        ids += SkillCatalog.ultimateTable.values.map { $0.id }
        XCTAssertEqual(Set(ids).count, ids.count, "스킬 id 계층 간 충돌 — 중복 id 존재")
        // nameById가 모든 id를 커버(override로 잃은 id 없음).
        XCTAssertEqual(SkillCatalog.nameById.count, ids.count)
    }

    // variant 3 해금: Epic+는 4슬롯(고유기 추가), 저레어는 3슬롯 유지.
    func testVariant3UniqueSlotGating() {
        // fox = common → variant3도 3슬롯(고유기 없음)
        XCTAssertNil(SkillCatalog.unique(for: .fox))
        XCTAssertEqual(SkillCatalog.skills(kind: .fox, variant: 3).count, 3)
        // warrior = mythic → variant3에서 4번째 슬롯 = 고유기(자기타입, power14)
        let w = SkillCatalog.skills(kind: .warrior, variant: 3)
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w[3].tier, .unique)
        XCTAssertEqual(w[3].id, "fullstack_smash")
        XCTAssertEqual(w[3].type, .warrior)
        // variant2에선 Epic+도 아직 3슬롯(고유기 미해금)
        XCTAssertEqual(SkillCatalog.skills(kind: .warrior, variant: 2).count, 3)
    }

    // ── ultimate (Phase C) ───────────────────────────────────────────────────

    // 궁극기 6종(타입별) · 자기타입 · power 24 · isUltimate · 표시명.
    func testUltimateTableComplete() {
        XCTAssertEqual(SkillCatalog.ultimateTable.count, 6)
        for t in BattleType.allCases {
            let u = SkillCatalog.ultimate(for: t)
            XCTAssertEqual(u.type, t, "궁극기는 자기타입")
            XCTAssertEqual(u.power, 24.0, accuracy: 1e-9)
            XCTAssertEqual(u.tier, .ultimate)
            XCTAssertTrue(SkillCatalog.isUltimate(u.id))
            XCTAssertNotNil(SkillCatalog.displayName(id: u.id))
        }
        XCTAssertFalse(SkillCatalog.isUltimate("hotfix"))   // 정규 스킬은 궁극기 아님
    }

    // 궁극기는 정규 스킬 목록(skills)에 없다 — 충전 게이지로 별도 발동(엔진). variant4도 정규 4슬롯.
    func testUltimateNotInRegularSkills() {
        let s = SkillCatalog.skills(kind: .warrior, variant: 4)
        XCTAssertEqual(s.count, 4)
        XCTAssertFalse(s.contains { $0.tier == .ultimate })
    }

    // ── 효과 연동 (E2) ──────────────────────────────────────────────────────

    // rider·궁극기 grant가 가리키는 effectId는 전부 EffectCatalog에 실재해야 한다(끊어진 참조 = 조용한 no-op).
    func testRiderAndUltEffectIdsResolve() {
        for (t, r) in SkillCatalog.typeSharedRiderTable {
            XCTAssertNotNil(EffectCatalog.effect(r.effectId), "\(t) rider \(r.effectId) 카탈로그 누락")
            XCTAssertTrue(r.chance > 0 && r.chance <= 1.0)
        }
        for (_, r) in SkillCatalog.collectionSharedRiderTable {
            XCTAssertNotNil(EffectCatalog.effect(r.effectId))
        }
        for (id, fx) in SkillCatalog.ultimateEffectTable {
            if case .grant(let e) = fx {
                XCTAssertNotNil(EffectCatalog.effect(e), "궁극기 \(id) grant \(e) 카탈로그 누락")
            }
        }
        XCTAssertEqual(SkillCatalog.ultimateEffectTable.count, 6, "궁극기 6종 전부 특수효과 보유")
    }

    // unique는 자기 타입 typeShared rider를 상속(타입 특성) — 미상속이면 Epic+는 unique가 ts를 항상
    // 지배해(21 > 16.5) rider가 영영 발동하지 않는다(E2 실측 회귀 가드).
    func testUniqueInheritsTypeRider() {
        for (kind, _) in SkillCatalog.uniqueTable {
            let u = SkillCatalog.unique(for: kind)!
            XCTAssertEqual(u.rider, SkillCatalog.typeSharedRiderTable[kind.battleType],
                           "\(kind) unique rider는 타입 rider 상속이어야")
        }
    }

    // ── E3 — cs rider 완전성 + 선택 AI 자기버프 우선 ─────────────────────────

    // collectionShared rider는 19컬렉션 전부 배정 + effectId가 카탈로그에 실재해야 한다.
    func testCollectionRidersCompleteAndResolve() {
        XCTAssertEqual(SkillCatalog.collectionSharedRiderTable.count, PetCollection.allCases.count)
        for c in PetCollection.allCases {
            guard let r = SkillCatalog.collectionSharedRiderTable[c] else {
                return XCTFail("\(c) cs rider 누락")
            }
            XCTAssertNotNil(EffectCatalog.effect(r.effectId), "\(c) cs rider \(r.effectId) 카탈로그 누락")
        }
    }

    // 선택 AI(E3) — 자기 버프 rider가 미보유면 데미지가 낮아도 그 버프 스킬을 우선한다.
    func testSelectPrefersUnownedSelfBuff() {
        // mascot v2: hotfix(mascot) + onboarding(mascot, load_balancer 자버프) + collectionShared.
        // 방어자 무관하게 미보유 버프(load_balancer/기타 자버프)를 우선 후보로 골라야.
        let skills = SkillCatalog.skills(kind: .mrMan, variant: 2)   // mascot(helloWorld)
        let selfBuffIds = Set(skills.compactMap { $0.rider }.filter { $0.selfTarget }.map { $0.effectId })
        XCTAssertFalse(selfBuffIds.isEmpty, "이 펫은 자버프 rider를 가져야 테스트 유효")
        let picked = SkillCatalog.select(from: skills, attackerType: .mascot, defenderType: .beast,
                                         activeEffectIds: [], hasDebuff: false)
        XCTAssertTrue(picked.rider?.selfTarget == true && selfBuffIds.contains(picked.rider!.effectId),
                      "미보유 자버프를 우선해야 (실제 선택: \(picked.id))")
        // 이미 그 버프를 보유하면 우선 후보에서 빠져 최대 데미지 스킬로 복귀.
        let picked2 = SkillCatalog.select(from: skills, attackerType: .mascot, defenderType: .beast,
                                          activeEffectIds: selfBuffIds, hasDebuff: false)
        let maxDmg = SkillCatalog.select(from: skills, attackerType: .mascot, defenderType: .beast)
        XCTAssertEqual(picked2.id, maxDmg.id, "버프 보유 시 최대 데미지 스킬로 복귀")
    }
}
