import XCTest
@testable import ClaudeUsage

@MainActor
final class RecapNarrationTests: SandboxedTestCase {
    private func emptyFacts() -> RecapFacts {
        var game = RecapGameFacts.gather(events: [])
        // 신규 설정에도 기본 펫이 있으므로, 수집 기록이 전혀 없는 경계를 따로 만든다.
        game.pulls = 0
        game.speciesOwned = 0
        return RecapFacts(usage: .compute(claude: [], codex: [], cursor: [], now: Date()), game: game)
    }

    func testEverySceneHasReadableNarrationWithoutHistory() {
        let facts = emptyFacts()
        for scene in RecapScenes.all {
            let text = scene.narration(facts)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scene.id)
            XCTAssertNotEqual(text, "…", scene.id)
            XCTAssertLessThan(text.count, 110, "대사창에서 읽을 수 있는 짧은 문구: \(scene.id)")
        }
        let player = RecapPlayer(facts: facts, scenes: RecapScenes.all)
        XCTAssertEqual(player.scenes.map(\.id), ["boot", "life", "ending"])
        XCTAssertTrue(player.scene.narration(facts).contains("아직 사용 기록은 적지만"))
        player.go(2)
        XCTAssertTrue(player.scene.narration(facts).contains("첫 페이지"))
    }

    func testFactsSelectNarrationWithoutEventLogs() {
        var facts = emptyFacts()
        facts.usage.activeDays = 42
        facts.usage.longestStreak = 12
        facts.game.badges = 7
        facts.game.collectionsCompleted = 3
        facts.game.arenaWins = 21
        facts.game.shinySpecies = 4
        XCTAssertTrue(RecapNarration.text(for: "grass", facts: facts).contains("12일"))
        XCTAssertTrue(RecapNarration.text(for: "gym", facts: facts).contains("뱃지는 7개"))
        XCTAssertTrue(RecapNarration.text(for: "gym", facts: facts).contains("컬렉션은 3개"))
        XCTAssertTrue(RecapNarration.text(for: "arena", facts: facts).contains("누적 21승"))
        XCTAssertTrue(RecapNarration.text(for: "gacha", facts: facts).contains("4종"))
        XCTAssertFalse(RecapNarration.text(for: "boot", facts: facts).contains("아직 사용 기록은 적지만"))
    }

    func testGoldenHourAndMissingPartnerFallbacks() {
        var facts = emptyFacts()
        XCTAssertTrue(RecapNarration.text(for: "golden", facts: facts).contains("기록이 없네"))
        XCTAssertFalse(RecapNarration.text(for: "partner", facts: facts).isEmpty)
        facts.usage.hours[23] = 10
        XCTAssertTrue(RecapNarration.text(for: "golden", facts: facts).contains("잠은 챙기자"))
        facts.usage.hours[14] = 20
        XCTAssertTrue(RecapNarration.text(for: "golden", facts: facts).contains("14시"))
        XCTAssertTrue(RecapNarration.text(for: "golden", facts: facts).contains("따로 집계"))
    }
}
