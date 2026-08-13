import XCTest
import SwiftUI
import AppKit
@testable import ClaudeUsage

/// `pauseAnimationsWhenHidden()`이 클릭을 삼키지 않는지.
///
/// v0.17.27에서 실제로 삼켰다. 창을 찾으려고 `NSViewRepresentable`을 `.background`로 깔았는데,
/// SwiftUI의 `.allowsHitTesting(false)`는 SwiftUI 레이어에만 적용되고 AppKit 자식 뷰의 `hitTest`는
/// 그대로 살아 있다. 콘텐츠 크기만큼 늘어난 투명 NSView가 패널 전체의 버튼 클릭을 가로챘다.
///
/// 눈에 보이는 증상(버튼이 안 눌린다)은 스크린샷으로도 안 잡히고 렌더 프리뷰로도 안 잡힌다 —
/// 그림은 멀쩡하기 때문이다. hitTest는 코드로 확인할 수 있으므로 여기서 못 박는다.
@MainActor
final class WindowVisibilityTests: XCTestCase {

    private func allSubviews(_ root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap(allSubviews)
    }

    /// modifier가 심는 accessor 뷰는 어떤 지점에서도 hitTest에 걸리면 안 된다.
    func testAccessorViewNeverTakesHits() {
        let host = NSHostingView(rootView: Text("hello").pauseAnimationsWhenHidden())
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.layoutSubtreeIfNeeded()

        let accessors = allSubviews(host).filter {
            String(describing: type(of: $0)).contains("Passthrough")
        }
        XCTAssertFalse(accessors.isEmpty,
                       "accessor 뷰를 찾지 못했다 — 구현이 바뀌었다면 이 테스트도 같이 고쳐야 한다")
        for view in accessors {
            // hitTest는 superview 좌표계를 받는다. 뷰 자신의 중심을 그 좌표계로 환산해 넣는다.
            let center = NSPoint(x: view.frame.midX, y: view.frame.midY)
            XCTAssertNil(view.hitTest(center), "accessor가 클릭을 가로챈다")
        }
    }

    // "버튼 위를 클릭하면 버튼이 받는다"는 통합 테스트도 시도했으나 뺐다. 두 가지 이유다:
    //   1. 회귀를 못 잡는다. 버그가 있는 코드에서도 통과했다 — 클릭을 가로챈 SwiftUI 내부 뷰의
    //      타입 이름을 특정할 수 없어 "누가 받았는지"를 판정하지 못했다.
    //   2. CI에서 불안정하다. 창에 붙지 않은 NSHostingView는 headless 러너에서 hitTest가 통째로
    //      nil을 반환해, 로컬에서만 통과하고 CI에서 깨졌다.
    // 위 accessor 테스트가 원인 지점을 직접 겨냥하고 실제로 회귀에서 실패하므로 그것으로 충분하다.
}
