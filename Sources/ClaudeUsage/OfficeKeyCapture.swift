import AppKit
import SwiftUI

/// 길드 사무실 WASD 조작용 키 감시 — `GuildOfficeView` 씬의 투명 배경으로 붙어, 뷰가 속한 창이
/// key window일 때 W/A/S/D의 keyDown/keyUp을 가로채 `OfficeSimulation.setControlKey`에 전달하고,
/// F keyDown은 `onEmote`(대사 + 액션)로 보낸다.
///
/// 가로채지 않는 경우 (이벤트를 그대로 통과시킨다):
///   - 다른 창의 이벤트 (`event.window !== window`) — 플로팅 패널·DM 창 등
///   - 텍스트 입력 중 (firstResponder가 NSTextView — 방명록·프리셋 이름·액자 문구)
///   - ⌘/⌃/⌥ 동반 (⌘W 닫기 같은 단축키)
/// 판정은 **물리 keyCode**(W=13 A=0 S=1 D=2 F=3)라 한글 입력 상태(ㅈ/ㅁ/ㄴ/ㅇ/ㄹ)에서도 동작한다.
/// 가로챈 이벤트는 nil을 반환해 SwiftUI 창의 "응답자 없음" 경고음을 막는다.
///
/// 키를 누른 채 창이 key를 잃으면 keyUp이 오지 않아 펫이 계속 걷는다 — `didResignKeyNotification`과
/// 뷰 제거 시점에 `onReleaseAll`로 눌림 상태를 전부 푼다.
///
/// **자동 포커스 가로채기** — SwiftUI는 창이 처음 표시될 때, 닫았다 다시 열 때, hide→unhide 때,
/// 시트가 열릴 때 창의 **첫 key view**(기하 순서)를 first responder로 만든다. 길드 탭에서는
/// "멤버 초대" 닉네임 입력란, 놀러가기 시트에서는 방명록 입력란이 그 첫 key view라 WASD가
/// 전부 거기로 타이핑됐다. `CaptureView`가 `acceptsFirstResponder`를 켜고 사무실 씬(입력란보다
/// 위)에 깔려 있으면 그 자동 포커스를 대신 받는다 — 입력란은 사용자가 클릭하거나 Tab으로
/// 넘어갈 때만 포커스된다. 투명(hitTest nil)이라 클릭으로는 포커스되지 않고, 포커스 링도 없다.
struct OfficeKeyCapture: NSViewRepresentable {
    let onKey: (OfficeSimulation.ControlKey, Bool) -> Void
    let onEmote: () -> Void
    let onReleaseAll: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onKey = onKey
        view.onEmote = onEmote
        view.onReleaseAll = onReleaseAll
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        view.onKey = onKey
        view.onEmote = onEmote
        view.onReleaseAll = onReleaseAll
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: ()) {
        view.uninstall()
    }

    final class CaptureView: NSView {
        var onKey: ((OfficeSimulation.ControlKey, Bool) -> Void)?
        var onEmote: (() -> Void)?
        var onReleaseAll: (() -> Void)?
        private static let emoteKeyCode: UInt16 = 3   // F
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            focusRingType = .none
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// first responder 후보 — 창의 첫 key view가 되어 SwiftUI의 자동 포커스(첫 TextField)를
        /// 대신 받는다. 키 처리 자체는 로컬 모니터가 하므로 이 뷰가 first responder인지 여부는
        /// WASD 동작과 무관하고, 입력란이 엉뚱하게 포커스되는 것만 막는다.
        override var acceptsFirstResponder: Bool { true }

        /// 투명 배경 — 마우스 히트테스트에서 빠져 가구 드래그·펫 탭을 가리지 않는다.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, let own = self.window, event.window === own,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(own.firstResponder is NSTextView) else { return event }
                if event.keyCode == Self.emoteKeyCode {
                    if event.type == .keyDown && !event.isARepeat { self.onEmote?() }
                    return nil   // keyUp도 삼켜 경고음 방지
                }
                guard let key = Self.controlKey(for: event.keyCode) else { return event }
                if event.type == .keyDown {
                    if !event.isARepeat { self.onKey?(key, true) }
                } else {
                    self.onKey?(key, false)
                }
                return nil
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onReleaseAll?() }
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            resignObserver = nil
            onReleaseAll?()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        /// 물리 키 → 방향. 레이아웃(한/영)과 무관하게 같은 자리의 키가 같은 방향이다.
        static func controlKey(for keyCode: UInt16) -> OfficeSimulation.ControlKey? {
            switch keyCode {
            case 13: return .up      // W
            case 0: return .left     // A
            case 1: return .down     // S
            case 2: return .right    // D
            default: return nil
            }
        }
    }
}
