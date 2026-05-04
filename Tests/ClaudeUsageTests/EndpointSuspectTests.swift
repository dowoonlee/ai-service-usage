import XCTest
@testable import ClaudeUsage

final class EndpointSuspectTests: XCTestCase {
    // 디코딩 에러는 endpoint 변경 의심.
    func testDecodingErrorIsSuspect() {
        struct Dummy: Decodable {}
        let badJSON = Data("{\"unrelated\":1}".utf8)
        let decodeErr: Error
        do {
            _ = try JSONDecoder().decode(Dummy.self, from: badJSON)
            XCTFail("decode should have thrown")
            return
        } catch {
            decodeErr = error
        }
        XCTAssertTrue(ViewModel.isSchemaSuspect(UsageError.decoding(decodeErr)))
        XCTAssertTrue(ViewModel.isSchemaSuspect(CursorError.decoding(decodeErr)))
    }

    // 4xx (auth/429 제외)는 endpoint 변경 의심.
    func testNonAuth4xxIsSuspect() {
        XCTAssertTrue(ViewModel.isSchemaSuspect(UsageError.http(400)))
        XCTAssertTrue(ViewModel.isSchemaSuspect(UsageError.http(404)))
        XCTAssertTrue(ViewModel.isSchemaSuspect(UsageError.http(410)))
        XCTAssertTrue(ViewModel.isSchemaSuspect(CursorError.http(404)))
    }

    // 401/403/429는 suspect 아님 (auth/rate-limit는 별도 처리).
    func testAuthAndRateLimitNotSuspect() {
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.http(401)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.http(403)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.http(429)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(CursorError.http(401)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(CursorError.http(429)))
    }

    // 5xx는 transient — suspect 아님.
    func testServerErrorsNotSuspect() {
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.http(500)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.http(503)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(CursorError.http(502)))
    }

    // transport 에러(네트워크)도 suspect 아님.
    func testTransportNotSuspect() {
        let netErr = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertFalse(ViewModel.isSchemaSuspect(UsageError.transport(netErr)))
        XCTAssertFalse(ViewModel.isSchemaSuspect(CursorError.transport(netErr)))
    }

    // 알 수 없는 에러 타입은 false (보수적 분류).
    func testUnknownErrorNotSuspect() {
        let other = NSError(domain: "Other", code: 1)
        XCTAssertFalse(ViewModel.isSchemaSuspect(other))
    }
}
