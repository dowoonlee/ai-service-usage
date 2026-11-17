import XCTest
@testable import ClaudeUsage

/// #293 — 랭킹 등록 후에 GitHub을 연결한 계정이 서버에 그 사실을 전하지 못해 게시판 게이트가
/// 풀리지 않던 문제. 여기서는 "언제 서버에 반영해야 하는가" 판정과 그 판정이 기대는 저장 상태를 고정한다.
@MainActor
final class GitHubServerLinkTests: SandboxedTestCase {

    private func needs(registered: Bool = true, deviceID: String = "dev",
                       local: Int?, server: Int?) -> Bool {
        GitHubServerLink.needsLink(registered: registered, deviceID: deviceID,
                                   localUserID: local, serverLinkedUserID: server)
    }

    /// 버그 그 자체: 등록돼 있고 로컬엔 GitHub이 연결됐는데 서버 반영 기록이 없다.
    func testRegisteredThenLinkedNeedsLink() {
        XCTAssertTrue(needs(local: 42, server: nil))
    }

    func testAlreadyReflectedNeedsNothing() {
        XCTAssertFalse(needs(local: 42, server: 42))
    }

    /// 연결 해제 후 다른 계정으로 다시 연결 — 플래그가 아니라 id 비교라서 잡힌다.
    func testDifferentAccountNeedsLink() {
        XCTAssertTrue(needs(local: 43, server: 42))
    }

    func testNoLocalGitHubNeedsNothing() {
        XCTAssertFalse(needs(local: nil, server: nil))
        XCTAssertFalse(needs(local: nil, server: 42))
    }

    /// 미등록 계정은 register가 GitHub id를 함께 보내므로 별도 반영이 필요 없다.
    func testUnregisteredNeedsNothing() {
        XCTAssertFalse(needs(registered: false, local: 42, server: nil))
        XCTAssertFalse(needs(deviceID: "", local: 42, server: nil))
    }

    /// 기존 사용자(업데이트 직후)는 저장값이 없다 → 연결돼 있으면 첫 사이클에서 반영 대상이 된다.
    func testExistingLinkedUserIsPickedUpAfterUpdate() {
        let s = Settings.shared
        s.rankingRegistered = true
        s.rankingDeviceID = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        s.githubUserID = 42
        XCTAssertNil(s.githubServerLinkedUserID)
        XCTAssertTrue(GitHubServerLink.needsLink)

        s.githubServerLinkedUserID = 42
        XCTAssertFalse(GitHubServerLink.needsLink)
    }

    /// 랭킹 계정을 지우면 서버 반영 기록도 무효 — 재등록 뒤 옛 기록 때문에 반영을 건너뛰면 안 된다.
    func testClearingRankingStateDropsServerLinkRecord() {
        let s = Settings.shared
        s.githubServerLinkedUserID = 42
        s.clearRankingLocalState()
        XCTAssertNil(s.githubServerLinkedUserID)
    }
}
