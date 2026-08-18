import AppKit
import WebKit

/// 로그인 WebView의 네비게이션 판정. 델리게이트에서 분리한 순수 함수라 테스트가 가능하다
/// (`LoginNavigationPolicyTests`). 판정이 조용히 틀리면 증상이 "아무 일도 안 일어남"이라
/// 사용자도 로그도 알려주지 않으므로, 규칙은 여기 한 곳에만 둔다.
enum LoginNavigationDecision: Equatable {
    case allow
    case cancel
    /// 로그인과 무관한 곳으로 사용자를 데려가려는 최상위 이동 — 시스템 브라우저로 넘긴다.
    case openExternally
}

enum LoginNavigationPolicy {
    /// 로그인 흐름에서 WebView 안에 머물러도 되는 호스트.
    ///
    /// ⚠️ 이 목록은 **최상위 프레임에만** 적용한다. 서브프레임(iframe)까지 여기에 걸면
    /// 로그인 페이지가 싣는 서드파티 리소스가 조용히 죽는다 — 실제로 claude.ai 로그인 페이지의
    /// hCaptcha(`newassets.hcaptcha.com`)가 목록에 없어서 캡차가 뜨지 않고, 그 iframe URL이
    /// 엉뚱하게 사용자의 외부 브라우저로 열리고 있었다. 페이지가 서드파티를 하나 추가할 때마다
    /// 조용히 깨지는 구조라, 목록을 늘리는 대신 프레임 단위로 규칙을 나눈다.
    static let allowedHostSuffixes = [
        "claude.ai",
        "anthropic.com",
        "google.com",
        "gstatic.com",
        "googleusercontent.com",
        "apple.com",
        "icloud.com",
        "github.com",
        "workos.com",
        "auth0.com",
    ]

    static func isAllowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return allowedHostSuffixes.contains { h == $0 || h.hasSuffix(".\($0)") }
    }

    /// - Parameter isMainFrame: 최상위 프레임 이동이면 true. iframe·팝업이면 false.
    ///   팝업(`targetFrame == nil`)은 여기서 통과시키고 `createWebViewWith`가 다시 판정한다.
    static func decide(for url: URL, isMainFrame: Bool) -> LoginNavigationDecision {
        if url.scheme == "about" { return .allow }
        guard url.scheme == "https", let host = url.host, !host.isEmpty else { return .cancel }
        // 서브프레임·팝업은 사용자를 데려가는 이동이 아니다. 외부 브라우저로 내보내면 안 된다.
        guard isMainFrame else { return .allow }
        return isAllowedHost(host) ? .allow : .openExternally
    }
}

final class LoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    var onCaptured: ((String) -> Void)?
    /// 창이 닫힐 때(성공/취소 무관) 1회 호출 — 소유자가 참조를 놓아 다음 로그인 시도가
    /// 새 컨트롤러로 시작되게 한다.
    var onClosed: (() -> Void)?
    private var webView: WKWebView!
    private var pollTimer: Timer?
    /// OAuth 팝업 창. Google 로그인은 팝업으로만 진행되므로 수명 관리가 필요하다.
    private var popupWindow: NSWindow?
    private var popupWebView: WKWebView?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude 로그인"
        window.center()
        // 코드로 생성한 NSWindow의 기본값은 true — 닫히는 순간 release돼 이후 showWindow 재사용
        // 시 해제된 창을 참조한다. 다른 모든 윈도우 컨트롤러와 동일하게 false로 고정.
        window.isReleasedWhenClosed = false
        self.init(window: window)
        window.delegate = self

        let cfg = WKWebViewConfiguration()
        // sessionKey는 캡처 즉시 Keychain에 저장하므로 WebView에 영구 쿠키를 남길 필요가 없다.
        // 영구 스토어(~/Library/WebKit)에 세션 쿠키가 평문으로 잔존해 Keychain 보호를 우회하는
        // 사본이 되는 것을 막기 위해 비영구 스토어를 쓴다.
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        // ⚠️ uiDelegate가 없으면 window.open()이 조용히 폐기된다. claude.ai의 "Google로 계속하기"는
        // Google Identity Services(GIS) SDK라 accounts.google.com을 **팝업으로** 여는데, 델리게이트가
        // 없던 동안 버튼을 눌러도 창도 에러도 없이 아무 일이 일어나지 않았다.
        wv.uiDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView?.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            wv.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        ])
        self.webView = wv
        wv.load(URLRequest(url: URL(string: "https://claude.ai/login")!))

        // 로그인 완료 시점을 놓치지 않도록 주기적으로도 쿠키를 스캔
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkForSessionKey()
        }
    }

    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSessionKey()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // targetFrame이 nil이면 새 창(window.open / target=_blank) — 최상위 이동이 아니므로
        // 통과시키고 createWebViewWith에서 다시 판정한다.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        switch LoginNavigationPolicy.decide(for: url, isMainFrame: isMainFrame) {
        case .allow:
            decisionHandler(.allow)
        case .cancel:
            decisionHandler(.cancel)
        case .openExternally:
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    // MARK: - OAuth 팝업 (WKUIDelegate)

    /// window.open() 요청. **전달받은 `configuration`을 그대로 써야 한다** — WebKit이 opener와
    /// 같은 데이터 스토어·프로세스 풀을 물려주기 때문이다. 새 configuration을 만들면
    /// (1) 팝업이 다른 쿠키 저장소를 쓰게 되어 로그인 결과 쿠키를 폴링이 못 보고,
    /// (2) `window.opener`가 끊겨 GIS의 `response_mode=form_post` 콜백이 완결되지 않는다.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        // 팝업도 사용자를 데려가는 이동이라 최상위와 같은 기준으로 판정한다.
        guard LoginNavigationPolicy.decide(for: url, isMainFrame: true) == .allow else {
            NSWorkspace.shared.open(url)
            return nil
        }
        // 이미 팝업이 떠 있으면 그 창을 재사용한다(중복 클릭 방어).
        if let existing = popupWebView {
            existing.load(navigationAction.request)
            popupWindow?.makeKeyAndOrderFront(nil)
            return existing
        }

        let popup = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popup.title = "로그인"
        popup.isReleasedWhenClosed = false
        popup.delegate = self

        let pv = WKWebView(frame: .zero, configuration: configuration)
        pv.navigationDelegate = self
        pv.uiDelegate = self
        pv.customUserAgent = webView.customUserAgent
        pv.translatesAutoresizingMaskIntoConstraints = false
        popup.contentView = NSView()
        popup.contentView?.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: popup.contentView!.topAnchor),
            pv.bottomAnchor.constraint(equalTo: popup.contentView!.bottomAnchor),
            pv.leadingAnchor.constraint(equalTo: popup.contentView!.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: popup.contentView!.trailingAnchor),
        ])

        popupWindow = popup
        popupWebView = pv
        if let parent = window {
            popup.setFrameOrigin(NSPoint(x: parent.frame.midX - 260, y: parent.frame.midY - 320))
        } else {
            popup.center()
        }
        popup.makeKeyAndOrderFront(nil)
        // WebKit이 반환된 WebView에 요청을 직접 싣는다 — 여기서 load하면 이중 로드가 된다.
        return pv
    }

    /// 팝업이 window.close()를 호출했을 때(=OAuth 완료). 창을 닫아준다.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        closePopup()
        // 팝업이 닫히는 시점엔 이미 claude.ai 쿠키가 스토어에 들어와 있다. 2초 폴링을
        // 기다리지 않고 즉시 확인해 로그인 완료를 앞당긴다.
        checkForSessionKey()
    }

    private func closePopup() {
        popupWindow?.delegate = nil
        popupWindow?.close()
        popupWindow = nil
        popupWebView = nil
    }

    private func checkForSessionKey() {
        // WebView가 비영구(nonPersistent) 스토어로 로그인하므로 쿠키도 그 스토어에서 조회해야 한다.
        // default()는 영구 스토어라 nonPersistent 로그인 쿠키가 없어 sessionKey 캡처가 영영 실패했다
        // (#77 회귀 — 7987c66에서 WebView만 nonPersistent로 바꾸고 조회 스토어를 안 맞춤).
        // 팝업은 opener의 configuration을 물려받아 같은 스토어를 쓰므로 이 조회 하나로 커버된다.
        let store = webView.configuration.websiteDataStore.httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            if let c = cookies.first(where: { $0.name == "sessionKey" && Self.isClaudeCookieDomain($0.domain) && !$0.value.isEmpty }) {
                self.capture(c.value)
            }
        }
    }

    private static func isClaudeCookieDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "claude.ai" || normalized.hasSuffix(".claude.ai")
    }

    private var captured = false
    private func capture(_ key: String) {
        if captured { return }
        captured = true
        Keychain.save(key)
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.closePopup()
            self?.onCaptured?(key)
            self?.close()
        }
    }

    /// 성공(capture→close)이든 취소(타이틀바 닫기)든 여기로 수렴 — 2초 쿠키 폴링을 반드시
    /// 멈추고 소유자에게 참조 해제를 알린다. 취소 시 이 정리가 없으면 타이머가 프로세스
    /// 종료까지 돌고, 재로그인 시도가 죽은 컨트롤러의 showWindow로 빠진다.
    func windowWillClose(_ notification: Notification) {
        // 팝업(OAuth 창)이 닫힌 것뿐이면 로그인 세션은 계속된다 — 폴링을 멈추면 안 된다.
        if let closing = notification.object as? NSWindow, closing === popupWindow {
            popupWindow = nil
            popupWebView = nil
            return
        }
        pollTimer?.invalidate()
        pollTimer = nil
        closePopup()
        onClosed?()
    }

    deinit {
        pollTimer?.invalidate()
    }
}
