import AppKit
import WebKit

final class LoginWindowController: NSWindowController, WKNavigationDelegate {
    var onCaptured: ((String) -> Void)?
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
        self.init(window: window)

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
        let store = WKWebsiteDataStore.default().httpCookieStore
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

    deinit {
        pollTimer?.invalidate()
    }
}
