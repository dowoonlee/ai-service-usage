import XCTest
import CryptoKit
@testable import ClaudeUsage

/// HMAC 서명 파리티 — 클라(Swift) ↔ 서버(TS).
///
/// 랭킹 인증의 근간이다. 클라는 `JSONEncoder([.sortedKeys, .withoutEscapingSlashes])`로 payload를
/// 직렬화한 뒤 HMAC-SHA256하고, 서버는 `_shared/hmac.ts`의 `canonicalize()`로 **같은 문자열을
/// 재현**해서 검증한다. 두 구현이 한 글자라도 갈라지면 서명이 어긋나 그 사용자만 조용히 막힌다.
///
/// 배틀 엔진은 골든으로 잠가뒀으면서 정작 인증 경로는 가드가 없었다. 여기 골든과
/// `supabase/functions/_shared/hmac.parity.test.ts`의 골든은 **같은 값**이어야 한다 —
/// 한쪽 직렬화가 바뀌면 그쪽 테스트가 깨진다.
///
/// 특히 podium 메시지는 사용자가 입력한 한글이 그대로 서명 대상이 되므로 non-ASCII를 반드시 포함한다.
final class HMACParityTests: XCTestCase {

    /// 테스트 전용 결정적 키 — 바이트 0…31. 서버 테스트도 같은 방식으로 만든다.
    ///
    /// base64 문자열을 그대로 박지 않는 이유는 시크릿 스캐너가 실제 키로 오인해서다. 값을
    /// 코드로 만들면 "이건 상수 바이트열이지 발급된 키가 아니다"가 그 자리에서 드러난다.
    static let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()

    // MARK: - 골든 (서버 hmac.parity.test.ts와 동일 값)

    func testSubmitPayloadSignature() throws {
        let payload = RankingAPI.SubmitPayload(
            deviceId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            delta: 1234, prevTotal: 56_789, ts: 1_800_000_000)
        XCTAssertEqual(try RankingAPI.sign(payload: payload, keyBase64: Self.key),
                       "e774d82dd04e3273283fb23cef28fe812bb90978c8c2c19a36fa230c1ec92fbd")
    }

    func testClaimPayloadSignature() throws {
        let payload = RankingAPI.ClaimRewardPayload(
            deviceId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            period: "2026-07", rank: 1, ts: 1_800_000_000)
        XCTAssertEqual(try RankingAPI.signClaim(payload: payload, keyBase64: Self.key),
                       "d1e89a2b73b4a32ff10322509cbafe7b9a9d19f2b31cb6600fcdbbcdde2b5ba7")
    }

    /// 한글 + 슬래시 + 따옴표가 섞인 메시지. 셋 다 두 구현이 갈라질 수 있는 지점이다:
    /// non-ASCII를 raw UTF-8로 낼 것인가 `\u` 이스케이프할 것인가, `/`를 이스케이프할 것인가.
    func testPodiumPayloadSignatureWithNonASCII() throws {
        let payload = RankingAPI.SetPodiumMessagePayload(
            deviceId: "3f2504e0-4f89-11d3-9a0c-0305e82c3301",
            message: "1등 했다! gg/wp \"vibe\"",
            period: "2026-07", rank: 1, ts: 1_800_000_000)
        XCTAssertEqual(try RankingAPI.signPodium(payload: payload, keyBase64: Self.key),
                       "99f920ba03db1f9c595f2aed5181e26f2ce24e7d00d8d0c273cf03adcb1cf8fc")
    }

    /// 서명 대상이 되는 canonical 문자열 자체도 고정한다. 서명만 비교하면 두 구현이 **둘 다**
    /// 같은 방식으로 틀렸을 때를 못 잡고, 실패했을 때 어디가 어긋났는지도 안 보인다.
    func testCanonicalStringShape() throws {
        let payload = RankingAPI.SetPodiumMessagePayload(
            deviceId: "dev-1", message: "한글/slash", period: "2026-07", rank: 2, ts: 42)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(data: try enc.encode(payload), encoding: .utf8)
        XCTAssertEqual(json,
            #"{"deviceId":"dev-1","message":"한글/slash","period":"2026-07","rank":2,"ts":42}"#)
    }

    /// 키가 잘못된 base64면 서명하지 않고 실패해야 한다 — 조용히 빈 키로 서명하면
    /// 서버가 전부 401을 주는데 원인이 안 보인다.
    func testInvalidKeyThrows() {
        let payload = RankingAPI.SubmitPayload(deviceId: "d", delta: 1, prevTotal: 0, ts: 0)
        XCTAssertThrowsError(try RankingAPI.sign(payload: payload, keyBase64: "!!not base64!!"))
    }
}
