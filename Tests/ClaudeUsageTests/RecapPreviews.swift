import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 연말 리캡 장면 — 공개 전까지 앱에서 숨겨져 있어 눈으로 확인할 길이 이것뿐이다.
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
}
