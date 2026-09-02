import XCTest
@testable import ClaudeUsage

/// 창 가시성/활성 판정. 깃발 이펙트(`PetEffectOverlay.flag`)는 `windowIsActive`로 프레임 루프를
/// 멈추므로, "언제 활성인가"가 곧 그 연출이 CPU를 쓰는 조건이다.
@MainActor
final class WindowActivityTests: XCTestCase {

    /// 포커스가 없으면 활성이 아니다 — 보이기만 하는 뒤쪽 창에서 비싼 연출이 돌면 안 된다.
    func testVisibleButNotKeyIsNotActive() {
        let s = WindowVisibilityMonitor.state(isVisible: true, isMiniaturized: false,
                                              occluded: false, isKey: false)
        XCTAssertTrue(s.visible)
        XCTAssertFalse(s.active)
    }

    /// 보이고 + 키면 활성.
    func testVisibleAndKeyIsActive() {
        let s = WindowVisibilityMonitor.state(isVisible: true, isMiniaturized: false,
                                              occluded: false, isKey: true)
        XCTAssertTrue(s.visible)
        XCTAssertTrue(s.active)
    }

    /// 안 보이면 key 플래그가 남아 있어도 활성이 아니다 (닫히는 중/최소화/완전 가림).
    func testHiddenIsNeverActive() {
        for (visible, mini, occluded) in [(false, false, false), (true, true, false), (true, false, true)] {
            let s = WindowVisibilityMonitor.state(isVisible: visible, isMiniaturized: mini,
                                                  occluded: occluded, isKey: true)
            XCTAssertFalse(s.visible, "visible=\(visible) mini=\(mini) occluded=\(occluded)")
            XCTAssertFalse(s.active, "visible=\(visible) mini=\(mini) occluded=\(occluded)")
        }
    }
}
