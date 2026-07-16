import AppKit

/// 단일 인스턴스 윈도우 컨트롤러 공용 — `present()` 말미의 "activate → show → front" 3콤보를
/// 한 곳에 고정한다. `NSWindowController`가 이미 `window`/`showWindow`를 제공하므로 각 컨트롤러는
/// 채택만 하면 되고, 본문 3줄은 `bringToFront()` 한 줄로 줄어든다.
///
/// (LoginWindowController처럼 `showWindow`를 오버라이드하거나 GuildOffice 데모창처럼 커스텀
///  표시 시퀀스를 쓰는 컨트롤러는 이 패턴에 맞지 않아 제외한다. 이 3콤보가 흩어져 있어
///  LoginWindow가 `isReleasedWhenClosed` 설정을 빠뜨린 전례가 있었음 — 한 곳에 모아 재발 방지.)
@MainActor
protocol SingleWindowPresenting: AnyObject {
    var window: NSWindow? { get }
    func showWindow(_ sender: Any?)
}

extension SingleWindowPresenting {
    /// 앱을 앞으로 가져오고(LSUIElement라 필수) 창을 키윈도우로 표시.
    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
