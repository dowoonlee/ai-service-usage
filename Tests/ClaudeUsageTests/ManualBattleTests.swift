import XCTest
@testable import ClaudeUsage

final class ManualBattleTests: XCTestCase {
    private func pet(_ type: BattleType, variant: Int = 4) -> BattlePetSnapshot {
        BattlePetSnapshot(kind: PetKind.allCases.first { $0.battleType == type }!, variant: variant)
    }
    private func fixture(count: Int = 3) throws -> ManualBattleState {
        let a = Array([pet(.beast), pet(.warrior), pet(.mascot)].prefix(count))
        let b = Array([pet(.machine), pet(.arcane), pet(.chaos)].prefix(count))
        return try ManualBattleEngine.make(teamA: a, teamB: b, seed: 42,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
    }
    private func basic(_ state: ManualBattleState, _ side: Int) -> ManualCommand {
        .move(state.teams[side].fighters[state.teams[side].active].moves[0].id)
    }
    private func toughen(_ state: inout ManualBattleState) {
        for side in 0...1 { for slot in state.teams[side].fighters.indices {
            state.teams[side].fighters[slot].stats.hp = 1000
            state.teams[side].fighters[slot].hp = 1000
        } }
    }

    func testDeterminismAndLegalQueriesDoNotConsumeRandomness() throws {
        let initial = try fixture()
        let before = initial
        _ = ManualBattleEngine.legalCommands(initial, side: 0)
        _ = ManualBattleEngine.chooseAI(initial, side: 0)
        XCTAssertEqual(initial, before)
        XCTAssertEqual(try ManualBattleEngine.submit(initial, command: basic(initial, 0)),
                       try ManualBattleEngine.submit(initial, command: basic(initial, 0)))
    }

    func testInvalidCommandAndInvalidTeams() throws {
        let state = try fixture()
        XCTAssertThrowsError(try ManualBattleEngine.submit(state, command: .swap(0)))
        XCTAssertThrowsError(try ManualBattleEngine.submit(state, command: .move("fake")))
        XCTAssertThrowsError(try ManualBattleEngine.make(teamA: [pet(.beast), pet(.beast)], teamB: [pet(.machine), pet(.arcane)], seed: 1))
        XCTAssertThrowsError(try ManualBattleEngine.make(teamA: [], teamB: [], seed: 1))
    }

    func testSwitchRedirectsAttackAndClearsOnlyBuffs() throws {
        var state = try fixture()
        toughen(&state)
        state.teams[0].fighters[0].effects = [
            ManualEffect(id: "firewall", applied: 1, expires: 4, sequence: 1),
            ManualEffect(id: "mem_leak", applied: 1, expires: 4, sequence: 2)
        ]
        let result = try ManualBattleEngine.resolve(state, commands: [.swap(1), basic(state, 1)])
        XCTAssertEqual(result.teams[0].active, 1)
        XCTAssertEqual(result.teams[0].fighters[0].hp, 1000)
        XCTAssertLessThan(result.teams[0].fighters[1].hp, 1000)
        XCTAssertEqual(result.teams[0].fighters[0].effects.map(\.id), ["mem_leak"])
        XCTAssertTrue(result.teams[0].fighters[1].participated)
    }

    func testGuardReducesDamageButNotResidualAndCannotRepeat() throws {
        var state = try fixture()
        toughen(&state)
        state.turn = 2
        state.teams[0].fighters[0].effects = [ManualEffect(id: "mem_leak", applied: 1, expires: 4, sequence: 1)]
        let guarded = try ManualBattleEngine.resolve(state, commands: [.guardMove, basic(state, 1)])
        let attack = guarded.events.first { $0.side == 0 && $0.kind == "damage" }!
        let nominal = ManualBattleRules.damage(state.teams[1].fighters[0].moves[0], from: state.teams[1].fighters[0], to: state.teams[0].fighters[0], factor: 0.9)
        XCTAssertLessThanOrEqual(attack.amount!, nominal)
        XCTAssertEqual(guarded.teams[0].fighters[0].hp, 1000 - attack.amount! - 50)
        XCTAssertFalse(ManualBattleEngine.legalCommands(guarded, side: 0).contains(.guardMove))
    }

    func testFaintedActorDoesNotSpendPP() throws {
        var state = try fixture()
        let powerful = state.teams[1].fighters[0].moves[1]
        state.teams[0].fighters[0].stats.atk = 10000
        state.teams[0].fighters[0].stats.spd = 10000
        state.teams[1].fighters[0].hp = 1
        let result = try ManualBattleEngine.resolve(state, commands: [basic(state, 0), .move(powerful.id)])
        XCTAssertEqual(result.teams[1].fighters[0].pp[powerful.id], powerful.maxPP)
        XCTAssertEqual(result.events.filter { $0.side == 1 && $0.kind == "skillUsed" }.count, 0)
        XCTAssertNotEqual(result.teams[1].active, 0)
    }

    func testControlStartsNextTurnAndGrantsImmunity() throws {
        var state = try fixture()
        toughen(&state)
        state.teams[0].fighters[0].effects = [ManualEffect(id: "rate_limited", applied: 1, expires: 2, sequence: 1)]
        let move = state.teams[0].fighters[0].moves[1]
        state = try ManualBattleEngine.resolve(state, commands: [.move(move.id), basic(state, 1)])
        XCTAssertEqual(state.teams[0].fighters[0].pp[move.id], 2)
        state = try ManualBattleEngine.resolve(state, commands: [.move(move.id), basic(state, 1)])
        XCTAssertEqual(state.teams[0].fighters[0].pp[move.id], 2)
        XCTAssertEqual(state.teams[0].fighters[0].immuneUntil, 4)
        XCTAssertTrue(state.events.contains { $0.kind == "actionSkipped" })
        XCTAssertFalse(state.teams[0].fighters[0].effects.contains { ManualBattleRules.isControl($0.id) })
    }

    func testBenchDOTAndSimultaneousKnockout() throws {
        var state = try fixture(count: 1)
        state.turn = 2
        for side in 0...1 {
            state.teams[side].fighters[0].hp = 1
            state.teams[side].fighters[0].effects = [ManualEffect(id: "mem_leak", applied: 1, expires: 4, sequence: side)]
        }
        let end = try ManualBattleEngine.resolve(state, commands: [.guardMove, .guardMove])
        XCTAssertTrue(end.finished)
        XCTAssertNil(end.outcome?.winner)
        XCTAssertEqual(end.outcome?.reason, "knockout")
        var bench = try fixture()
        bench.turn = 2
        bench.teams[0].fighters[2].effects = [ManualEffect(id: "mem_leak", applied: 1, expires: 4, sequence: 1)]
        let hp = bench.teams[0].fighters[2].hp
        bench = try ManualBattleEngine.resolve(bench, commands: [.guardMove, .guardMove])
        XCTAssertLessThan(bench.teams[0].fighters[2].hp, hp)
    }

    func testAllBranchesAndHealingAvailability() throws {
        for type in BattleType.allCases {
            let a = ManualBattleRules.ultimate(type, branch: .original)
            let b = ManualBattleRules.ultimate(type, branch: .alternate)
            XCTAssertNotEqual(a.id, b.id)
            XCTAssertFalse(b.summary.isEmpty)
            let member = pet(type)
            var state = try ManualBattleEngine.make(teamA: [member], teamB: [pet(.warrior)],
                branchesA: [member.kind.rawValue: .alternate], seed: 12)
            toughen(&state)
            state.teams[0].charge = 10
            if type == .mascot {
                XCTAssertFalse(ManualBattleEngine.legalCommands(state, side: 0).contains(.move(b.id)))
                state.teams[0].fighters[0].hp = 300
            }
            let end = try ManualBattleEngine.resolve(state, commands: [.move(b.id), .guardMove])
            XCTAssertEqual(end.teams[0].charge, 0)
            XCTAssertTrue(end.teams[0].fighters[0].ultimateUsed)
        }
    }

    func testChargeCapAndUltimateDoesNotGenerateAttackCharge() throws {
        var state = try fixture()
        toughen(&state)
        state.teams[0].charge = 10
        let ult = state.teams[0].fighters[0].moves.last!
        let end = try ManualBattleEngine.resolve(state, commands: [.move(ult.id), basic(state, 1)])
        XCTAssertEqual(end.teams[0].charge, 1)
        XCTAssertEqual(end.teams[1].charge, 2)
        XCTAssertTrue(end.teams[1].fighters.dropFirst().allSatisfy { $0.hp < 1000 })
    }

    func testPPExhaustionAndNoChargeForGuardingOnly() throws {
        var state = try fixture()
        toughen(&state)
        let move = state.teams[0].fighters[0].moves[1]
        for _ in 0..<3 { state = try ManualBattleEngine.resolve(state, commands: [.move(move.id), basic(state, 1)]) }
        XCTAssertEqual(state.teams[0].fighters[0].pp[move.id], 0)
        XCTAssertFalse(ManualBattleEngine.legalCommands(state, side: 0).contains(.move(move.id)))
        let initial = try fixture()
        let end = try ManualBattleEngine.resolve(initial, commands: [.guardMove, .guardMove])
        XCTAssertEqual(end.teams.map(\.charge), [0, 0])
    }

    func testNoUnboundedGamesAndAIAlwaysChoosesLegalCommand() throws {
        for seed in 1...100 {
            var state = try ManualBattleEngine.make(teamA: [pet(.beast), pet(.warrior), pet(.mascot)],
                teamB: [pet(.machine), pet(.arcane), pet(.chaos)], seed: UInt64(seed))
            var steps = 0
            while !state.finished && steps < 100 {
                let command = try XCTUnwrap(ManualBattleEngine.chooseAI(state, side: 0))
                XCTAssertTrue(ManualBattleEngine.legalCommands(state, side: 0).contains(command))
                state = try ManualBattleEngine.submit(state, command: command)
                steps += 1
            }
            XCTAssertTrue(state.finished)
            XCTAssertLessThanOrEqual(state.turn, 40)
            XCTAssertTrue(state.teams.flatMap(\.fighters).allSatisfy { $0.hp >= 0 && $0.hp <= $0.stats.hp })
        }
    }

    func testPracticeMedalsRequireRainbowParticipationAndDeduplicate() throws {
        var state = try fixture()
        state.outcome = ManualOutcome(winner: 0, reason: "knockout")
        state.teams[0].fighters[0].participated = true
        state.teams[0].fighters[0].ultimateUsed = true
        state.teams[0].fighters[1].participated = false
        var archive = ManualPracticeArchive(state: state)
        archive.recordResult(); archive.recordResult()
        let record = try XCTUnwrap(archive.records[state.teams[0].fighters[0].pet.kind.rawValue])
        XCTAssertEqual(record.wins, 1)
        XCTAssertEqual(record.originalWins, 1)
        XCTAssertEqual(archive.records.count, 1)
        state.id = UUID(); state.tutorial = true
        archive.state = state; archive.recordResult()
        XCTAssertEqual(archive.records.values.first?.wins, 1)
        XCTAssertEqual(ManualMasteryRecord(wins: 100).title, "마스터")
    }

    func testExportServerParityVectors() throws {
        guard let path = ProcessInfo.processInfo.environment["MANUAL_PARITY_OUT"] else {
            throw XCTSkip("서버 파리티 fixture 출력 전용")
        }
        struct Fighter: Encodable {
            let hp: Int; let pp: [String: Int]; let effects: [ManualEffect]
            let immuneUntil: Int; let participated: Bool; let ultimateUsed: Bool
            init(_ f: ManualFighter) { hp = f.hp; pp = f.pp; effects = f.effects; immuneUntil = f.immuneUntil
                participated = f.participated; ultimateUsed = f.ultimateUsed }
        }
        struct Team: Encodable {
            let active: Int; let charge: Int; let lastGuard: Int; let lastSwitch: Int; let fighters: [Fighter]
            init(_ t: ManualTeam) { active = t.active; charge = t.charge; lastGuard = t.lastGuard; lastSwitch = t.lastSwitch
                fighters = t.fighters.map(Fighter.init) }
        }
        struct Projection: Encodable {
            let turn: Int; let revision: Int; let randomState: String; let teams: [Team]
            let outcome: ManualOutcome?; let committedAI: ManualCommand?; let effectSequence: Int
            let events: [ManualEvent]
            init(_ s: ManualBattleState, after eventID: Int) {
                turn = s.turn; revision = s.revision; randomState = s.randomState; teams = s.teams.map(Team.init)
                outcome = s.outcome; committedAI = s.committedAI; effectSequence = s.effectSequence
                events = Array(s.events.dropFirst(eventID))
            }
        }
        struct Step: Encodable { let command: ManualCommand; let expected: Projection }
        struct Vector: Encodable { let base: ManualBattleState; let initial: ManualBattleState; let steps: [Step] }
        var vectors: [Vector] = []
        for (index, type) in BattleType.allCases.enumerated() {
            for branch in ManualBranch.allCases {
                let lead = pet(type)
                let allies = [lead] + BattleType.allCases.filter { $0 != type }.prefix(4).map { pet($0) }
                let enemies = Array(allies.reversed())
                var state = try ManualBattleEngine.make(teamA: allies, teamB: enemies,
                    branchesA: [lead.kind.rawValue: branch], seed: UInt64(20261025 + index),
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index * 2 + (branch == .original ? 1 : 2)))!)
                let base = state
                // Exercise every ultimate, live effects, a switch and depleted resources, not only basic attacks.
                state.teams[0].charge = 10
                state.teams[0].fighters[0].hp = max(1, state.teams[0].fighters[0].hp / 2)
                state.teams[1].fighters[0].effects = [ManualEffect(id: "load_balancer", applied: 0, expires: 3, sequence: 1, shield: 20)]
                state.effectSequence = 1
                let initial = state
                var steps: [Step] = []
                let ultimate = state.teams[0].fighters[0].moves.last!
                state = try ManualBattleEngine.submit(state, command: .move(ultimate.id))
                steps.append(Step(command: .move(ultimate.id), expected: Projection(state, after: initial.events.count)))
                while !state.finished {
                    let legal = ManualBattleEngine.legalCommands(state, side: 0)
                    let command = steps.count == 1 && legal.contains(.swap(1)) ? ManualCommand.swap(1)
                        : try XCTUnwrap(ManualBattleEngine.chooseAI(state, side: 0))
                    let count = state.events.count
                    state = try ManualBattleEngine.submit(state, command: command)
                    steps.append(Step(command: command, expected: Projection(state, after: count)))
                }
                vectors.append(Vector(base: base, initial: initial, steps: steps))
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(vectors).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

@MainActor
final class ManualBattleSessionTests: SandboxedTestCase {
    private final class Server: ManualArenaTransport {
        var state: ManualBattleState
        var responses: [UUID: RankingAPI.ManualArenaResponse] = [:]
        var received: [UUID] = []
        var loseNextCommandResponse = false
        init() throws {
            let team = [PetKind.fox, .wolf, .scrapBot, .warrior, .lancer].map { BattlePetSnapshot(kind: $0, variant: 4) }
            state = try ManualBattleEngine.make(teamA: team, teamB: Array(team.reversed()), seed: 8)
        }
        func status(owner: String, hmac: String) async throws -> RankingAPI.ManualArenaStatus {
            RankingAPI.ManualArenaStatus(enabled: true, records: [:], active: nil)
        }
        func register(team: [BattlePetSnapshot], owner: String, hmac: String) async throws {}
        func send(_ pending: ManualPendingRequest, hmac: String) async throws -> RankingAPI.ManualArenaResponse {
            received.append(pending.id)
            if let response = responses[pending.id] { return response }
            if pending.action == "command" {
                let command = try JSONDecoder().decode(ManualCommand.self, from: Data(pending.commandJSON.utf8))
                state = try ManualBattleEngine.submit(state, command: command)
            }
            var visible = state
            visible.committedAI = nil; visible.seed = "0"; visible.randomState = "0"
            let response = RankingAPI.ManualArenaResponse(state: visible, eligibleKinds: [], expiresAt: "2099-01-01T00:00:00Z")
            responses[pending.id] = response
            if pending.action == "command" && loseNextCommandResponse {
                loseNextCommandResponse = false
                throw URLError(.timedOut)
            }
            return response
        }
    }
    private func drain(_ session: ManualBattleSession) async throws {
        for _ in 0..<1000 {
            if !session.busy { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("network task did not finish")
    }

    func testLostServerResponseSurvivesRestartAndRetriesSameRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = try Server()
        let session = ManualBattleSession(directory: dir, transport: server, credentials: { ("owner", "test-key") })
        session.startRemote(team: server.state.teams[0].fighters.map(\.pet))
        try await drain(session)
        XCTAssertTrue(session.isRemote)
        server.loseNextCommandResponse = true
        let move = try XCTUnwrap(session.state?.teams[0].fighters[0].moves[1])
        session.submit(.move(move.id))
        try await drain(session)
        XCTAssertTrue(session.hasPendingRequest)
        XCTAssertEqual(server.state.revision, 1)
        let id = try XCTUnwrap(session.archive.pendingRequest?.id)
        let resumed = ManualBattleSession(directory: dir, transport: server, credentials: { ("owner", "test-key") })
        resumed.retryPending()
        try await drain(resumed)
        XCTAssertFalse(resumed.hasPendingRequest)
        XCTAssertEqual(resumed.state?.revision, 1)
        XCTAssertEqual(server.state.revision, 1)
        XCTAssertEqual(Array(server.received.suffix(2)), [id, id])
        XCTAssertTrue(resumed.archive.records.isEmpty, "server battles must not mutate practice counters")
    }

    func testOfficialMedalCacheIsOwnerScoped() {
        ManualMasteryStore.shared.replace(["fox": ManualMasteryRecord(wins: 30)], owner: "one")
        XCTAssertEqual(ManualMasteryStore.shared.record(kind: .fox, owner: "one")?.title, "베테랑")
        XCTAssertNil(ManualMasteryStore.shared.record(kind: .fox, owner: "two"))
        XCTAssertNil(ManualMasteryStore.shared.record(kind: .wolf, owner: "one"))
    }

    func testRoundTripResumeAndFixedReplayDoNotRestorePPOrFarmRecords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ManualBattleSession(directory: dir)
        session.start(teamA: [BattlePetSnapshot(kind: .fox, variant: 4)], teamB: [BattlePetSnapshot(kind: .scrapBot, variant: 4)])
        let original = try XCTUnwrap(session.state)
        let move = original.teams[0].fighters[0].moves[1]
        session.submit(.move(move.id))
        XCTAssertNil(session.error)
        let resumed = ManualBattleSession(directory: dir)
        XCTAssertEqual(resumed.state, session.state)
        XCTAssertEqual(resumed.state?.teams[0].fighters[0].pp[move.id], 2)
        resumed.replaySameConditions()
        XCTAssertEqual(resumed.state?.id, original.id)
        XCTAssertEqual(resumed.state?.seed, original.seed)
    }

    func testUnreadableSaveIsNotOverwrittenByBranchPreferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("manual-arena-v1.json")
        try Data("broken".utf8).write(to: file)
        let session = ManualBattleSession(directory: dir)
        XCTAssertNotNil(session.error)
        session.setBranch(.alternate, kind: .fox, team: [.fox])
        XCTAssertEqual(try String(contentsOf: file), "broken")
        session.discard()
        XCTAssertNil(session.error)
    }

    func testBranchChoiceIsFrozenAndScopedToTeam() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let session = ManualBattleSession(directory: dir)
        session.setBranch(.alternate, kind: .fox, team: [.fox])
        session.start(teamA: [BattlePetSnapshot(kind: .fox, variant: 4)], teamB: [BattlePetSnapshot(kind: .scrapBot)])
        session.setBranch(.original, kind: .fox, team: [.fox])
        XCTAssertEqual(session.state?.teams[0].fighters[0].branch, .alternate)
        XCTAssertTrue(session.branches(for: [.fox, .wolf]).isEmpty)
    }
}
