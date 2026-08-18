import XCTest
@testable import ClaudeUsage

/// 로그인 WebView 네비게이션 판정.
///
/// 이 판정이 틀리면 증상이 **"아무 일도 안 일어남"** 이라 사용자도 로그도 원인을 알려주지 않는다.
/// 실제로 두 번 그랬다:
///   1) uiDelegate 미구현 — "Google로 계속하기"가 window.open() 팝업인데 조용히 폐기돼 무반응.
///   2) iframe까지 호스트 허용목록을 적용 — 로그인 페이지의 hCaptcha가 CANCEL되고
///      그 iframe URL이 외부 브라우저로 열렸다.
/// 둘 다 "프레임 종류를 안 봤다"는 한 가지 실수에서 나왔으므로 그 축을 고정한다.
final class LoginNavigationPolicyTests: XCTestCase {

    private func decide(_ urlString: String, mainFrame: Bool) -> LoginNavigationDecision {
        guard let url = URL(string: urlString) else {
            XCTFail("URL 파싱 실패: \(urlString)")
            return .cancel
        }
        return LoginNavigationPolicy.decide(for: url, isMainFrame: mainFrame)
    }

    // MARK: - 최상위 프레임 — 허용목록이 실제 보안 통제가 되는 지점

    func testMainFrameAllowsLoginHosts() {
        for host in ["claude.ai", "www.claude.ai", "accounts.google.com", "github.com",
                     "api.workos.com", "appleid.apple.com", "ssl.gstatic.com"] {
            XCTAssertEqual(decide("https://\(host)/x", mainFrame: true), .allow, host)
        }
    }

    func testMainFrameSendsUnknownHostToBrowser() {
        // 로그인과 무관한 곳으로 사용자를 데려가려는 이동은 시스템 브라우저로 넘긴다.
        XCTAssertEqual(decide("https://example.com/", mainFrame: true), .openExternally)
        XCTAssertEqual(decide("https://claude.com/pricing", mainFrame: true), .openExternally)
    }

    func testSuffixMatchIsNotSubstringMatch() {
        // "evil-claude.ai" / "claude.ai.attacker.com" 류가 통과하면 안 된다.
        XCTAssertEqual(decide("https://evilclaude.ai/", mainFrame: true), .openExternally)
        XCTAssertEqual(decide("https://claude.ai.attacker.com/", mainFrame: true), .openExternally)
        XCTAssertEqual(decide("https://notgoogle.com/", mainFrame: true), .openExternally)
    }

    // MARK: - 서브프레임 — 사용자를 데려가는 이동이 아니다

    func testSubFrameNeverGoesToExternalBrowser() {
        // 회귀 고정: hCaptcha iframe이 외부 브라우저로 열리던 버그.
        XCTAssertEqual(decide("https://newassets.hcaptcha.com/captcha/v1/x/hcaptcha.html", mainFrame: false), .allow)
        // 허용목록에 없는 서드파티가 추가돼도 조용히 깨지지 않아야 한다.
        XCTAssertEqual(decide("https://cdn.some-analytics.example/x.js", mainFrame: false), .allow)
    }

    func testSubFrameStillRejectsNonHttps() {
        // 프레임 종류와 무관하게 https가 아니면 막는다.
        XCTAssertEqual(decide("http://claude.ai/", mainFrame: false), .cancel)
        XCTAssertEqual(decide("javascript:alert(1)", mainFrame: false), .cancel)
        XCTAssertEqual(decide("file:///etc/passwd", mainFrame: false), .cancel)
    }

    // MARK: - 스킴 경계

    func testAboutBlankAllowedInAnyFrame() {
        // WebKit이 프레임을 만들 때 about:blank를 먼저 태운다 — 막으면 페이지가 조립되지 않는다.
        XCTAssertEqual(decide("about:blank", mainFrame: true), .allow)
        XCTAssertEqual(decide("about:blank", mainFrame: false), .allow)
    }

    func testNonHttpsMainFrameIsCancelledNotOpenedExternally() {
        // 외부 브라우저로 넘기면 안 된다 — 앱이 임의 스킴을 시스템에 넘기는 통로가 된다.
        XCTAssertEqual(decide("http://example.com/", mainFrame: true), .cancel)
        XCTAssertEqual(decide("ftp://example.com/", mainFrame: true), .cancel)
    }

    // MARK: - 팝업 판정 (createWebViewWith가 isMainFrame: true로 재판정한다)

    func testGoogleOAuthPopupIsAllowed() {
        // "Google로 계속하기"가 여는 실제 URL 형태. 이게 막히면 다시 무반응이 된다.
        let url = "https://accounts.google.com/o/oauth2/v2/auth?gsiwebsdk=gis_attributes"
            + "&client_id=1062961139910-example.apps.googleusercontent.com&response_mode=form_post"
        XCTAssertEqual(decide(url, mainFrame: true), .allow)
    }

    // MARK: - 허용목록 자체

    func testAllowedHostMatchingIsCaseInsensitive() {
        XCTAssertTrue(LoginNavigationPolicy.isAllowedHost("ACCOUNTS.GOOGLE.COM"))
        XCTAssertTrue(LoginNavigationPolicy.isAllowedHost("Claude.AI"))
        XCTAssertFalse(LoginNavigationPolicy.isAllowedHost("EXAMPLE.COM"))
    }

    func testBareSuffixMatchesItself() {
        for suffix in LoginNavigationPolicy.allowedHostSuffixes {
            XCTAssertTrue(LoginNavigationPolicy.isAllowedHost(suffix), suffix)
            XCTAssertTrue(LoginNavigationPolicy.isAllowedHost("sub.\(suffix)"), "sub.\(suffix)")
        }
    }
}
