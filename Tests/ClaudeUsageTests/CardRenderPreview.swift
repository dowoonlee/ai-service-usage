import XCTest
import SwiftUI
@testable import ClaudeUsage

// 카드 프리뷰 렌더러 — 앱(GUI)을 띄우지 않고 트레이너 카드만 PNG로 뽑는다.
// 레포트 탭은 클릭으로만 열려서 카드 UI를 고칠 때마다 앱을 실행해야 했는데, 그 dev 실행이
// 실사용 UserDefaults/Keychain을 건드린다(CLAUDE.md 경고 참조). ImageRenderer로 뷰만 그리면
// 그 위험 없이 시각 확인이 된다.
//
//   CARD_OUT_DIR=/tmp/x swift test --filter CardRenderPreview
//
// 환경변수가 없으면 XCTSkip — CI·일반 `swift test`에는 영향이 없다.
@MainActor
final class CardRenderPreview: XCTestCase {
    func testRenderCardPNG() throws {
        let outDir = ProcessInfo.processInfo.environment["CARD_OUT_DIR"]
        try XCTSkipIf(outDir == nil, "CARD_OUT_DIR 미설정 — 프리뷰 전용")

        // 본토 + 클라우드 제도를 섞어 8개 — 신규 전용 스프라이트(Crown/Ore/Rose/Silver)가
        // 기존 보석과 한 줄에 같이 오는 최악 배치를 본다.
        let earned: Set<BadgeCategory> = [
            .standup, .claude, .heartbeat, .stash,
            .arenaWins, .guildTenure, .dailyRitual, .bugHunter,
        ]
        let badges = BadgeCategory.allCases.map {
            TrainerCardView.BadgeRow(category: $0, cleared: earned.contains($0), available: true)
        }
        let doneCollections: Set<PetCollection> = [.helloWorld, .npmInstall, .dns, .happyPath,
                                                   .emotionalSupport, .nodeModules, .oomKilled]
        let collections = PetCollection.allCases.map { ($0, doneCollections.contains($0)) }

        let stats = TrainerStats(
            totalSeconds: 152 * 3600 + 30 * 60,
            coinsTotalEarned: 48_210,
            totalPulls: 137,
            badgesCleared: earned.count * 2,
            badgesTotal: BadgeCategory.allCases.count * BadgeTier.allCases.count,
            collectionsComplete: doneCollections.count,
            collectionsTotal: PetCollection.allCases.count
        )

        let view = TrainerCardView(
            card: .default,
            trainerID: "04217",
            trainerName: "DEMO TRAINER",
            stats: stats,
            badges: badges,
            collections: collections
        )

        let renderer = ImageRenderer(content: view.frame(width: TrainerCardView.standardWidth))
        renderer.scale = 2
        guard let ns = renderer.nsImage,
              let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("렌더 실패")
        }
        let url = URL(fileURLWithPath: outDir!).appendingPathComponent("card_preview.png")
        try png.write(to: url)
        print("CARD_PNG=\(url.path) size=\(ns.size)")
    }
}
