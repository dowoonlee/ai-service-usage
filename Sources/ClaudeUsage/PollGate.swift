import Foundation

/// sync가 받아온 랭킹 섹션 — `.rankingSynced` 알림의 object.
/// 리더보드와 테넌트 공지는 같은 화면이 함께 쓰므로 한 묶음으로 전달한다.
final class RankingSyncPayload: NSObject, @unchecked Sendable {
    let leaderboard: RankingAPI.LeaderboardResponse
    let tenantAnnouncements: [RankingAPI.TenantAnnouncementRow]
    init(leaderboard: RankingAPI.LeaderboardResponse,
         tenantAnnouncements: [RankingAPI.TenantAnnouncementRow]) {
        self.leaderboard = leaderboard
        self.tenantAnnouncements = tenantAnnouncements
    }
}

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

    /// 게시판 창이 떠 있는 동안 true. 게시판 폴링은 이 플래그가 참일 때만 돈다 —
    /// 쪽지·게시판은 사용자가 열었을 때만 서버를 조회한다(배경 주기 폴링 없음).
    ///
    /// 갱신 주체는 `BoardWindowController`의 `present()` / `windowWillClose`다.
    /// SwiftUI `onAppear`/`onDisappear`에 맡기지 않는 이유는 위 주석과 같다 —
    /// `isReleasedWhenClosed = false`로 창을 재사용하면 닫아도 `onDisappear`가 오지 않는다.
    static var boardViewIsOpen = false

    /// 쪽지 창이 떠 있는 동안 true. 인박스 갱신 루프가 이 값을 본다.
    /// 갱신 주체는 `DMWindowController`의 `present()` / `windowWillClose`.
    static var dmViewIsOpen = false

    /// 랭킹 화면이 보이는 동안 true. 랭킹은 별도 창이 아니라 메인 패널의 탭이라
    /// `RankingView`의 onAppear/onDisappear가 갱신한다(탭 전환은 뷰가 실제로 사라져 신뢰 가능).
    static var rankingViewIsOpen = false

    /// 지금 sync가 받아와야 할 화면 목록 — 열린 창이 없으면 배지만 받는다.
    static var openSurfaces: [String] {
        var out: [String] = []
        if dmViewIsOpen { out.append("inbox") }
        if boardViewIsOpen { out.append("board") }
        if rankingViewIsOpen { out.append("ranking") }
        return out
    }

    /// 지금 네트워크 폴링을 돌려도 되는지. macOS sleep 중이거나 가시 surface
    /// (패널/메뉴바)가 둘 다 없으면 false.
    static var shouldPoll: Bool {
        if isSystemSleeping { return false }
        return panelIsVisible || Settings.shared.showMenuBar
    }
}
