import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 트레이너 카드 시각 검수.
///
/// 카드는 꾸미기 조합(배경 × 프레임 × 타이틀 × 액세서리 × 아바타)의 곱이라, 하나를 고치면 다른
/// 조합에서 깨지는 게 앱을 켜서 클릭해봐야 드러났다. 조합을 늘어놓고 한 번에 본다.
///
/// 특히 뱃지 줄 — 카드는 획득분만 그리므로 개수에 따라 dot 크기가 달라진다. 0개/소수/전부를
/// 각각 찍어서 "너무 작아 안 보이는" 지점을 잡는다.
///
///   bash scripts/render-previews.sh card
@MainActor
final class TrainerCardPreviews: SandboxedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { PreviewDemoState.seed() }
    }

    private func card(_ mutate: (inout TrainerCard) -> Void = { _ in }) -> TrainerCard {
        var c = TrainerCard.default
        c.avatar = PetSelection(kind: .fox, variant: 1)
        mutate(&c)
        return c
    }

    private func view(card: TrainerCard,
                      badges: [TrainerCardView.BadgeRow]? = nil,
                      collections: [(PetCollection, Bool)]? = nil,
                      stats: TrainerStats? = nil) -> some View {
        TrainerCardView(
            card: card,
            trainerID: "04217",
            trainerName: "데모트레이너",
            stats: stats ?? PreviewDemoState.trainerStats,
            badges: badges ?? PreviewDemoState.badgeRows,
            collections: collections ?? PreviewDemoState.collectionRows)
    }

    /// 기본형 — 진행도가 어중간한 상태(뱃지 일부, 컬렉션 절반)의 표준 카드.
    func testRenderDefaultCard() throws {
        try PreviewRenderer.render(view(card: card()),
                                   section: "트레이너 카드", title: "1-기본",
                                   note: "중반 진행도. 뱃지 줄과 컬렉션 dot이 서로 안 밀리는지.",
                                   width: TrainerCardView.standardWidth)
    }

    /// 뱃지 개수에 따른 dot 크기 변화. 카드가 획득분만 그리는 이유가 여기 있다 —
    /// 미획득까지 넣으면 dot이 줄어들어 획득분이 안 보였다.
    func testRenderBadgeDensityRange() throws {
        let cases: [(String, Int)] = [
            ("2-뱃지-0개", 0),
            ("2-뱃지-소수", 3),
            ("2-뱃지-절반", BadgeCategory.allCases.count / 2),
            ("2-뱃지-전부", BadgeCategory.allCases.count),
        ]
        for (title, count) in cases {
            let badges = BadgeCategory.allCases.enumerated().map { i, category in
                TrainerCardView.BadgeRow(category: category, cleared: i < count, available: true)
            }
            try PreviewRenderer.render(
                view(card: card(), badges: badges),
                section: "트레이너 카드", title: title,
                note: "획득 \(count)개. dot이 개수 반비례로 작아지므로 전부일 때 식별되는지 본다.",
                width: TrainerCardView.standardWidth)
        }
    }

    /// 배경 전종(테마 4 + 컬렉션 19). 컬렉션 배경은 `accentColor`를 그대로 쓰는데 밝은 색이
    /// 섞여 있어, 흰 텍스트나 뱃지가 묻히는 조합이 나오는지 전부 훑는다.
    func testRenderAllBackgrounds() throws {
        let backgrounds: [TrainerBackground] =
            PetTheme.allCases.map { .theme($0) }
            + PetCollection.allCases.map { .collection($0.rawValue) }
        for background in backgrounds {
            let slug = background.displayName
            try PreviewRenderer.render(
                view(card: card { $0.background = background }),
                section: "트레이너 카드 배경", title: "bg-\(slug)",
                note: "배경 \(slug) — 텍스트·뱃지 대비가 유지되는지.",
                width: TrainerCardView.standardWidth)
        }
    }

    /// 프레임 전종.
    func testRenderAllFrames() throws {
        for frame in CardFrame.allCases {
            try PreviewRenderer.render(
                view(card: card { $0.frame = frame }),
                section: "트레이너 카드 프레임", title: "frame-\(frame.rawValue)",
                note: "프레임 \(frame.rawValue) — 모서리에서 콘텐츠가 잘리지 않는지.",
                width: TrainerCardView.standardWidth)
        }
    }

    /// 타이틀 전종 — 긴 한글 타이틀이 줄바꿈되거나 넘치는지.
    func testRenderAllTitles() throws {
        for title in CardTitle.allCases {
            try PreviewRenderer.render(
                view(card: card { $0.title = title }),
                section: "트레이너 카드 타이틀", title: "title-\(title.rawValue)",
                note: "타이틀 \(title.rawValue) — 폭 초과 시 줄바꿈/생략 처리.",
                width: TrainerCardView.standardWidth)
        }
    }

    /// 액세서리 전종. 아바타 위에 얹히는 것이라 펫 종류에 따라 위치가 어긋날 수 있어
    /// 대표 펫 두 종(작은 펫 / 큰 펫)으로 각각 본다.
    func testRenderAccessoriesOnTwoAvatars() throws {
        for accessory in CardAccessory.allCases {
            for (petLabel, kind) in [("소형", PetKind.fox), ("대형", PetKind.heroKnight)] {
                try PreviewRenderer.render(
                    view(card: card {
                        $0.avatar = PetSelection(kind: kind, variant: 0)
                        $0.accessory = accessory
                        $0.accessoryTransform = .default
                    }),
                    section: "트레이너 카드 액세서리", title: "acc-\(accessory.rawValue)-\(petLabel)",
                    note: "\(accessory.rawValue) on \(kind.rawValue) — 기본 위치가 아바타에 맞는지.",
                    width: TrainerCardView.standardWidth)
            }
        }
    }
}
