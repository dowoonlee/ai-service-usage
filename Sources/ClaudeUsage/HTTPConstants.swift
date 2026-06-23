import Foundation

/// claude.ai / Cursor / Codex 비공식 엔드포인트에 공통으로 보내는 브라우저 User-Agent.
/// 세 actor(UsageAPI/CursorAPI/CodexAPI)가 같은 값을 써야 서버별 UA 비일관(ban-risk)을 피한다.
/// OS 버전 등 갱신은 여기 한 곳만 고치면 된다. WeatherAPI는 의도적으로 별도 UA를 쓰므로 제외.
let sharedBrowserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
