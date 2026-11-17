import Foundation

/// 로컬 GitHub 연결을 서버 랭킹 계정(`users.github_login`)에 맞추는 조정자(#293).
///
/// 서버가 GitHub 연결을 알게 되는 경로는 원래 `register`(등록 시점에 이미 연결돼 있던 경우)와
/// `recover-by-github`뿐이었다. 그래서 **랭킹 등록 → 나중에 GitHub 연결** 순서로 온 계정은
/// 설정에 "연결됨"이 떠도 서버는 미연동으로 보고, 게시판 쓰기 게이트가 풀리지 않았다.
///
/// 연결 직후(`GitHubLinkView`)에 한 번 부르는 것만으로는 부족하다 — 이미 그 상태로 굳어 있는
/// 기존 사용자는 다시 연결할 일이 없다. 그래서 폴링 사이클에서도 불러 스스로 낫게 한다.
/// 판정은 `Settings.githubServerLinkedUserID != githubUserID` 하나이고, 맞춰진 뒤엔 호출이 없다.
@MainActor
enum GitHubServerLink {
    /// 일시 실패(네트워크·서버 5xx·함수 미배포) 후 자동 재시도 간격. 폴링 사이클(600s)마다
    /// Edge Function을 두드리지 않도록 한다.
    static let retryIntervalSec: TimeInterval = 3600

    private static var lastAttemptAt: Date?
    private static var inFlight = false
    /// 서버가 확정적으로 거부한 GitHub user id — 같은 id로는 이번 실행 동안 자동 재시도하지 않는다
    /// (다른 랭킹 계정에 이미 연결됨 / 토큰 무효). 사용자가 직접 누른 재시도(`force`)는 통과.
    private static var rejectedUserID: Int?

    /// 서버에 연결을 반영해야 하는 상태인지 (순수 판정 — 테스트 대상).
    nonisolated static func needsLink(registered: Bool, deviceID: String,
                                      localUserID: Int?, serverLinkedUserID: Int?) -> Bool {
        guard registered, !deviceID.isEmpty, let localUserID else { return false }
        return localUserID != serverLinkedUserID
    }

    static var needsLink: Bool {
        let s = Settings.shared
        return needsLink(registered: s.rankingRegistered, deviceID: s.rankingDeviceID,
                         localUserID: s.githubUserID, serverLinkedUserID: s.githubServerLinkedUserID)
    }

    /// 필요하면 서버에 연결을 반영한다. 반환값은 사용자에게 보여줄 실패 사유(성공·불필요·보류는 nil).
    /// - Parameter force: 사용자가 직접 요청한 경우 — 재시도 간격과 거부 기록을 무시한다.
    @discardableResult
    static func reconcileIfNeeded(force: Bool = false) async -> String? {
        let s = Settings.shared
        guard RankingAPI.isConfigured, needsLink, !inFlight,
              let userID = s.githubUserID else { return nil }
        if !force {
            if rejectedUserID == userID { return nil }
            if let last = lastAttemptAt, Date().timeIntervalSince(last) < retryIntervalSec { return nil }
        }
        guard let token = Keychain.loadGitHubToken(),
              let hmacKey = Keychain.loadRankingHmacKey() else {
            return force ? "키체인에서 인증 정보를 읽지 못했습니다. 키체인 접근을 승인한 뒤 다시 시도해 주세요." : nil
        }
        inFlight = true
        lastAttemptAt = Date()
        defer { inFlight = false }
        do {
            let resp = try await RankingAPI.shared.linkGitHub(
                deviceId: s.rankingDeviceID, githubToken: token, hmacKeyBase64: hmacKey)
            // await 사이에 사용자가 연결을 해제·교체했으면 반영하지 않는다 — 다음 판정이 다시 잡는다.
            guard s.githubUserID == resp.githubUserId else { return nil }
            s.githubServerLinkedUserID = resp.githubUserId
            if s.githubLogin != resp.githubLogin { s.githubLogin = resp.githubLogin }
            rejectedUserID = nil
            DebugLog.log("GitHubServerLink: 서버 랭킹 계정에 GitHub 연결 반영")
            return nil
        } catch let e as RankingAPI.RankingError {
            switch e {
            case .githubLinkedElsewhere, .githubTokenRejected:
                rejectedUserID = userID
            default:
                break
            }
            DebugLog.log("GitHubServerLink: 반영 실패 — \(e.localizedDescription)")
            return e.localizedDescription
        } catch {
            DebugLog.log("GitHubServerLink: 반영 실패 — \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
}
