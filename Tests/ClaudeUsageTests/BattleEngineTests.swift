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

    // ATB: 빠른 팀이 더 자주 행동한다(로그의 자기 측 액션 수가 더 많음).
    func testFasterTeamActsMoreOften() {
        let fast = team([.fox], enh: 15, pu: 8)    // beast(SPD archetype 1.10) 풀강 → 빠름
        let slow = team([.scrapBot], enh: 0)        // machine(SPD 0.75) 무강 → 느림
        let r = BattleEngine.simulate(teamA: fast, teamB: slow, seed: 3)
        let aActs = r.log.filter { $0.attacker == .a }.count
        let bActs = r.log.filter { $0.attacker == .b }.count
        XCTAssertGreaterThan(aActs, bActs, "빠른 팀이 더 많이 행동해야")
    }

    // 패링(퍼펙트 가드) — DEF+SPD 조합. 빠른 탱커 > 밸런스 > 느린 유리몸, 클램프, 단조.
    func testParryChance() {
        let fastTank = BattleEngine.parryChance(defSPD: 120, defDEF: 100, atkSPD: 40, atkDEF: 40)
        let balanced = BattleEngine.parryChance(defSPD: 60, defDEF: 60, atkSPD: 60, atkDEF: 60)
        let slowFrag = BattleEngine.parryChance(defSPD: 40, defDEF: 40, atkSPD: 120, atkDEF: 60)
        XCTAssertGreaterThan(fastTank, balanced)
        XCTAssertGreaterThan(balanced, slowFrag)
        XCTAssertLessThanOrEqual(fastTank, BattleEngine.parryMax)
        XCTAssertGreaterThanOrEqual(slowFrag, 0)
        XCTAssertLessThan(slowFrag, 0.02, "느린 유리몸은 거의 패링 못 함")
        // SPD·DEF 각각 단조 증가.
        XCTAssertGreaterThan(BattleEngine.parryChance(defSPD: 120, defDEF: 60, atkSPD: 60, atkDEF: 60), balanced)
        XCTAssertGreaterThan(BattleEngine.parryChance(defSPD: 60, defDEF: 120, atkSPD: 60, atkDEF: 60), balanced)
    }

    // 패링은 실제 배틀에서 발동한다(대량 시드에서 parried 이벤트 존재).
    func testParryOccursInBattles() {
        var parries = 0
        for seed in 0..<100 {
            let r = BattleEngine.simulate(teamA: team([.fox, .wolf, .bear]),
                                          teamB: team([.scrapBot, .antennaBot, .pixelBot]), seed: UInt64(seed))
            parries += r.log.filter { $0.parried }.count
        }
        XCTAssertGreaterThan(parries, 0)
    }

    // 레인보우(variant 4) 공격자만 크리 발동 — 기본(0)은 절대 크리 없음.
    func testRainbowCritOnlyForRainbow() {
        let rainbow = BattleTeam([BattlePetSnapshot(kind: .fox, variant: 4, enhanceLevel: 10, progressUnits: 4)])
        let plain = BattleTeam([BattlePetSnapshot(kind: .wolf, variant: 0, enhanceLevel: 10, progressUnits: 4)])
        var rainbowCrits = 0, plainCrits = 0
        for seed in 0..<100 {
            let r = BattleEngine.simulate(teamA: rainbow, teamB: plain, seed: UInt64(seed))
            rainbowCrits += r.log.filter { $0.attacker == .a && $0.crit == true }.count
            plainCrits += r.log.filter { $0.attacker == .b && $0.crit == true }.count
        }
        XCTAssertGreaterThan(rainbowCrits, 0, "레인보우 공격자는 크리가 나와야")
        XCTAssertEqual(plainCrits, 0, "기본 이로치는 크리 없음")
    }

    // 궁극기 — 레인보우(variant4)만 충전 게이지가 차면 발동. 비레인보우(variant0)는 절대 발동 안 함.
    func testUltimateFiresForRainbowOnly() {
        let rainbow = BattleTeam([BattlePetSnapshot(kind: .warrior, variant: 4, enhanceLevel: 5, progressUnits: 2)])
        let tank = BattleTeam([BattlePetSnapshot(kind: .mrMan, variant: 0, enhanceLevel: 15, progressUnits: 8)])  // mascot 만강 = 최고 HP → 긴 배틀(레인보우 6+행동 보장)
        var rbUlts = 0, tankUlts = 0
        for seed in 0..<100 {
            let r = BattleEngine.simulate(teamA: rainbow, teamB: tank, seed: UInt64(seed))
            rbUlts += r.log.filter { $0.attacker == .a && SkillCatalog.isUltimate($0.move) }.count
            tankUlts += r.log.filter { $0.attacker == .b && SkillCatalog.isUltimate($0.move) }.count
        }
        XCTAssertGreaterThan(rbUlts, 0, "레인보우는 충전 후 궁극기를 발동해야")
        XCTAssertEqual(tankUlts, 0, "비레인보우(variant0)는 궁극기 없음")
    }

    // 로그 이벤트의 데미지는 항상 ≥ 1, 스킬 상성 배수는 유효 3값 중 하나(Phase A: ×2.0/×1.0/×0.5).
    func testLogInvariants() {
        let r = BattleEngine.simulate(teamA: team(weak), teamB: team(strong), seed: 777)
        for e in r.log {
            XCTAssertGreaterThanOrEqual(e.damage, 1)
            XCTAssertTrue([0.5, 1.0, 2.0].contains(e.effectiveness))
        }
    }

    // 격노 램프: rageStart까지 배수 1.0, 이후 단조 증가.
    func testRageMultiplierRamp() {
        XCTAssertEqual(BattleEngine.rageMultiplier(action: 1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(BattleEngine.rageMultiplier(action: BattleEngine.rageStart), 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(BattleEngine.rageMultiplier(action: BattleEngine.rageStart + 10),
                             BattleEngine.rageMultiplier(action: BattleEngine.rageStart + 5))
    }

    // variant3 Epic+ 고유기 배틀도 backstop(maxRounds) 전에 종료하고 데미지 불변식을 지킨다.
    // unique(power14 자기타입 STAB, 실효 21)가 종료성/데미지≥1 불변식을 깨지 않음을 회귀 가드.
    func testUniqueBattleTerminates() {
        func t3(_ kinds: [PetKind]) -> BattleTeam {
            BattleTeam(kinds.map { BattlePetSnapshot(kind: $0, variant: 3, enhanceLevel: 5, progressUnits: 2) })
        }
        let a = t3([.warrior, .lancer, .monk])       // mythic warrior — 전원 고유기 보유
        let b = t3([.archer, .pawn, .heroKnight])    // mythic/epic warrior — 전원 고유기 보유
        for seed in 0..<60 {
            let r = BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64(seed))
            XCTAssertLessThan(r.rounds, BattleEngine.maxRounds, "variant3 고유기 배틀도 backstop 전 종료(seed \(seed))")
            for e in r.log { XCTAssertGreaterThanOrEqual(e.damage, 1) }
        }
    }

    // R1 회귀 가드: 데미지식은 성장이 atk/def에 동시 곱해져 비율 불변 → TTK가 HP만큼 선형 증가.
    // 격노 램프가 없으면 풀강 탱커(mascot=최고 HP archetype) 미러전이 maxRounds를 상시 초과해
    // "KO 없는 HP 총량 타이브레이크"로 수렴한다. 램프가 있으면 backstop 전에 KO로 결판나야 한다.
    func testEnhancedTankMirrorTerminatesByKO() {
        let tanks: [PetKind] = [.mrMan, .bumpyBot, .princessSera]   // helloWorld / mascot 모노(시너지 ×1.15)
        let a = team(tanks, enh: 15, pu: 8)                          // 이론상 최대 성장
        let b = team(tanks, enh: 15, pu: 8)
        for seed in 0..<80 {
            let r = BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64(seed))
            XCTAssertLessThan(r.rounds, BattleEngine.maxRounds,
                              "풀강 탱커 미러는 격노 램프로 backstop 전에 종결돼야(seed \(seed), rounds \(r.rounds))")
            XCTAssertNotNil(r.winner, "KO 종결이면 승자 존재(seed \(seed))")
        }
    }
}
