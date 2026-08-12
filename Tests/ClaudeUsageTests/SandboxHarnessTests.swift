import XCTest
@testable import ClaudeUsage

/// 격리 하네스 자체에 대한 테스트.
///
/// 여기가 깨지면 다른 테스트가 "통과"하면서 실제 사용자 데이터를 오염시킬 수 있다 —
/// 나머지 상태 의존 테스트 전부가 이 파일의 단언 위에 서 있다.
@MainActor
final class SandboxHarnessTests: SandboxedTestCase {

    func testTestRunIsSandboxed() {
        XCTAssertTrue(AppEnv.isSandboxed, "XCTest는 자동으로 샌드박스여야 한다")
    }

    // 설정 저장소가 실사용 도메인이 아니어야 한다. 이게 뒤집히면 테스트가 사용자의 코인·펫을 덮어쓴다.
    func testDefaultsAreNotTheStandardDomain() {
        XCTAssertFalse(AppEnv.defaults === UserDefaults.standard)
        AppEnv.defaults.set(12345, forKey: "sandbox.probe")
        XCTAssertEqual(AppEnv.defaults.integer(forKey: "sandbox.probe"), 12345)
        XCTAssertNil(UserDefaults.standard.object(forKey: "sandbox.probe"),
                     "샌드박스 쓰기가 실사용 도메인으로 새면 안 된다")
    }

    // keychain은 in-memory여야 한다. 실 keychain이면 ad-hoc ACL 재승인 다이얼로그로 실행이 멈춘다.
    func testKeychainBackendIsInMemory() {
        XCTAssertTrue(AppEnv.keychain is InMemoryKeychainBackend)
    }

    // JSONL 저장 경로가 Application Support 실경로가 아니어야 한다.
    func testDataDirectoryIsRedirected() throws {
        let dir = try XCTUnwrap(AppEnv.dataDirectory)
        XCTAssertFalse(dir.path.contains("Application Support/ClaudeUsage"),
                       "샌드박스 JSONL이 실사용 경로를 가리키면 안 된다: \(dir.path)")
    }

    // reset이 실제로 상태를 지우는지 — 지우지 못하면 테스트 간 오염이 조용히 번진다.
    func testResetClearsSettingsAndKeychain() {
        Settings.shared.coins = 9999
        Keychain.save("session-token")
        XCTAssertEqual(Keychain.load(), "session-token")

        Settings.resetForTesting()

        XCTAssertNotEqual(Settings.shared.coins, 9999, "리셋 후 코인이 남아있으면 안 된다")
        XCTAssertNil(Keychain.load(), "리셋 후 keychain 값이 남아있으면 안 된다")
    }

    // 리셋은 인스턴스까지 새로 만든다 — suite만 비우면 메모리에 올라온 이전 값이 그대로 살아남는다.
    func testResetReplacesSharedInstance() {
        let before = Settings.shared
        Settings.resetForTesting()
        XCTAssertFalse(before === Settings.shared)
    }
}
