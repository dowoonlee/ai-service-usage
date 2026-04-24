import AppKit
import WebKit

final class LoginWindowController: NSWindowController, WKNavigationDelegate {
    var onCaptured: ((String) -> Void)?
    private var webView: WKWebView!
    private var pollTimer: Timer?

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
        cfg.websiteDataStore = WKWebsiteDataStore.default()
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

    private func checkForSessionKey() {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { [weak self] cookies in
            guard let self else { return }
            if let c = cookies.first(where: { $0.name == "sessionKey" && $0.domain.contains("claude.ai") && !$0.value.isEmpty }) {
                self.capture(c.value)
            }
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
