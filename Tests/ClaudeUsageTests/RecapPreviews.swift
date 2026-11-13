import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 연말 리캡 장면과 내레이션의 시각 검수.
/// 장면마다 연출이 무르익은 시점 하나를 고정해 찍는다(그리는 중 생기는 파티클은 빠짐).
///
///   bash scripts/render-previews.sh recap
@MainActor
final class RecapPreviews: SandboxedTestCase {

    /// 활동이 고르게 있는 반년치 가짜 사용량 + 중반 게임 진행도.
    private func demoFacts() -> RecapFacts {
        let days = 186
        let daily = (0..<days).map { i -> Double in
            let wave = 40 + 30 * sin(Double(i) / 9) + Double(i) * 0.4
            return i % 11 == 5 ? 0 : max(0, wave)
        }
        let usage = RecapUsageFacts(
            firstDay: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date())),
            daily: daily, activeDays: daily.filter { $0 > 0 }.count, longestStreak: 17, currentStreak: 17,
            peakWeekDay: nil, hours: (0..<24).map { h in h >= 9 && h <= 19 ? Double(20 + h) : 2 },
            weekdays: [50, 40, 42, 45, 38, 8, 5],
            claudeWeeklyGauges: 9.8, claudeWeeklyPeak: .init(pct: 88, at: Date()), claudeFiveHourWallHits: 1,
            codexWeeklyGauges: 6.1, codexWeeklyPeak: .init(pct: 97, at: Date()),
            cursorUSD: 1137.6, cursorTopModel: "gpt-5.5-high", cursorFirst: Date(), cursorLast: Date())
        let game = RecapGameFacts(
            pulls: 1802, speciesOwned: 195, rosterSize: 195, topDuplicate: (.goblin, 23), shinySpecies: 173,
            prestigeKinds: [.warrior],
            partners: [.init(kind: .ninjaFrog, hours: 1835), .init(kind: .kingPig, hours: 1738), .init(kind: .knightM, hours: 1541)],
            narrator: PetSelection(kind: .ninjaFrog, variant: 0),
            collectionsCompleted: 19, collectionsTotal: 19, firstCollectionAt: nil, lastCollectionAt: nil,
            badges: 70, masteredRegions: 7, arenaWins: 177, arenaBestRating: 1429, arenaBestRank: 1,
            quizCorrect: 144, wellnessResponded: 208, nightOwlHours: 281, prBonuses: 203,
            guildName: "AI혁신팀", isGuildLeader: true, nickname: "trainer",
            coinsBySource: ["claude": 8674, "codex": 22140, "cursor": 5642], events: [])
        return RecapFacts(usage: usage, game: game)
    }

    func testRenderScenes() throws {
        _ = try PreviewRenderer.requireOutputDir()
        let facts = demoFacts()
        // 장면별로 연출이 다 나온 시점.
        let moments: [String: Double] = ["boot": 5.5, "yearline": 6, "gauges": 7.5, "partner": 5]
        let size = CGSize(width: RecapCanvasSize.width * RecapCanvasSize.scale,
                          height: RecapCanvasSize.height * RecapCanvasSize.scale)
        let probe = RecapPlayer(facts: facts, scenes: RecapScenes.all)
        for (i, scene) in probe.scenes.enumerated() {
            let player = RecapPlayer(facts: facts, scenes: RecapScenes.all)
            player.go(i)
            player.freeze(at: moments[scene.id] ?? 4)
            try PreviewRenderer.renderInWindow(
                RecapStoryView(player: player), size: size,
                section: "리캡", title: "\(i + 1). \(scene.id)",
                note: moments[scene.id] == nil ? "연출 이식 전 자리(숫자 장면)" : "t=\(moments[scene.id]!)s")
        }
    }

    func testRenderEmptyHistoryNarration() throws {
        _ = try PreviewRenderer.requireOutputDir()
        let facts = RecapFacts(usage: .compute(claude: [], codex: [], cursor: [], now: Date()),
                               game: .gather(events: []))
        let player = RecapPlayer(facts: facts, scenes: RecapScenes.all)
        for (index, scene) in player.scenes.enumerated() {
            player.go(index)
            player.freeze(at: 5)
            try PreviewRenderer.renderInWindow(
                RecapStoryView(player: player),
                size: CGSize(width: RecapCanvasSize.width * RecapCanvasSize.scale,
                             height: RecapCanvasSize.height * RecapCanvasSize.scale),
                section: "리캡", title: "신규 사용자. \(scene.id)", note: "빈 기록에서도 내레이션 표시")
        }
    }

    func testRenderClaudeNarration() throws {
        _ = try PreviewRenderer.requireOutputDir()
        guard let path = ProcessInfo.processInfo.environment["RECAP_CLAUDE_SAMPLES"] else {
            throw XCTSkip("실제 Claude E2E 샘플 미지정")
        }
        struct Sample: Decodable { let persona: String; let lines: [String: String] }
        let samples = try JSONDecoder().decode([String: Sample].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        for (kind, sample) in samples.sorted(by: { $0.key < $1.key }) {
            var facts = demoFacts()
            facts.game.narrator = PetSelection(kind: try XCTUnwrap(PetKind(rawValue: kind)), variant: 0)
            let player = RecapPlayer(facts: facts, scenes: RecapScenes.all)
            for (index, scene) in player.scenes.enumerated() {
                player.go(index)
                player.freeze(at: 6)
                try PreviewRenderer.renderInWindow(
                    RecapStoryView(player: player, generatedNarration: sample.lines),
                    size: CGSize(width: RecapCanvasSize.width * RecapCanvasSize.scale,
                                 height: RecapCanvasSize.height * RecapCanvasSize.scale),
                    section: "Claude 리캡", title: "\(kind)-\(scene.id)", note: sample.persona)
            }
        }
    }

    func testRenderNarrationLoadingAndSavedStates() async throws {
        _ = try PreviewRenderer.requireOutputDir()
        let size = CGSize(width: 480, height: 772)
        let facts = demoFacts()
        try PreviewRenderer.renderInWindow(RecapExperienceView(facts: facts), size: size,
            section: "Claude 리캡", title: "미등록 안내", note: "기본 대사와 랭킹 등록 안내")
        Settings.shared.rankingDeviceID = "preview-account"
        XCTAssertTrue(Keychain.saveRankingHmacKey("preview-key"))
        let loading = RecapNarrationLoader(request: { _, _, _, _, _ in
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return .init(status: .pending, row: nil, retryAfter: 3)
        })
        try PreviewRenderer.renderInWindow(RecapExperienceView(facts: facts, loader: loading), size: size,
            section: "Claude 리캡", title: "첫 생성 대기", note: "대기 중 안내와 창 크기")
        let row = RecapNarrationRow(year: 2026, petKind: facts.game.narrator.kind.rawValue,
            generatedAt: Date(), persona: "절제되고 은밀한 닌자 개구리",
            lines: Dictionary(uniqueKeysWithValues: RecapNarration.sceneIDs.map { ($0, "쉿, 기록 속 기척을 따라 조용히 걸어보겠다. 준비됐나…개굴.") }))
        let saved = RecapNarrationLoader(request: { _, _, _, _, _ in .init(status: .ready, row: row, retryAfter: nil) })
        await saved.load(facts: facts)
        try PreviewRenderer.renderInWindow(RecapExperienceView(facts: facts, loader: saved), size: size,
            section: "Claude 리캡", title: "저장된 대사", note: "생성 시점 안내 footer")
    }
}
