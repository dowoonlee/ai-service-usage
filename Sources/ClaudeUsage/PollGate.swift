import Foundation

/// 폴링 루프가 공유하는 게이트.
///
/// `ViewModel.startPolling`은 원래부터 sleep/visibility를 확인했지만, 뷰 레벨 루프
/// (게시판·쪽지·랭킹·길드)는 확인하지 않아 패널을 닫아도 계속 서버를 두드렸다.
/// `NSPanel.orderOut`은 SwiftUI `onDisappear`를 부르지 않으므로 뷰가 살아 있는 한
/// 루프도 살아 있다 — 그래서 루프 쪽에서 명시적으로 게이트를 봐야 한다.
///
/// 상태는 ViewModel(패널 표시/시스템 sleep)과 BoardView(창 열림)가 갱신한다.
@MainActor
enum PollGate {
    /// App.swift가 panel show/orderOut 시 `ViewModel.panelIsVisible`을 통해 갱신.
    /// 기본값 true (panel 가시 가정), 메뉴바 모드는 `Settings.showMenuBar`로 별도 판단.
    static var panelIsVisible = true

    /// macOS sleep 진입 동안 true. didWake 시 false → polling 재개.
    static var isSystemSleeping = false

    /// 게시판 창이 떠 있는 동안 true — 메인 폴링 사이클의 unread 조회가 같은 `board`
    /// 엔드포인트를 중복 호출하지 않게 하는 플래그.
    static var boardViewIsOpen = false

    /// 지금 네트워크 폴링을 돌려도 되는지. macOS sleep 중이거나 가시 surface
    /// (패널/메뉴바)가 둘 다 없으면 false.
    static var shouldPoll: Bool {
        if isSystemSleeping { return false }
        return panelIsVisible || Settings.shared.showMenuBar
    }
}
