import AppKit
import WebKit

final class LoginWindowController: NSWindowController, WKNavigationDelegate, NSWindowDelegate {
    var onCaptured: ((String) -> Void)?
    /// 창이 닫힐 때(성공/취소 무관) 1회 호출 — 소유자가 참조를 놓아 다음 로그인 시도가
    /// 새 컨트롤러로 시작되게 한다.
    var onClosed: (() -> Void)?
    private var webView: WKWebView!
    private var pollTimer: Timer?
    private static let allowedLoginHostSuffixes = [
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
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        guard url.scheme == "https", let host = url.host?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        if Self.isAllowedLoginHost(host) {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    private func checkForSessionKey() {
        // WebView가 비영구(nonPersistent) 스토어로 로그인하므로 쿠키도 그 스토어에서 조회해야 한다.
        // default()는 영구 스토어라 nonPersistent 로그인 쿠키가 없어 sessionKey 캡처가 영영 실패했다
        // (#77 회귀 — 7987c66에서 WebView만 nonPersistent로 바꾸고 조회 스토어를 안 맞춤).
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

    private static func isAllowedLoginHost(_ host: String) -> Bool {
        allowedLoginHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    private var captured = false
    private func capture(_ key: String) {
        if captured { return }
        captured = true
        Keychain.save(key)
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer?.invalidate()
            self?.pollTimer = nil
            self?.onCaptured?(key)
            self?.close()
        }
    }

    /// 성공(capture→close)이든 취소(타이틀바 닫기)든 여기로 수렴 — 2초 쿠키 폴링을 반드시
    /// 멈추고 소유자에게 참조 해제를 알린다. 취소 시 이 정리가 없으면 타이머가 프로세스
    /// 종료까지 돌고, 재로그인 시도가 죽은 컨트롤러의 showWindow로 빠진다.
    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        onClosed?()
    }

    deinit {
        pollTimer?.invalidate()
    }
}
