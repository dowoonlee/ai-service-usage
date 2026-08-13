import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 대련 시트 레이아웃 가드 — 재생 뷰가 시트 안에 들어가는지 실측한다.
///
/// 대련창은 클릭으로만 열려서 잘림을 눈으로 확인하기 어렵다. 최근 세로 잘림 버그가 연달아
/// 세 건(#223/#224/#226) 났는데, 정작 그걸 잡을 이 프로브는 `SIZE_PROBE=1`이 없으면 skip이라
/// **CI에서 한 번도 실행되지 않았다**. 이제 항상 돈다.
///
/// 절대 임계(“540 이하”) 대신 **기준선 대비 증가율**로 판정하는 이유: 렌더 높이는 폰트·환경에
/// 따라 몇 px 흔들리는데, 현재 값(513)과 시트 minHeight(540) 사이 여유가 27px(5%)뿐이라
/// 절대 임계로 CI에 걸면 환경 차이만으로 빨간불이 뜬다. 증가율 판정은 그 흔들림을 흡수하면서
/// "컴포넌트를 추가해 콘텐츠가 유의미하게 길어진" 회귀는 그대로 잡는다.
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

    /// 2026-08 실측 기준선(needed = chrome 232 + replay 281). 의도적으로 레이아웃을 바꿨다면
    /// 새 실측값으로 갱신할 것 — 그때 이 숫자를 고치는 행위가 곧 "높이가 늘어난 걸 인지했다"는 기록이다.
    private let baselineNeeded: CGFloat = 513
    /// 허용 증가율. 폰트·환경 차이는 통상 1~2%라 10%면 오탐 없이 회귀만 잡힌다.
    private let tolerance: CGFloat = 1.10

    func testReplayFitsInSheetMinHeight() throws {
        let a = [PetKind.fox, .wolf, .bear].map { BattlePetSnapshot(kind: $0, variant: 1) }
        let b = [PetKind.slime, .goblin, .bat].map { BattlePetSnapshot(kind: $0, variant: 0) }
        let result = BattleEngine.simulate(teamA: BattleTeam(a), teamB: BattleTeam(b), seed: 42)

        let replay = BattleReplayView(aSnaps: a, bSnaps: b, result: result) { EmptyView() }
            .frame(width: contentWidth)
        let renderer = ImageRenderer(content: replay)
        renderer.scale = 1
        let replayHeight = renderer.nsImage?.size.height ?? 0

        let needed = chromeHeight + replayHeight
        print("PROBE replay=\(replayHeight) chrome=\(chromeHeight) needed=\(needed) "
              + "baseline=\(baselineNeeded) minHeight=\(sheetMinHeight)")

        XCTAssertGreaterThan(replayHeight, 0, "재생 뷰가 렌더되지 않았다")
        XCTAssertLessThan(needed, baselineNeeded * tolerance,
                          "재생 뷰 높이가 기준선(\(baselineNeeded))보다 10% 넘게 늘었다 — "
                          + "시트 minHeight(\(sheetMinHeight))를 넘겨 아래가 잘릴 수 있다. "
                          + "의도한 변경이면 baselineNeeded를 새 실측값으로 갱신할 것.")
    }
}
