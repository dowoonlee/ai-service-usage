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

    /// 버튼 위 클릭이 실제로 버튼에 도달하는지 — 위 테스트가 놓칠 수 있는 통합 경로.
    func testButtonStillReceivesClicksThroughModifier() {
        let size = NSSize(width: 200, height: 80)
        let button = Button("탭") {}.frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: button.pauseAnimationsWhenHidden())
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        let hit = host.hitTest(NSPoint(x: size.width / 2, y: size.height / 2))
        XCTAssertNotNil(hit, "클릭이 아무 뷰에도 닿지 않는다")
        XCTAssertFalse(String(describing: type(of: hit!)).contains("Passthrough"),
                       "accessor 뷰가 버튼 대신 클릭을 받는다 — v0.17.27 회귀")
    }
}
