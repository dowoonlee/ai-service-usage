import XCTest
@testable import ClaudeUsage

@MainActor
final class TrainerPlacementTests: SandboxedTestCase {
    func testPartyReplacementUpdatesBothAssignedChartsAndPreservesSlot() {
        let settings = Settings.shared
        let original = [PetKind.fox, .wolf, .bear].map { PetSelection(kind: $0, variant: 0) }
        settings.ownedPets = [.fox: .initial(), .wolf: .initial(), .bear: .initial(), .rabbit: .initial()]
        let id = settings.addPreset(name: "공유 파티", members: original)
        settings.assignPreset(id, to: .claude)
        settings.assignPreset(id, to: .codex)
        let rabbit = PetSelection(kind: .rabbit, variant: 0)
        XCTAssertFalse(settings.replacePartyMember(.wolf, in: id, with: original[0]))
        XCTAssertTrue(settings.replacePartyMember(.wolf, in: id, with: rabbit))
        for chart in [PetChartSource.claude, .codex] {
            XCTAssertEqual(settings.party(for: chart), [original[0], rabbit, original[2]])
        }
    }

    func testBattlePlacementRequiresAnExplicitReplacementAtCapacity() {
        let settings = Settings.shared
        let full: [PetKind] = [.fox, .wolf, .bear, .boar, .deer]
        settings.ownedPets = Dictionary(uniqueKeysWithValues: (full + [.rabbit]).map { ($0, .initial()) })
        settings.battleTeam = full
        XCTAssertFalse(settings.placeInBattleTeam(.rabbit, replacing: nil))
        XCTAssertFalse(settings.placeInBattleTeam(.wolf, replacing: .fox))
        XCTAssertTrue(settings.placeInBattleTeam(.rabbit, replacing: .bear))
        XCTAssertEqual(settings.battleTeam, [.fox, .wolf, .rabbit, .boar, .deer])
        settings.battleTeam = [.wolf]
        XCTAssertFalse(settings.placeInBattleTeam(.rabbit, replacing: .bear))
        XCTAssertTrue(settings.placeInBattleTeam(.rabbit, replacing: nil))
        XCTAssertTrue(settings.battleTeamKeepsEmptySlots)
    }
}
