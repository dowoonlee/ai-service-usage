import XCTest
@testable import ClaudeUsage

/// 단일 vault keychain의 캐시·레거시 이전·덮어쓰기 거부.
///
/// 이 코드는 사용자 값을 **영구 유실시킨 버그가 두 번 난** 자리인데(#169, 그리고 레거시 이전에서
/// 못 읽은 원본까지 지운 건), 실 keychain에 붙어 있어 테스트가 불가능했다. 백엔드 경계를
/// 항목 단위로 내려 두었으므로 vault의 판단 로직 자체는 아래 테스트에서 그대로 실행된다.
@MainActor
final class KeychainVaultTests: SandboxedTestCase {

    private func backend() throws -> InMemoryKeychainBackend {
        try XCTUnwrap(AppEnv.keychain as? InMemoryKeychainBackend)
    }

    // MARK: - 기본 왕복

    func testStoreAndLoadRoundTrip() throws {
        Keychain.save("session-1")
        XCTAssertEqual(Keychain.load(), "session-1")
        XCTAssertTrue(Keychain.saveRankingHmacKey("hmac-1"))
        XCTAssertEqual(Keychain.loadRankingHmacKey(), "hmac-1")

        // 여러 값이 있어도 keychain 항목은 vault 하나뿐이어야 한다 — 업데이트 후 ACL 재승인
        // 프롬프트가 항목 수만큼 뜨던 문제를 없앤 설계이므로, 항목이 늘면 그 이득이 사라진다.
        XCTAssertEqual(try backend().storedAccounts, ["vault"])
    }

    func testClearRemovesOnlyTargetKey() throws {
        Keychain.save("session-1")
        Keychain.saveGitHubToken("gh-1")
        Keychain.clear()
        XCTAssertNil(Keychain.load())
        XCTAssertEqual(Keychain.loadGitHubToken(), "gh-1", "다른 키가 함께 지워졌다")
    }

    // 조회 3-상태 — "값 없음"과 "지금 못 읽음"을 뭉개면 인증키 유실 배너가 오탐한다(#169).
    func testLookupDistinguishesAbsentFromAccessFailure() throws {
        if case .absent = Keychain.rankingHmacKeyLookup() {} else {
            XCTFail("저장 전에는 .absent여야 한다")
        }
        Keychain.saveRankingHmacKey("hmac-1")
        if case .value(let v) = Keychain.rankingHmacKeyLookup() {
            XCTAssertEqual(v, "hmac-1")
        } else {
            XCTFail("저장 후에는 .value여야 한다")
        }

        // 캐시가 아니라 백엔드를 실제로 다시 타는 상태에서의 접근 실패를 본다.
        Keychain.resetForTesting()
        let failing = InMemoryKeychainBackend(seed: ["vault": #"{"rankingHmacKey":"hmac-1"}"#])
        failing.simulateAccessFailure = true
        AppEnv.setKeychainBackend(failing)
        if case .accessFailed = Keychain.rankingHmacKeyLookup() {} else {
            XCTFail("접근 실패가 .absent로 뭉개졌다 — 인증키 유실 배너 오탐 경로")
        }
    }

    // MARK: - #169 회귀: 접근 실패 상태에서 덮어쓰기 금지

    // vault를 못 읽는 상태에서 쓰기를 허용하면, 빈 dict가 vault를 덮어 세션키·토큰이 전부 날아간다.
    func testWriteIsRefusedWhileVaultIsUnreadable() throws {
        let seeded = #"{"sessionKey":"live-session","githubToken":"gh-live"}"#
        Keychain.resetForTesting()
        let failing = InMemoryKeychainBackend(seed: ["vault": seeded])
        failing.simulateAccessFailure = true
        AppEnv.setKeychainBackend(failing)

        XCTAssertFalse(Keychain.saveRankingHmacKey("new-key"), "접근 실패 중 저장이 성공으로 보고됐다")
        XCTAssertEqual(failing.rawValue(account: "vault"), seeded, "기존 vault가 덮어써졌다")

        // 접근이 회복되면 원래 값이 그대로 살아있어야 한다 — 유실이 아니라 지연이어야 한다.
        failing.simulateAccessFailure = false
        XCTAssertEqual(Keychain.load(), "live-session")
        XCTAssertEqual(Keychain.loadGitHubToken(), "gh-live")
    }

    func testDeleteIsRefusedWhileVaultIsUnreadable() throws {
        let seeded = #"{"sessionKey":"live-session"}"#
        Keychain.resetForTesting()
        let failing = InMemoryKeychainBackend(seed: ["vault": seeded])
        failing.simulateAccessFailure = true
        AppEnv.setKeychainBackend(failing)

        Keychain.clear()
        XCTAssertEqual(failing.rawValue(account: "vault"), seeded, "접근 실패 중 삭제가 vault를 덮어썼다")
    }

    // MARK: - 레거시 개별 항목 이전

    func testLegacyItemsMigrateIntoVaultAndOriginalsAreRemoved() throws {
        Keychain.resetForTesting()
        let legacy = InMemoryKeychainBackend(seed: [
            "sessionKey": "old-session",
            "githubToken": "old-gh",
            "integrityKey": "old-integrity",
        ])
        AppEnv.setKeychainBackend(legacy)

        XCTAssertEqual(Keychain.load(), "old-session")          // 첫 접근이 이전을 트리거
        XCTAssertEqual(Keychain.loadGitHubToken(), "old-gh")
        XCTAssertEqual(Keychain.loadOrCreateIntegrityKey(), "old-integrity")
        XCTAssertEqual(legacy.storedAccounts, ["vault"], "이전 후 레거시 원본이 남았다")
    }

    // 과거 버그: 이전 시 legacyAccounts를 통째로 지우는 바람에, ACL 재승인을 거부해 **못 읽은**
    // 항목의 원본까지 삭제돼 값이 영구 유실됐다(integrityKey 유실 → 무결성 오탐).
    // 읽지 못한 원본은 반드시 남아야 한다.
    func testUnreadableLegacyItemIsNotDeleted() throws {
        Keychain.resetForTesting()
        let partial = InMemoryKeychainBackend(seed: [
            "sessionKey": "old-session",
            "integrityKey": "precious",
        ])
        partial.failingAccounts = ["integrityKey"]   // 이 항목만 재승인 거부
        AppEnv.setKeychainBackend(partial)

        XCTAssertEqual(Keychain.load(), "old-session")           // 이전 트리거
        XCTAssertEqual(partial.rawValue(account: "integrityKey"), "precious",
                       "읽지 못한 레거시 원본이 삭제됐다 — 영구 유실 경로")
        XCTAssertFalse(partial.storedAccounts.contains("sessionKey"), "읽어서 옮긴 원본은 삭제돼야 한다")
    }

    // 신규 설치는 이전할 것이 없다 — 빈 vault로 시작하고 프롬프트도 없어야 한다.
    func testFreshInstallStartsEmpty() {
        XCTAssertNil(Keychain.load())
        XCTAssertNil(Keychain.loadGitHubToken())
        XCTAssertNil(Keychain.loadRecoveryCode())
    }

    // 손상된 vault JSON은 신규처럼 빈 상태로 취급하되, 접근 실패로 오인하지는 않는다.
    func testCorruptVaultJSONIsTreatedAsEmptyNotFailure() throws {
        Keychain.resetForTesting()
        AppEnv.setKeychainBackend(InMemoryKeychainBackend(seed: ["vault": "{not json"]))
        XCTAssertNil(Keychain.load())
        XCTAssertTrue(Keychain.saveRankingHmacKey("recovered"), "손상 복구 후 쓰기가 막히면 안 된다")
        XCTAssertEqual(Keychain.loadRankingHmacKey(), "recovered")
    }

    // MARK: - 무결성 키

    func testIntegrityKeyIsGeneratedOnceAndPersists() {
        let first = Keychain.loadOrCreateIntegrityKey()
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(Keychain.loadOrCreateIntegrityKey(), first, "호출마다 키가 재생성됐다")
        XCTAssertNotNil(Data(base64Encoded: first), "base64가 아니다")
    }
}
