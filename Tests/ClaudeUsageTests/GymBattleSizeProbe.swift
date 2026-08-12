import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 대련 시트 레이아웃 진단 — 재생 뷰가 시트 `minHeight` 안에 들어가는지 실측한다.
///
/// 대련창은 클릭으로만 열려서 잘림을 눈으로 확인하기 어렵다. `ImageRenderer`로 크기만 재면
/// 앱 없이 검증된다. 렌더 크기는 폰트·환경에 따라 미세하게 흔들릴 수 있어 CI에서 상시 돌리진
/// 않는다 — `SIZE_PROBE=1`일 때만 실행:
///
///   SIZE_PROBE=1 swift test --filter GymBattleSizeProbe
///
/// 대련창에 컴포넌트를 추가한 뒤 이 값이 `sheetMinHeight`를 넘으면, 넘친 만큼은 내부 스크롤로
/// 밀리므로 minHeight를 올릴지 판단하면 된다.
@MainActor
final class GymBattleSizeProbe: XCTestCase {
    /// GymBattleView의 `.frame(minHeight:)`와 같은 값 — 바꾸면 여기도 맞춘다.
    private let sheetMinHeight: CGFloat = 540
    /// 시트 폭(430) − 좌우 padding(16×2).
    private let contentWidth: CGFloat = 430 - 32
    /// 재생 뷰를 뺀 고정 크롬(header + footer + VStack spacing + padding 32).
    ///
    /// minHeight를 넣기 **전** 로딩 상태 시트를 실측해 얻은 값(408) − placeholder(176) = 232.
    /// 지금 같은 방식으로 다시 재면 minHeight가 적용된 540에서 역산돼 순환이 되므로 상수로 고정한다.
    private let chromeHeight: CGFloat = 232

    func testReplayFitsInSheetMinHeight() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SIZE_PROBE"] == nil, "진단 전용")

        let a = [PetKind.fox, .wolf, .bear].map { BattlePetSnapshot(kind: $0, variant: 1) }
        let b = [PetKind.slime, .goblin, .bat].map { BattlePetSnapshot(kind: $0, variant: 0) }
        let result = BattleEngine.simulate(teamA: BattleTeam(a), teamB: BattleTeam(b), seed: 42)

        let replay = BattleReplayView(aSnaps: a, bSnaps: b, result: result) { EmptyView() }
            .frame(width: contentWidth)
        let renderer = ImageRenderer(content: replay)
        renderer.scale = 1
        let replayHeight = renderer.nsImage?.size.height ?? 0

        let needed = chromeHeight + replayHeight
        print("PROBE replay=\(replayHeight) chrome=\(chromeHeight) needed=\(needed) minHeight=\(sheetMinHeight)")
        XCTAssertLessThanOrEqual(needed, sheetMinHeight,
                                 "재생 기본 상태가 시트 minHeight를 넘는다 — 스크롤 없이 보이려면 minHeight를 올려야 함")
    }
}
