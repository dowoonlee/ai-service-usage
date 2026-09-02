import SwiftUI
import AppKit

// 창 가시성 → SwiftUI 프레임 루프 제어.
//
// 왜 필요한가: 이 앱의 창들은 `isReleasedWhenClosed = false` + 싱글턴 컨트롤러라, 닫아도
// `orderOut`될 뿐 NSHostingController와 SwiftUI 뷰 트리가 그대로 남는다. 그 안의
// `TimelineView(.animation)`은 화면에 없어도 계속 tick하므로, **아무도 보지 않는 화면을
// 초당 60~120회 다시 그리는** 상태가 된다. 실측에서 닫힌 가챠 창 하나가 CPU 50%를 먹고 있었고,
// 메인 스레드 샘플의 절반이 `NSHostingView.layout` → AttributeGraph 갱신이었다.
//
// 해법은 창이 보이지 않을 때 프레임 루프를 멈추는 것이다. 뷰가 창을 직접 알 수는 없으므로
// 창 루트에서 `.pauseAnimationsWhenHidden()`으로 한 번 감싸고, 각 `TimelineView`가
// `@Environment(\.windowIsVisible)`을 읽어 `paused:`에 넘긴다.
//
//     NSHostingController(rootView: GachaView().pauseAnimationsWhenHidden())
//
//     @Environment(\.windowIsVisible) private var windowIsVisible
//     TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) { ... }
//
// 뷰 트리를 통째로 버리는 방법(닫을 때 contentViewController = nil)도 있지만, @State로 들고 있는
// 탭 선택·스크롤 위치가 함께 날아가고 다시 열 때 재구성 비용이 든다. 멈추기만 하면 상태는 남는다.

private struct WindowIsVisibleKey: EnvironmentKey {
    /// 창에 붙지 않은 컨텍스트(프리뷰 렌더러의 오프스크린 호스팅, 테스트)에서는 "보인다"로 둔다.
    /// 기본값을 false로 하면 그런 경로에서 애니메이션이 아예 안 돌아 캡처가 빈 프레임이 된다.
    static let defaultValue = true
}

/// 창이 **활성(key)** 인지. 보이기만 하면 되는 애니메이션과 달리, 비싼 연출은 사용자가 실제로
/// 그 창을 보고 있을 때만 돌리려고 쓴다 (예: 깃발 이펙트의 Canvas 파동).
private struct WindowIsActiveKey: EnvironmentKey {
    /// `windowIsVisible`과 같은 이유로 기본값 true — 창에 붙지 않은 프리뷰/테스트에서도 돌아야 한다.
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 이 뷰가 속한 창이 화면에 보이는지. 닫힘·최소화·완전 가림이면 false.
    var windowIsVisible: Bool {
        get { self[WindowIsVisibleKey.self] }
        set { self[WindowIsVisibleKey.self] = newValue }
    }

    /// 이 뷰가 속한 창이 키 윈도우(사용자가 지금 조작 중인 창)인지. 다른 앱/다른 창으로 포커스가
    /// 넘어가면 false — `windowIsVisible`보다 엄격하다(보이지만 뒤에 있는 창도 false).
    var windowIsActive: Bool {
        get { self[WindowIsActiveKey.self] }
        set { self[WindowIsActiveKey.self] = newValue }
    }
}

/// 붙어 있는 `NSWindow`의 가시성을 관찰해 발행한다.
@MainActor
final class WindowVisibilityMonitor: ObservableObject {
    @Published private(set) var isVisible = true
    /// 키 윈도우 여부. 앱이 백그라운드로 가면 창이 key를 잃으므로 앱 비활성도 여기서 같이 잡힌다.
    @Published private(set) var isActive = true

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// 창이 보이지 않게 되는 경로. `willClose`는 알림 시점에 아직 `isVisible == true`라
    /// 별도로 false를 강제해야 한다(그래서 상태 계산과 분리해 둔다).
    private static let hidingNotifications: [Notification.Name] = [
        NSWindow.willCloseNotification,
        NSWindow.didMiniaturizeNotification,
    ]

    /// 다시 보이게 되거나 가림 상태가 바뀌는 경로.
    private static let showingNotifications: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.didBecomeKeyNotification,
        NSWindow.didExposeNotification,
        // key를 잃는 것은 가시성과 무관하지만 `isActive` 갱신에 필요하다. recompute가 둘 다 계산한다.
        NSWindow.didResignKeyNotification,
    ]

    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        detach()
        self.window = window
        guard let window else { return }

        let center = NotificationCenter.default
        for name in Self.hidingNotifications {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                Task { @MainActor [weak self] in
                    self?.isVisible = false
                    self?.isActive = false
                }
            })
        }
        for name in Self.showingNotifications {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.recompute() }
            })
        }
        recompute()
    }

    private func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        window = nil
    }

    /// 창 상태 → (보임, 활성). AppKit 없이 단언할 수 있게 순수 함수로 분리한다 — 헤드리스
    /// 테스트에서는 창이 실제로 화면에 올라오지 않아 `NSWindow`로는 이 규칙을 검증할 수 없다.
    ///
    /// `active`가 `visible`을 포함하는 게 핵심이다. 닫히는 중(willClose)처럼 key 플래그가 아직
    /// 남아 있는 순간에 "안 보이는데 활성"으로 읽히면, 깃발 이펙트처럼 활성일 때만 도는 연출이
    /// 보이지도 않는 창에서 계속 돌게 된다.
    static func state(isVisible: Bool, isMiniaturized: Bool,
                      occluded: Bool, isKey: Bool) -> (visible: Bool, active: Bool) {
        let visible = isVisible && !isMiniaturized && !occluded
        return (visible, visible && isKey)
    }

    private func recompute() {
        guard let window else { return }
        // `isVisible`은 orderOut/닫힘을, occlusionState는 다른 창에 완전히 가려진 경우를 잡는다.
        // 둘 다 봐야 하는 이유: 닫힌 창은 occlusionState가 갱신되지 않고 남아 있을 수 있다.
        let next = Self.state(isVisible: window.isVisible,
                              isMiniaturized: window.isMiniaturized,
                              occluded: !window.occlusionState.contains(.visible),
                              isKey: window.isKeyWindow)
        if next.visible != isVisible { isVisible = next.visible }
        if next.active != isActive { isActive = next.active }
    }

    deinit {
        // detach()는 @MainActor라 여기서 못 부른다. removeObserver는 스레드 안전이므로 직접 정리.
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// 마우스 이벤트를 절대 받지 않는 뷰.
///
/// SwiftUI의 `.allowsHitTesting(false)`는 SwiftUI 레이어에서만 동작하고, `NSViewRepresentable`이
/// 실제로 뷰 계층에 꽂아 넣은 AppKit 뷰의 `hitTest`까지 막아주지는 않는다. 그래서 아래 accessor를
/// `.background`로 깔았을 때 패널 크기만큼 늘어난 투명 NSView가 **모든 클릭을 가로챘다**
/// (v0.17.27에서 패널의 버튼이 전부 안 눌리는 회귀로 나타났다). AppKit 쪽에서 직접 막는다.
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 상위 창을 찾아 monitor에 연결하는 0크기 뷰. SwiftUI에서 `NSWindow`에 닿는 표준 우회로다.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView(frame: .zero)
        // makeNSView 시점엔 아직 창 계층에 붙기 전이라 view.window가 nil이다. 한 틱 뒤에 읽는다.
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // 창이 바뀌는 경우(다른 창으로 호스팅 이동)에도 따라가도록 매번 확인 — monitor 쪽에서
        // 같은 창이면 no-op 처리한다.
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

private struct PauseAnimationsWhenHidden: ViewModifier {
    @StateObject private var monitor = WindowVisibilityMonitor()

    func body(content: Content) -> some View {
        content
            .environment(\.windowIsVisible, monitor.isVisible)
            .environment(\.windowIsActive, monitor.isActive)
            // 0×0으로 고정 + PassthroughView. 둘 중 하나만으로도 막히지만, `.background`는 기본적으로
            // 콘텐츠 크기만큼 늘어나므로 크기와 hitTest 양쪽을 다 잠가둔다.
            .background(
                WindowAccessor { monitor.attach(to: $0) }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// 창 루트에 한 번 붙인다. 하위 `TimelineView`들이 `\.windowIsVisible`(보임)과
    /// `\.windowIsActive`(포커스)로 프레임 루프를 멈춘다.
    func pauseAnimationsWhenHidden() -> some View {
        modifier(PauseAnimationsWhenHidden())
    }
}
