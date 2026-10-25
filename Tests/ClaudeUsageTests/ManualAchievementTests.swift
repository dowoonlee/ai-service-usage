import XCTest
@testable import ClaudeUsage

final class ManualAchievementTests: XCTestCase {
    private func pet(_ type: BattleType) -> BattlePetSnapshot {
        BattlePetSnapshot(kind: PetKind.allCases.first { $0.battleType == type }!, variant: 4)
    }
    private func battle(_ a: [BattleType] = [.beast, .warrior, .mascot],
                        _ b: [BattleType] = [.machine, .arcane, .chaos]) throws -> ManualBattleState {
        var s = try ManualBattleEngine.make(teamA: a.map(pet), teamB: b.map(pet), seed: 33)
        for side in 0...1 { for i in s.teams[side].fighters.indices {
            s.teams[side].fighters[i].stats = BattleStats(hp: 500, atk: 20, def: 100, spd: side == 0 ? 90 : 100)
            s.teams[side].fighters[i].hp = 500
        } }
        return s
    }
    private func basic(_ s: ManualBattleState, _ side: Int) -> ManualCommand {
        .move(s.teams[side].fighters[s.teams[side].active].moves[0].id)
    }
    private func fact(_ s: ManualBattleState, _ achievement: ManualAchievement) -> Bool {
        s.events.contains { $0.kind == "achievementFact" && $0.moveID == achievement.rawValue }
    }

    func testSuperEffectiveKOMustBeDirectAndCumulativeDeduplicated() throws {
        var s = try battle([.warrior], [.machine])
        s.teams[1].fighters[0].hp = 1
        s = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), basic(s, 1)])
        XCTAssertTrue(fact(s, .typeExpert))
        var archive = ManualPracticeArchive(state: s)
        archive.recordResult(); archive.recordResult()
        XCTAssertEqual(archive.achievementPreview?.value(.typeExpert), 1)
        XCTAssertTrue(archive.achievementPreview?.contains(.firstCommand) == true)
        for _ in 1..<10 { s.id = UUID(); archive.state = s; archive.recordResult() }
        XCTAssertTrue(archive.achievementPreview?.contains(.typeExpert) == true)
        XCTAssertEqual(archive.achievementPreview?.value(.typeExpert), 10)

        var dot = try battle([.warrior], [.machine])
        dot.turn = 2; dot.teams[1].fighters[0].hp = 1
        dot.teams[1].fighters[0].effects = [ManualEffect(id: "mem_leak", applied: 1, expires: 4, sequence: 1)]
        dot = try ManualBattleEngine.resolve(dot, commands: [.guardMove, .guardMove])
        XCTAssertFalse(fact(dot, .typeExpert), "DoT must not count as a super-effective direct knockout")
    }

    func testResistedSwitchRequiresImmediateNextTurnKO() throws {
        var s = try battle()
        s = try ManualBattleEngine.resolve(s, commands: [.swap(1), basic(s, 1)])
        XCTAssertTrue(s.events.contains { $0.kind == "resistedSwitch" })
        let prepared = s
        s.teams[1].fighters[s.teams[1].active].hp = 1
        s.teams[0].fighters[1].stats.spd = 200
        s = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), basic(s, 1)])
        XCTAssertTrue(fact(s, .switchCounter))

        var delayed = try ManualBattleEngine.resolve(prepared, commands: [.guardMove, .guardMove])
        delayed.teams[1].fighters[delayed.teams[1].active].hp = 1
        delayed = try ManualBattleEngine.resolve(delayed, commands: [basic(delayed, 0), basic(delayed, 1)])
        XCTAssertFalse(fact(delayed, .switchCounter))

        var neutral = try battle()
        neutral.teams[1].fighters[0].moves[0].type = "arcane"
        neutral = try ManualBattleEngine.resolve(neutral, commands: [.swap(1), basic(neutral, 1)])
        XCTAssertFalse(neutral.events.contains { $0.kind == "resistedSwitch" })
    }

    func testSpeedReductionMustActuallyReverseOrder() throws {
        var s = try battle([.warrior], [.machine])
        s.turn = 2
        s.teams[1].fighters[0].hp = 1
        s.teams[1].fighters[0].effects = [ManualEffect(id: "legacy", applied: 1, expires: 4, sequence: 1)]
        var alreadyFast = s; alreadyFast.teams[0].fighters[0].stats.spd = 110
        let flipped = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), basic(s, 1)])
        XCTAssertTrue(fact(flipped, .speedPlanner))
        let ordinary = try ManualBattleEngine.resolve(alreadyFast, commands: [basic(alreadyFast, 0), basic(alreadyFast, 1)])
        XCTAssertFalse(fact(ordinary, .speedPlanner))
        let guarded = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), .guardMove])
        XCTAssertFalse(fact(guarded, .speedPlanner), "priority must not be mistaken for a speed reversal")
    }

    func testBankedUltimateRequiresTwoDifferentDirectVictims() throws {
        var s = try battle()
        s.teams[0].charge = 10
        s.teams[0].fighters[0].stats.spd = 200
        s.teams[1].fighters[0].hp = 1
        s = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), basic(s, 1)])
        XCTAssertTrue(s.events.contains { $0.kind == "reservedUltimate" })
        XCTAssertFalse(fact(s, .ultimateReserve))
        let reserved = s
        s.teams[1].fighters[s.teams[1].active].hp = 1
        let ultimate = s.teams[0].fighters[0].moves.last!
        s = try ManualBattleEngine.resolve(s, commands: [.move(ultimate.id), basic(s, 1)])
        XCTAssertTrue(fact(s, .ultimateReserve))

        var splashOnly = reserved
        let active = splashOnly.teams[1].active
        let bench = try XCTUnwrap(splashOnly.teams[1].fighters.indices.first { $0 != active && splashOnly.teams[1].fighters[$0].alive })
        splashOnly.teams[1].fighters[bench].hp = 1
        splashOnly = try ManualBattleEngine.resolve(splashOnly, commands: [.move(ultimate.id), .guardMove])
        XCTAssertTrue(splashOnly.teams[1].fighters[active].alive)
        XCTAssertTrue(fact(splashOnly, .ultimateReserve), "an ultimate splash knockout also spends the reserved ultimate meaningfully")

        var noCharge = try battle()
        noCharge.teams[1].fighters[0].hp = 1
        noCharge = try ManualBattleEngine.resolve(noCharge, commands: [basic(noCharge, 0), basic(noCharge, 1)])
        XCTAssertFalse(noCharge.events.contains { $0.kind == "reservedUltimate" })
    }

    func testComebackNeedsVictoryAndActualOneVersusThreeWindow() throws {
        var s = try battle()
        s.teams[0].fighters[1].hp = 0; s.teams[0].fighters[2].hp = 0
        s.teams[0].fighters[0].stats.spd = 200
        for _ in 0..<3 {
            s.teams[1].fighters[s.teams[1].active].hp = 1
            s = try ManualBattleEngine.resolve(s, commands: [basic(s, 0), basic(s, 1)])
        }
        XCTAssertEqual(s.outcome?.winner, 0)
        var progress = ManualAchievementProgress()
        progress.apply(s, mastery: [:])
        XCTAssertTrue(progress.contains(.lastStand))
        s.outcome = ManualOutcome(winner: 1, reason: "knockout")
        var lost = ManualAchievementProgress(); lost.apply(s, mastery: [:])
        XCTAssertFalse(lost.contains(.lastStand))
    }

    func testCheckpointCountsActualHealedRecipientsAndRequiresWin() throws {
        var s = try battle([.mascot, .beast, .warrior])
        let pet = s.teams[0].fighters[0].pet
        s.teams[0].fighters[0].moves = ManualBattleRules.moves(for: pet, branch: .alternate)
        s.teams[0].fighters[0].branch = .alternate
        s.teams[0].charge = 10
        for i in 0..<3 { s.teams[0].fighters[i].hp = 200 }
        var onlyTwo = s; onlyTwo.teams[0].fighters[2].hp = 500
        let healed = try ManualBattleEngine.resolve(s, commands: [.move("checkpoint"), .guardMove])
        XCTAssertTrue(fact(healed, .teamRecovery))
        let partial = try ManualBattleEngine.resolve(onlyTwo, commands: [.move("checkpoint"), .guardMove])
        XCTAssertFalse(fact(partial, .teamRecovery))
        var progress = ManualAchievementProgress(); progress.apply(healed, mastery: [:])
        XCTAssertFalse(progress.contains(.teamRecovery), "an unfinished game cannot grant an achievement")
        var win = healed; win.outcome = ManualOutcome(winner: 0, reason: "knockout")
        progress.apply(win, mastery: [:]); XCTAssertTrue(progress.contains(.teamRecovery))
    }

    func testDualUltimateRequiresBothBranchesOnSamePetAndNoAbandonedGames() throws {
        var s = try battle()
        s.outcome = ManualOutcome(winner: 0, reason: "knockout")
        var split = ManualAchievementProgress()
        split.apply(s, mastery: ["fox": ManualMasteryRecord(originalWins: 1), "wolf": ManualMasteryRecord(alternateWins: 1)])
        XCTAssertFalse(split.contains(.dualUltimate))
        split.apply(s, mastery: ["fox": ManualMasteryRecord(originalWins: 1, alternateWins: 1)])
        XCTAssertTrue(split.contains(.dualUltimate))
        for reason in ["surrender", "expired", "cancelled"] {
            s.outcome = ManualOutcome(winner: 0, reason: reason)
            var invalid = ManualAchievementProgress(); invalid.apply(s, mastery: ["fox": ManualMasteryRecord(originalWins: 1, alternateWins: 1)])
            XCTAssertTrue(invalid.unlocked.isEmpty)
        }
        s.outcome = ManualOutcome(winner: 0, reason: "knockout"); s.tutorial = true
        var tutorial = ManualAchievementProgress(); tutorial.apply(s, mastery: [:])
        XCTAssertTrue(tutorial.unlocked.isEmpty)
    }
}

@MainActor
final class ManualAchievementRewardTests: SandboxedTestCase {
    func testStatusDecodesAchievementProgressAndOldServerResponse() throws {
        let data = Data(#"{"enabled":true,"records":{},"active":null,"achievements":{"progress":{"switch_counter":1},"unlocked":["switch_counter"]}}"#.utf8)
        let status = try JSONDecoder().decode(RankingAPI.ManualArenaStatus.self, from: data)
        XCTAssertTrue(status.achievements?.contains(.switchCounter) == true)
        let legacy = try JSONDecoder().decode(RankingAPI.ManualArenaStatus.self, from: Data(#"{"enabled":false,"records":{},"active":null}"#.utf8))
        XCTAssertNil(legacy.achievements)
    }
    func testTitlesOnlyUnlockFromOwnerScopedOfficialCache() {
        let s = Settings.shared
        s.rankingDeviceID = "owner-one"
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.manualSwitcher))
        ManualAchievementStore.shared.replace(ManualAchievementProgress(progress: ["switch_counter": 1], unlocked: ["switch_counter"]), owner: "owner-two")
        XCTAssertFalse(CardTitle.unlocked(in: s).contains(.manualSwitcher))
        ManualAchievementStore.shared.replace(ManualAchievementProgress(progress: ["switch_counter": 1], unlocked: ["switch_counter"]), owner: "owner-one")
        XCTAssertTrue(CardTitle.unlocked(in: s).contains(.manualSwitcher))
        XCTAssertEqual(ManualAchievement.allCases.filter(\.hidden).count, 2)
        XCTAssertEqual(Set(ManualAchievement.allCases.map(\.rewardTitle)).count, 8)
        XCTAssertTrue(ManualAchievement.allCases.allSatisfy { $0.rewardTitle.purchasePrice == nil })
    }
}
