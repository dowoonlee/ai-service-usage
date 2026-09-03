import AppKit
import WebKit

/// 로그인 WebView의 네비게이션 판정. 델리게이트에서 분리한 순수 함수라 테스트가 가능하다
/// (`LoginNavigationPolicyTests`). 판정이 조용히 틀리면 증상이 "아무 일도 안 일어남"이라
/// 사용자도 로그도 알려주지 않으므로, 규칙은 여기 한 곳에만 둔다.
enum LoginNavigationDecision: Equatable {
    case allow
    case cancel
}

enum LoginNavigationPolicy {
    /// https는 **호스트를 가리지 않고 창 안에서** 처리한다. 프레임 종류도 보지 않는다.
    ///
    /// 예전에는 로그인에 쓰이는 호스트 허용목록을 두고 그 밖은 `NSWorkspace.open`으로 시스템
    /// 브라우저에 넘겼는데, 그게 로그인을 깨는 원인이었다. OAuth는 state·nonce·쿠키가 **이 창의
    /// 세션**에 묶여 있어서, 중간 한 단계라도 다른 브라우저로 넘어가면 그쪽에는 맞는 세션이 없다.
    /// 실제 제보: Google 로그인 도중 기본 브라우저(웨일)가 열렸고 Google이 403으로 거부했다.
    /// 브라우저 종류의 문제가 아니다 — 넘긴 순간 어느 브라우저에서든 깨진다.
    ///
    /// 허용목록을 늘려서는 못 고친다. 로그인 플로우는 회사 SSO IdP, 캡차, 본인확인 같은 임의
    /// 호스트를 정상적으로 경유하고, 그 목록은 계정·조직마다 다르다. 목록을 한 줄씩 늘리는 방식은
    /// 다음 사용자에서 또 조용히 깨진다.
    ///
    /// 대신 남은 통제는 **스킴**이다. 비-https(`mailto:`, `ftp:`, 커스텀 스킴 등)는 취소한다 —
    /// 그걸 시스템에 넘기면 이 창이 임의 스킴을 여는 통로가 된다.
    static func decide(for url: URL, isMainFrame: Bool) -> LoginNavigationDecision {
        // WebKit이 프레임을 만들 때 about:blank를 먼저 태운다. 막으면 페이지가 조립되지 않는다.
        if url.scheme == "about" { return .allow }
        guard url.scheme == "https", let host = url.host, !host.isEmpty else { return .cancel }
        return .allow
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
        Self.log("창 열기 — claude.ai/login 로드")
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

    /// 로드 실패 — 사내망 TLS 가로채기나 차단된 호스트를 여기서 구분한다. URL은 남기지 않고
    /// 에러 도메인·코드만 남긴다.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        Self.log("로드 실패 \(ns.domain) code=\(ns.code)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let ns = error as NSError
        Self.log("로드 실패(provisional) \(ns.domain) code=\(ns.code)")
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
            // 최상위 이동만 남긴다 — 서브프레임까지 찍으면 광고·계측 프레임에 로그가 묻힌다.
            if isMainFrame { Self.log("이동 host=\(url.host ?? "?")") }
            decisionHandler(.allow)
        case .cancel:
            Self.log("차단 scheme=\(url.scheme ?? "?") main=\(isMainFrame)")
            decisionHandler(.cancel)
        }
    }

    /// 로그인 흐름 로그. **호스트·스킴·단계만** 남긴다 — path/query에는 OAuth code·state가,
    /// 쿠키에는 sessionKey가 실려 있고 이 로그는 버그리포트로 GitHub 이슈에 첨부된다.
    ///
    /// 로깅이 없던 동안 "로그인이 안 된다" 제보는 전부 추측으로만 다뤄야 했다 — 팝업이 떴는지,
    /// 어느 호스트에서 멈췄는지, 쿠키를 잡았는지 로그에 아무 흔적이 없었다.
    private static func log(_ message: String) {
        DebugLog.log("Login: \(message)")
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
        // 팝업도 사용자를 데려가는 이동이라 최상위와 같은 기준으로 판정한다. 여기서 창 밖으로
        // 내보내면 OAuth 세션이 끊긴다(위 `decide` 주석 참조) — 못 열 URL이면 그냥 무시한다.
        guard LoginNavigationPolicy.decide(for: url, isMainFrame: true) == .allow else {
            Self.log("팝업 차단 scheme=\(url.scheme ?? "?")")
            return nil
        }
        Self.log("팝업 host=\(url.host ?? "?")")
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
        Self.log("팝업 닫힘 (window.close) — 쿠키 즉시 확인")
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
        Self.log("sessionKey 캡처 — 로그인 완료")
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
        Self.log(captured ? "창 닫힘 (성공)" : "창 닫힘 (캡처 없이 종료)")
        pollTimer?.invalidate()
        pollTimer = nil
        closePopup()
        onClosed?()
    }

    deinit {
        pollTimer?.invalidate()
    }
}
