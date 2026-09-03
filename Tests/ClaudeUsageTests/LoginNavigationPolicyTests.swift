import XCTest
@testable import ClaudeUsage

/// 로그인 WebView 네비게이션 판정.
///
/// 이 판정이 틀리면 증상이 **"아무 일도 안 일어남"** 또는 **"엉뚱한 브라우저가 열림"** 이라
/// 사용자도 로그도 원인을 알려주지 않는다. 실제로 세 번 그랬다:
///   1) uiDelegate 미구현 — "Google로 계속하기"가 window.open() 팝업인데 조용히 폐기돼 무반응.
///   2) iframe까지 호스트 허용목록을 적용 — 로그인 페이지의 hCaptcha가 CANCEL되고
///      그 iframe URL이 외부 브라우저로 열렸다.
///   3) 허용목록 밖 호스트를 시스템 브라우저로 넘김 — OAuth 세션이 이 창에 묶여 있어
///      넘겨받은 브라우저에서는 성립하지 않는다. Google이 403으로 거부했다.
/// 셋 다 "이 창 밖으로 새는 경로"에서 나왔으므로, 이제 https는 전부 창 안에서 처리한다.
final class LoginNavigationPolicyTests: XCTestCase {

    private func decide(_ urlString: String, mainFrame: Bool) -> LoginNavigationDecision {
        guard let url = URL(string: urlString) else {
            XCTFail("URL 파싱 실패: \(urlString)")
            return .cancel
        }
        return LoginNavigationPolicy.decide(for: url, isMainFrame: mainFrame)
    }

    // MARK: - 로그인에 쓰이는 호스트

    func testMainFrameAllowsLoginHosts() {
        for host in ["claude.ai", "www.claude.ai", "accounts.google.com", "github.com",
                     "api.workos.com", "appleid.apple.com", "ssl.gstatic.com"] {
            XCTAssertEqual(decide("https://\(host)/x", mainFrame: true), .allow, host)
        }
    }

    /// 회귀 고정 — 이 케이스가 예전에 `.openExternally`였고, 그게 로그인을 깼다.
    ///
    /// 로그인 플로우는 회사 SSO IdP·캡차·본인확인처럼 **미리 알 수 없는 호스트**를 정상적으로
    /// 경유한다. 허용목록을 늘려서는 못 고치고, 밖으로 내보내면 OAuth state·쿠키가 이 창에만
    /// 있어 어느 브라우저로 넘겨도 실패한다.
    func testUnknownHostStaysInsideWindow() {
        for url in ["https://sso.example-corp.com/saml",     // 회사 IdP
                    "https://accounts.youtube.com/x",         // 구글 계정 연결 단계
                    "https://recaptcha.net/recaptcha/api2/x", // 구글 대체 캡차 도메인
                    "https://accounts.google.co.kr/x",        // 국가 도메인
                    "https://example.com/"] {
            XCTAssertEqual(decide(url, mainFrame: true), .allow, url)
        }
    }

    // MARK: - 서브프레임

    func testSubFrameAllowsThirdParty() {
        // 회귀 고정: hCaptcha iframe이 외부 브라우저로 열리던 버그.
        XCTAssertEqual(decide("https://newassets.hcaptcha.com/captcha/v1/x/hcaptcha.html", mainFrame: false), .allow)
        XCTAssertEqual(decide("https://cdn.some-analytics.example/x.js", mainFrame: false), .allow)
    }

    // MARK: - 스킴 경계 (남은 유일한 통제)

    func testNonHttpsIsCancelledInAnyFrame() {
        for frame in [true, false] {
            XCTAssertEqual(decide("http://claude.ai/", mainFrame: frame), .cancel)
            XCTAssertEqual(decide("javascript:alert(1)", mainFrame: frame), .cancel)
            XCTAssertEqual(decide("file:///etc/passwd", mainFrame: frame), .cancel)
            XCTAssertEqual(decide("ftp://example.com/", mainFrame: frame), .cancel)
        }
    }

    /// 커스텀 스킴을 통과시키면 이 창이 임의 앱을 여는 통로가 된다 — 취소만 하고 밖으로 넘기지 않는다.
    func testCustomSchemeIsCancelled() {
        XCTAssertEqual(decide("someapp://open?x=1", mainFrame: true), .cancel)
        XCTAssertEqual(decide("mailto:a@b.c", mainFrame: true), .cancel)
    }

    func testHttpsWithoutHostIsCancelled() {
        XCTAssertEqual(decide("https:///nohost", mainFrame: true), .cancel)
    }

    func testAboutBlankAllowedInAnyFrame() {
        // WebKit이 프레임을 만들 때 about:blank를 먼저 태운다 — 막으면 페이지가 조립되지 않는다.
        XCTAssertEqual(decide("about:blank", mainFrame: true), .allow)
        XCTAssertEqual(decide("about:blank", mainFrame: false), .allow)
    }

    // MARK: - 팝업 (createWebViewWith가 isMainFrame: true로 재판정한다)

    func testGoogleOAuthPopupIsAllowed() {
        // "Google로 계속하기"가 여는 실제 URL 형태. 이게 막히면 다시 무반응이 된다.
        let url = "https://accounts.google.com/o/oauth2/v2/auth?gsiwebsdk=gis_attributes"
            + "&client_id=1062961139910-example.apps.googleusercontent.com&response_mode=form_post"
        XCTAssertEqual(decide(url, mainFrame: true), .allow)
    }
}
