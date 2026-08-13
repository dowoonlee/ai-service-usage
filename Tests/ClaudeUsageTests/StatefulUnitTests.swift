import XCTest
import CryptoKit
@testable import ClaudeUsage

/// 상태를 만져야 검증되는 것들 — 알림 dedup, 백업 병합, E2EE 왕복.
///
/// 셋 다 `Settings`/`UserDefaults`/`Keychain`을 직접 쓴다는 이유로 그동안 테스트가 없었다.
/// 하네스(`AppEnv`) 도입으로 안전하게 만질 수 있게 된 영역이고, 실패 모드는 각각
/// "알림이 안 오거나 도배된다 / 복구했더니 진행도가 줄었다 / 쪽지를 못 읽는다"라서
/// 사용자가 겪기 전에는 눈에 띄지 않는다.
@MainActor
final class StatefulUnitTests: SandboxedTestCase {

    // ========================================================================
    // 알림 dedup — 같은 주기에 같은 임계치를 두 번 쏘지 않는다
    // ========================================================================

    private let window = Date(timeIntervalSince1970: 1_800_000_000)

    /// 발송 대신 "발송했는가"만 세는 프로브. 실제 알림은 번들이 없는 테스트 프로세스에서
    /// 어차피 no-op이라, dedup 판정 로직만 떼어 본다.
    private func firedThresholds(_ steps: [(Double, Date)], key: String = "test.5h") -> [Int] {
        var fired: [Int] = []
        for (pct, reset) in steps {
            NotificationManager.shared.evaluate(
                key: key, value: pct, resetAt: reset, title: "t",
                bodyMaker: { threshold in fired.append(threshold); return "" })
        }
        return fired
    }

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            Settings.shared.notifyEnabled = true
            Settings.shared.notifyThresholds = [50, 80, 95]
        }
    }

    func testNotifyFiresOncePerThresholdWithinWindow() {
        // 40 → 아무것도 안 넘음 / 55 → 50 / 60 → 이미 50 발송됨 / 85 → 80 / 97 → 95
        let fired = firedThresholds([(40, window), (55, window), (60, window), (85, window), (97, window)])
        XCTAssertEqual(fired, [50, 80, 95])
    }

    /// 한 번에 여러 임계를 넘어도 **가장 높은 것 하나만** 쏜다 — 폴 간격이 10분이라
    /// 50/80/95를 한 사이클에 통과하는 일이 실제로 생긴다. 세 개를 연달아 쏘면 도배가 된다.
    func testNotifyFiresOnlyHighestCrossedInOneStep() {
        XCTAssertEqual(firedThresholds([(10, window), (99, window)]), [95])
    }

    /// 창이 바뀌면(resetAt 변경) 카운터가 리셋돼 같은 임계를 다시 쏜다.
    func testNotifyResetsOnNewWindow() {
        let next = window.addingTimeInterval(5 * 3600)
        XCTAssertEqual(firedThresholds([(60, window), (60, window), (60, next)]), [50, 50])
    }

    /// ISO 타임스탬프는 폴마다 미세하게 흔들린다. 60초 이내 차이는 같은 창으로 봐야
    /// 재발송이 일어나지 않는다.
    func testNotifySubMinuteResetDriftIsSameWindow() {
        XCTAssertEqual(firedThresholds([(60, window), (60, window.addingTimeInterval(30))]), [50])
    }

    func testNotifyRespectsDisabledAndEmptyThresholds() {
        Settings.shared.notifyEnabled = false
        XCTAssertEqual(firedThresholds([(99, window)]), [])

        Settings.shared.notifyEnabled = true
        Settings.shared.notifyThresholds = []
        XCTAssertEqual(firedThresholds([(99, window)], key: "test.other"), [])
    }

    /// 값이나 창이 없으면(첫 폴 실패 등) 아무것도 하지 않는다.
    func testNotifyIgnoresMissingInput() {
        var fired: [Int] = []
        NotificationManager.shared.evaluate(key: "k", value: nil, resetAt: window, title: "t",
                                            bodyMaker: { fired.append($0); return "" })
        NotificationManager.shared.evaluate(key: "k", value: 99, resetAt: nil, title: "t",
                                            bodyMaker: { fired.append($0); return "" })
        XCTAssertEqual(fired, [])
    }


    /// 백업 픽스처 — 필드가 24개라 매번 나열하면 테스트가 안 읽힌다. 기본은 전부 nil(구버전
    /// 백업과 같은 모양)이고, 검증할 항목만 넘긴다.
    private func backup(ownedPets: [String: PetOwnership]? = nil,
                        petUsageSeconds: [String: TimeInterval]? = nil,
                        pendingHighlights: [String]? = nil,
                        petClaudeKind: String? = nil,
                        petClaudeVariant: Int? = nil,
                        coins: Int? = nil,
                        gachaTickets: Int? = nil,
                        premiumTickets: Int? = nil,
                        coinsTotalEarned: Int? = nil,
                        v: Int = 2) -> ProfileState.BackupPayload {
        ProfileState.BackupPayload(
            v: v, ownedPets: ownedPets, petUsageSeconds: petUsageSeconds,
            pendingHighlights: pendingHighlights,
            petClaudeKind: petClaudeKind, petCursorKind: nil,
            petClaudeVariant: petClaudeVariant, petCursorVariant: nil,
            coins: coins, gachaTickets: gachaTickets, premiumTickets: premiumTickets,
            coinsTotalEarned: coinsTotalEarned, firstCreditedAt: nil,
            claimedPodiumPeriods: nil, creditedPRNumbers: nil, completedCollections: nil,
            clearedBadges: nil, masteredRegions: nil, ownedTitles: nil,
            notifyEnabled: nil, notifyThresholds: nil, showMenuBar: nil,
            showGitHubLoginInCard: nil, dailyFortuneLastShownDate: nil)
    }

    // ========================================================================
    // 백업 복원 — 병합은 항상 "진행도가 줄지 않는" 방향
    // ========================================================================

    /// 복구는 다른 기기의 백업을 덮어쓰는 게 아니라 병합한다. 한쪽이라도 앞서 있으면
    /// 그 값을 살려야 한다 — 덮어썼다가는 사용자가 "복구했더니 코인이 줄었다"를 겪는다.
    func testBackupMergeKeepsHigherProgress() {
        let s = Settings.shared
        s.coins = 500
        s.gachaTickets = 1
        s.coinsTotalEarned = 10_000
        s.ownedPets = [.fox: PetOwnership(count: 3, unlockedVariants: [0, 1])]
        s.petUsageSeconds = [.fox: 100]

        s.applyBackup(backup(
            ownedPets: ["fox": PetOwnership(count: 1, unlockedVariants: [0, 2]),
                        "wolf": PetOwnership(count: 5, unlockedVariants: [0])],
            petUsageSeconds: ["fox": 50, "wolf": 900],
            pendingHighlights: ["wolf"],
            petClaudeKind: "wolf", petClaudeVariant: 2,
            coins: 100, gachaTickets: 9, premiumTickets: 2, coinsTotalEarned: 3_000))

        XCTAssertEqual(s.coins, 500, "로컬이 크면 로컬 유지")
        XCTAssertEqual(s.gachaTickets, 9, "원격이 크면 원격 채택")
        XCTAssertEqual(s.premiumTickets, 2, "로컬에 없던 값(구버전 nil 대비)")
        XCTAssertEqual(s.coinsTotalEarned, 10_000)

        // 펫: count는 max, 해금 variant는 합집합 — 어느 쪽에서 연 것이든 닫히면 안 된다.
        XCTAssertEqual(s.ownedPets[.fox]?.count, 3)
        XCTAssertEqual(s.ownedPets[.fox]?.unlockedVariants, [0, 1, 2])
        XCTAssertEqual(s.ownedPets[.wolf]?.count, 5, "로컬에 없던 펫은 그대로 들어온다")
        XCTAssertEqual(s.petUsageSeconds[.fox], 100)
        XCTAssertEqual(s.petUsageSeconds[.wolf], 900)
        XCTAssertTrue(s.pendingHighlights.contains(.wolf))
        XCTAssertEqual(s.petClaudeKind, .wolf, "펫 선택은 백업 의도를 따른다")
    }

    /// 모르는 펫 이름(구버전에서 지워졌거나 다른 빌드에서 온 값)은 조용히 건너뛴다 —
    /// 여기서 죽으면 복구 전체가 실패한다.
    func testBackupSkipsUnknownPetKinds() {
        let s = Settings.shared
        s.ownedPets = [:]
        s.applyBackup(backup(
            ownedPets: ["definitely_not_a_pet": PetOwnership(count: 9, unlockedVariants: [0]),
                        "fox": PetOwnership(count: 2, unlockedVariants: [0])],
            petUsageSeconds: ["definitely_not_a_pet": 100],
            pendingHighlights: ["nope"],
            petClaudeKind: "nope"))

        XCTAssertEqual(s.ownedPets.count, 1)
        XCTAssertEqual(s.ownedPets[.fox]?.count, 2)
    }

    /// 전 필드가 nil인 백업(구버전 스키마)은 아무것도 바꾸지 않는다.
    func testBackupWithAllNilsIsNoOp() {
        let s = Settings.shared
        s.coins = 777
        s.ownedPets = [.fox: .initial()]
        s.applyBackup(backup(v: 1))
        XCTAssertEqual(s.coins, 777)
        XCTAssertEqual(s.ownedPets.count, 1)
    }

    // ========================================================================
    // 쪽지 E2EE — 왕복과 인증
    // ========================================================================

    /// HPKE Auth 모드라 수신자만 복호할 수 있고 발신자 인증까지 붙는다. 키는 Keychain에
    /// 사는데 샌드박스에서는 in-memory라 마음껏 만들 수 있다.
    func testDMSealOpenRoundTrip() throws {
        let myPub = DMCrypto.identityPublicKeyBase64()
        let aad = DMCrypto.aad(senderDevice: "dev-a", recipientDevice: "dev-b")
        // 자기 자신에게 보내는 형태 — 한 키쌍으로 왕복 전체를 검증할 수 있다.
        let blob = try DMCrypto.seal("안녕하세요 🎉 / test", toRecipientPubBase64: myPub, aad: aad)
        XCTAssertEqual(try DMCrypto.open(blob, fromSenderPubBase64: myPub, aad: aad),
                       "안녕하세요 🎉 / test")
    }

    /// aad는 발신·수신 device를 묶는다. 다른 대화로 옮겨 붙인 암호문은 복호되면 안 된다(오배송 방지).
    func testDMRejectsMismatchedAAD() throws {
        let myPub = DMCrypto.identityPublicKeyBase64()
        let blob = try DMCrypto.seal("secret",
                                     toRecipientPubBase64: myPub,
                                     aad: DMCrypto.aad(senderDevice: "dev-a", recipientDevice: "dev-b"))
        XCTAssertThrowsError(try DMCrypto.open(
            blob, fromSenderPubBase64: myPub,
            aad: DMCrypto.aad(senderDevice: "dev-a", recipientDevice: "dev-c")))
    }

    /// 발신자 공개키가 다르면 인증이 깨져 복호 실패해야 한다 — 사칭 차단.
    func testDMRejectsWrongSenderKey() throws {
        let myPub = DMCrypto.identityPublicKeyBase64()
        let blob = try DMCrypto.seal("secret", toRecipientPubBase64: myPub,
                                     aad: DMCrypto.aad(senderDevice: "a", recipientDevice: "b"))
        let otherPub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        XCTAssertThrowsError(try DMCrypto.open(blob, fromSenderPubBase64: otherPub,
                                               aad: DMCrypto.aad(senderDevice: "a", recipientDevice: "b")))
    }

    func testDMRejectsCorruptBlob() {
        let myPub = DMCrypto.identityPublicKeyBase64()
        let aad = DMCrypto.aad(senderDevice: "a", recipientDevice: "b")
        for bad in ["", "!!not base64!!", Data([0x02, 0x00]).base64EncodedString()] {
            XCTAssertThrowsError(try DMCrypto.open(bad, fromSenderPubBase64: myPub, aad: aad), bad)
        }
    }

    /// 신원 키는 한 번 만들면 유지된다 — 매번 새로 만들면 기존 대화가 전부 복호 불가가 된다.
    func testDMIdentityKeyIsStable() {
        let first = DMCrypto.identityPublicKeyBase64()
        XCTAssertEqual(DMCrypto.identityPublicKeyBase64(), first)
        XCTAssertEqual(Data(base64Encoded: first)?.count, 32, "X25519 raw 32B")
    }

    /// 지문은 표시 전용이지만 대역외 검증에 쓰이므로 같은 키에서 항상 같아야 한다.
    func testDMFingerprintIsDeterministic() {
        let pub = DMCrypto.identityPublicKeyBase64()
        let fp = DMCrypto.fingerprint(ofPubBase64: pub)
        XCTAssertEqual(DMCrypto.fingerprint(ofPubBase64: pub), fp)
        XCTAssertFalse(fp.isEmpty)
    }
}
