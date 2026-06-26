import Foundation
import CryptoKit

/// 글로벌 랭킹 보드용 Supabase 클라이언트.
///
/// 인증 모델은 `UsageAPI`/`CursorAPI`와 다름 — Supabase anon key + per-install HMAC 키
/// 조합. 옵트인 시점에 서버 register → recovery code + HMAC 키 발급, 이후 모든 submit은
/// payload를 HMAC-SHA256으로 서명. 어뷰징의 1차 방어선이지만 클라이언트 patch에는 무력 —
/// 서버측 시간 비례 하드캡(elapsed × max_natural_rate × margin)이 실제 방어선.
///
/// Info.plist 키:
///   - `SupabaseURL`        — 프로젝트 URL (e.g. https://xxx.supabase.co)
///   - `SupabaseAnonKey`    — anon 공개 키 (브라우저 노출 OK, Row Level Security가 권한 통제)
///   - `PrivacyPolicyURL`   — 옵트인 동의 화면에서 노출할 처리방침 URL
///
/// 위 3개가 모두 비어 있으면 `isConfigured == false` → UI는 "이 빌드는 랭킹 미지원" 안내만.
actor RankingAPI {
    static let shared = RankingAPI()

    static var baseURL: URL? {
        guard var s = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
              !s.isEmpty else { return nil }
        // Data API URL을 통째로 박은 경우(끝에 `/rest/v1/` 붙음) 자동 정규화 —
        // sanity_check_ranking.sh와 동일 로직. 사용자 실수 방어.
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/rest/v1") { s.removeLast("/rest/v1".count) }
        if s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
    static var anonKey: String? {
        let s = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String
        return (s?.isEmpty == false) ? s : nil
    }
    static var privacyPolicyURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "PrivacyPolicyURL") as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }
    static var isConfigured: Bool { baseURL != nil && anonKey != nil }

    /// 버전 텔레메트리 — submit 시 서버로 전송. dev 실행(번들 없음)은 nil.
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    /// macOS major.minor.patch (예: "14.4.1"). build 번호는 분포 over-fragment 방지 위해 제외.
    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    // MARK: - Models

    struct RegisterRequest: Encodable {
        let deviceId: String
        let nickname: String
        let githubLogin: String?
        let githubUserId: Int?
        /// 옵트인 시점의 `coinsTotalEarned`. 서버는 그대로 total_coins로 저장 (누적값 인정).
        /// 1M cap (서버측).
        let initialCoins: Int?
        let profileJson: ProfileState?
    }
    struct RegisterResponse: Decodable {
        let hmacKey: String
        let recoveryCode: String
        let nickname: String
    }

    struct SubmitPayload: Encodable {
        let deviceId: String
        let delta: Int
        let prevTotal: Int
        let ts: Int64
    }
    struct SubmitRequest: Encodable {
        let payload: SubmitPayload
        let signature: String
        /// payload 외부 — HMAC 서명 대상 아님. 변조 위험 작아 display data로 수용.
        let profileJson: ProfileState?
        /// 클라이언트 버전 텔레메트리 (서명 대상 밖). 서버가 users.app_version/os_version에 저장.
        /// dev 실행(번들 없음)·delete 경로는 nil.
        let appVersion: String?
        let osVersion: String?
    }
    struct SubmitResponse: Decodable {
        let accepted: Bool
        let totalCoins: Int
        let rejectReason: String?
    }

    struct LeaderboardEntry: Decodable, Identifiable, Sendable {
        let rank: Int
        let nickname: String
        let totalCoins: Int
        let githubLogin: String?
        /// 트레이너 카드 + stats — 보드 행/팝오버 렌더링 입력. 미옵트인/구버전 사용자는 nil.
        let profileJson: ProfileState?
        /// 누적 금/은/동 메달 — 서버 `monthly_winners` 집계. 구버전 서버는 미반환 → nil.
        let medals: MedalTally?
        var id: Int { rank }
    }
    struct LeaderboardResponse: Decodable {
        let entries: [LeaderboardEntry]
        let myRank: Int?
        let myTotalCoins: Int?
        /// 본인 누적 메달 — 보드에 없어도(이번 달 0 VP) deviceId로 집계해 내려준다. 구버전 서버 nil.
        let myMedals: MedalTally?
        let total: Int
        /// "monthly" — 현재 운영 중인 보드 종류. 추후 weekly/all-time 추가 시 확장.
        let period: String?
        /// 다음 리셋 시각 (UTC ISO 8601). 보드 헤더의 "리셋까지" 카운트다운 표시용.
        let periodResetAt: Date?
        /// 직전 달 명예의 전당 — Top 3 동결 기록.
        let previousMonth: PreviousMonth?
        /// 본인의 미수령 보상 — 옵트인 + 이전 달 Top 3 진입 시 1개 row.
        let pendingReward: PendingReward?
        /// 본인의 미수령 RP 보상 — 랭킹 순위 정산(월간/주간). coins와 별도 원장. 구버전 서버 nil.
        let pendingRpReward: PendingRpReward?
    }

    struct PreviousMonth: Decodable, Sendable {
        let period: String                  // "YYYY-MM"
        /// 요청자가 이 시상대 우승자면 그 rank(1/2/3), 아니면 nil. "내 칸 한마디 등록" 판정용.
        /// 구버전 서버는 미반환 → nil.
        let myRank: Int?
        let entries: [PreviousMonthEntry]
    }

    struct PreviousMonthEntry: Decodable, Identifiable, Sendable {
        let rank: Int
        let nickname: String
        let totalCoins: Int                 // 직전 달 최종 VP
        let githubLogin: String?
        let profileJson: ProfileState?
        let rewardCoins: Int
        /// 우승자가 등록한 시상대 한마디. 미등록/구버전 서버는 nil.
        let message: String?
        var id: Int { rank }
    }

    struct PendingReward: Decodable, Sendable {
        let period: String                  // "YYYY-MM"
        let rank: Int                       // 1/2/3
        let coins: Int                      // 보상 코인
        /// dedup key — "YYYY-MM.rank" 형식. Settings.claimedPodiumPeriods에 매칭.
        var dedupKey: String { "\(period).\(rank)" }
    }

    struct PendingRpReward: Decodable, Sendable {
        let period: String                  // 월간 "YYYY-MM" / 주간 "IYYY-Www"
        let periodType: String              // "monthly" | "weekly"
        let rank: Int                       // 전체 순위 (1~)
        let rp: Int                         // 보상 RP
        /// dedup key — "type.period.rank" 형식. Settings.claimedRpRewards에 매칭.
        var dedupKey: String { "\(periodType).\(period).\(rank)" }
    }

    struct ClaimRewardPayload: Encodable {
        let deviceId: String
        let period: String
        let rank: Int
        let ts: Int64
    }
    struct ClaimRewardRequest: Encodable {
        let payload: ClaimRewardPayload
        let signature: String
        /// "coins"(기본) | "rp" — 서명 페이로드 밖 라우팅 필드 (서버가 어느 원장에서 수령할지 결정).
        let rewardType: String?
    }
    struct ClaimRewardResponse: Decodable {
        let alreadyClaimed: Bool
        let rewardType: String?      // "coins" | "rp" (구버전 서버 nil)
        let rewardCoins: Int?        // coins claim 시
        let rp: Int?                 // rp claim 시
        let claimedAt: String
    }

    struct SetPodiumMessagePayload: Encodable {
        let deviceId: String
        let message: String
        let period: String
        let rank: Int
        let ts: Int64
    }
    struct SetPodiumMessageRequest: Encodable {
        let payload: SetPodiumMessagePayload
        let signature: String
    }
    struct SetPodiumMessageResponse: Decodable {
        /// 이미 등록돼 변경 불가였는지(immutable). true면 서버의 기존 값이 `message`로 옴.
        let alreadySet: Bool
        let message: String
    }

    // MARK: - Board models

    struct BoardLiker: Decodable, Sendable, Hashable {
        let nickname: String
        let createdAt: Date
    }

    struct BoardPost: Decodable, Identifiable, Sendable {
        let id: Int
        let nickname: String
        let content: String
        let createdAt: Date
        let isMine: Bool
        let likeCount: Int
        let likedByMe: Bool
        /// 호버 popover에서 누른 사람 표시. 시간순(오래된 것 → 최근).
        let likers: [BoardLiker]
    }

    struct BoardResponse: Decodable, Sendable {
        let posts: [BoardPost]
        /// 본인의 다음 글 작성까지 남은 초. 0이면 즉시 작성 가능. 미등록 사용자는 0.
        let cooldownRemainingSec: Int
        /// 게시판 표시 윈도우(시간 단위). 서버가 권위 — UI 문구를 이 값으로 동적 생성.
        /// optional은 구버전 서버 호환용 — nil이면 BoardView가 기본 라벨(24h) 사용.
        let displayWindowHours: Int?
        /// 글 작성 후 다음 글까지 cooldown 정책값(초). 작성 직후 클라이언트 카운트다운
        /// 초기치로 사용. nil이면 BoardView fallback(600s).
        let postCooldownSec: Int?
        /// 본인 글 작성 후 삭제 가능한 윈도우(초). BoardRow 삭제 버튼 노출 여부 판정.
        /// nil이면 BoardView fallback(60s).
        let deletePostWindowSec: Int?
    }

    struct PostBoardPayload: Encodable {
        let content: String
        let deviceId: String
        let ts: Int64
    }
    struct PostBoardRequest: Encodable {
        let payload: PostBoardPayload
        let signature: String
    }
    struct PostBoardResponse: Decodable {
        let accepted: Bool
        let postId: Int?
        let createdAt: Date?
    }

    struct LikePayload: Encodable {
        let deviceId: String
        let postId: Int
        let ts: Int64
    }
    struct LikeRequest: Encodable {
        let payload: LikePayload
        let signature: String
    }
    struct LikeResponse: Decodable {
        let liked: Bool
        let count: Int
    }

    struct DeletePostPayload: Encodable {
        let deviceId: String
        let postId: Int
        let ts: Int64
    }
    struct DeletePostRequest: Encodable {
        let payload: DeletePostPayload
        let signature: String
    }
    struct DeletePostResponse: Decodable {
        let deleted: Bool
    }

    struct RecoverByCodeRequest: Encodable {
        let recoveryCode: String
        let newDeviceId: String
    }
    struct RecoverByGitHubRequest: Encodable {
        let githubToken: String
        let newDeviceId: String
    }
    struct PeekByGitHubRequest: Encodable {
        let githubToken: String
    }
    /// peek-by-github 응답 — 복원 전 컨펌 다이얼로그에 표시할 메타데이터.
    /// 서버는 이 호출에서 변경을 만들지 않는다. 실제 hmac_key rotation은 별도 recover 호출에서.
    struct GitHubAccountPeek: Decodable, Sendable, Equatable {
        let nickname: String
        let totalCoins: Int
        /// 마지막 백업 시점 (last_submitted_at, 없으면 registered_at).
        let backupAt: Date
        let githubLogin: String
    }
    struct RecoverResponse: Decodable {
        /// 서버측 권위 있는 device_id. 클라이언트가 보낸 newDeviceId는 무시되고 기존 값이
        /// 반환됨 → 클라이언트는 이걸 받아 로컬 `rankingDeviceID`에 저장해야 함. 서버측
        /// submissions FK 변경 없이 hmac_key만 rotate하는 설계.
        let deviceId: String
        let hmacKey: String
        let nickname: String
        let totalCoins: Int
        /// 백업 복원용 — `ProfileState.backup`에 펫 인벤토리·코인 잔액·설정이 들어있음.
        /// 옛 서버 또는 등록 시점에 아직 profileJson을 안 보낸 사용자는 nil.
        let profileJson: ProfileState?
    }

    // MARK: - Errors

    enum RankingError: LocalizedError {
        case notConfigured
        case notRegistered
        case nicknameTaken
        case invalidRecoveryCode
        case banned
        case privacyNotAccepted
        /// 게시판 cooldown 위반 (10분 / post). retryAfterSec은 서버가 응답 body에 포함.
        case rateLimited(retryAfterSec: Int)
        case http(Int, String?)
        case decoding(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:       return "랭킹 기능이 이 빌드에 포함되지 않았습니다."
            case .notRegistered:       return "랭킹 등록이 필요합니다."
            case .nicknameTaken:       return "이미 사용 중인 닉네임입니다."
            case .invalidRecoveryCode: return "복구 코드가 올바르지 않습니다."
            case .banned:              return "이 계정은 운영 정책 위반으로 차단되었습니다."
            case .privacyNotAccepted:  return "처리방침 동의가 필요합니다."
            case .rateLimited(let s):
                let m = s / 60, r = s % 60
                if m > 0 { return "다음 글 작성까지 \(m)분 \(r)초 남았습니다." }
                return "다음 글 작성까지 \(r)초 남았습니다."
            case .http(let code, let msg):
                return "서버 오류 \(code)\(msg.map { ": \($0)" } ?? "")"
            case .decoding(let s):     return "응답 디코딩 오류: \(s)"
            case .network(let s):      return "네트워크 오류: \(s)"
            }
        }
    }

    // MARK: - Public API

    /// 첫 옵트인 시 호출. 서버가 hmacKey + recoveryCode 발급. 성공 시 Keychain/Settings 갱신.
    /// 닉네임 중복 시 `.nicknameTaken` throw — 호출 측이 다른 닉네임으로 재시도.
    func register(deviceId: String, nickname: String,
                  githubLogin: String?, githubUserId: Int?,
                  initialCoins: Int?, profileJson: ProfileState?) async throws -> RegisterResponse {
        let req = RegisterRequest(deviceId: deviceId, nickname: nickname,
                                  githubLogin: githubLogin, githubUserId: githubUserId,
                                  initialCoins: initialCoins, profileJson: profileJson)
        return try await post(path: "register", body: req)
    }

    /// 폴링 cycle 직후 호출 (fire-and-forget). delta = 현재 coinsTotalEarned - lastSubmittedTotal.
    /// delta <= 0이면 호출 측에서 skip — 여기까지 와도 서버가 0을 거부할 수도 있어서.
    /// profileJson은 매 호출마다 최신 ProfileState 전달 (display 갱신).
    func submitDelta(deviceId: String, delta: Int, prevTotal: Int,
                     hmacKeyBase64: String, profileJson: ProfileState?) async throws -> SubmitResponse {
        let payload = SubmitPayload(deviceId: deviceId, delta: delta, prevTotal: prevTotal,
                                    ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.sign(payload: payload, keyBase64: hmacKeyBase64)
        let req = SubmitRequest(payload: payload, signature: sig, profileJson: profileJson,
                                appVersion: Self.appVersion, osVersion: Self.osVersion)
        return try await post(path: "submit", body: req)
    }

    /// 진단 샘플 제출 (이슈 #36 + 버그리포트 통합). codex_voluntary·bug_report 공용.
    /// 보상이 없어 HMAC 서명 없이 anon key POST. fire-and-forget 성격이지만 호출 측이
    /// 성공/실패를 표시할 수 있게 throw는 전파한다.
    func submitDiagnostic(_ sample: DiagnosticSample) async throws {
        try await postVoid(path: "codex-sample", body: sample)
    }

    /// Top N + 내 순위. 페이지네이션 없이 한 번에 받음 (50명 규모라 부담 없음).
    func fetchLeaderboard(deviceId: String?) async throws -> LeaderboardResponse {
        let q = deviceId.map { [URLQueryItem(name: "deviceId", value: $0)] }
        return try await get(path: "leaderboard", queryItems: q)
    }

    /// 새 device에서 복구 코드 입력 → 서버가 새 device_id로 hmacKey 재발급. 기존 hmacKey 무효화.
    func recoverWithRecoveryCode(_ code: String, newDeviceId: String) async throws -> RecoverResponse {
        let req = RecoverByCodeRequest(recoveryCode: code, newDeviceId: newDeviceId)
        do {
            return try await post(path: "recover-by-code", body: req)
        } catch RankingError.http(404, _) {
            throw RankingError.invalidRecoveryCode
        }
    }

    /// 새 device에서 GitHub OAuth 토큰 → 서버가 GitHub API로 user 확인 → 매칭 user에 재발급.
    func recoverWithGitHub(token: String, newDeviceId: String) async throws -> RecoverResponse {
        let req = RecoverByGitHubRequest(githubToken: token, newDeviceId: newDeviceId)
        do {
            return try await post(path: "recover-by-github", body: req)
        } catch RankingError.http(404, _) {
            throw RankingError.invalidRecoveryCode
        }
    }

    /// 복원 전 컨펌용 — 토큰으로 매칭되는 계정 메타(닉네임·코인·마지막 백업 시점) 조회만. 변경 없음.
    /// 호출 후 사용자에게 "X 시점으로 복원하시겠습니까?" 다이얼로그를 띄우고, OK 클릭 시
    /// `recoverWithGitHub`로 진행한다.
    func peekGitHubAccount(token: String) async throws -> GitHubAccountPeek {
        let req = PeekByGitHubRequest(githubToken: token)
        do {
            return try await post(path: "peek-by-github", body: req)
        } catch RankingError.http(404, _) {
            throw RankingError.invalidRecoveryCode
        }
    }

    /// 명예의 전당 보상 수령. 클라이언트가 reward 알림 + credit 후 호출.
    /// 이미 claim된 경우 서버가 `alreadyClaimed=true`로 idempotent 응답 — 클라이언트는 무시 가능.
    func claimReward(deviceId: String, period: String, rank: Int,
                     rewardType: String = "coins",
                     hmacKeyBase64: String) async throws -> ClaimRewardResponse {
        // 서명 페이로드는 {deviceId, period, rank, ts}로 불변 — rewardType은 서명에 넣지 않는다
        // (서버 verifyHmac과 일치 + 기존 coins claim 호환). rewardType은 request 레벨 라우팅 필드.
        let payload = ClaimRewardPayload(deviceId: deviceId, period: period, rank: rank,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signClaim(payload: payload, keyBase64: hmacKeyBase64)
        let req = ClaimRewardRequest(payload: payload, signature: sig, rewardType: rewardType)
        return try await post(path: "claim-reward", body: req)
    }

    /// 시상대 한마디 1회 등록. 본인이 그 (period, rank) 우승자일 때만 서버가 수락.
    /// 이미 등록된 경우 `alreadySet=true`로 기존 값 반환(immutable). `message`는 trim된 상태로 전달.
    func setPodiumMessage(deviceId: String, period: String, rank: Int, message: String,
                          hmacKeyBase64: String) async throws -> SetPodiumMessageResponse {
        let payload = SetPodiumMessagePayload(deviceId: deviceId, message: message, period: period,
                                              rank: rank, ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signPodium(payload: payload, keyBase64: hmacKeyBase64)
        let req = SetPodiumMessageRequest(payload: payload, signature: sig)
        return try await post(path: "set-podium-message", body: req)
    }

    // MARK: - Board

    /// 최근 N개 글 + 좋아요 정보. deviceId가 있으면 isMine/likedByMe/cooldownRemainingSec 채워짐.
    func fetchBoard(deviceId: String?) async throws -> BoardResponse {
        let q = deviceId.map { [URLQueryItem(name: "deviceId", value: $0)] }
        return try await get(path: "board", queryItems: q)
    }

    // MARK: - 펫 메타데이터 (실험: 서버 override)

    struct PetMetadataRow: Decodable, Sendable {
        let kind: String
        let displayName: String
        let description: String
        let quotes: [String]
    }
    struct PetMetadataResponse: Decodable, Sendable {
        let pets: [PetMetadataRow]
    }

    /// 전 사용자 공통 펫 메타데이터(이름/대사/설명). 읽기 전용 public — HMAC 불필요.
    func fetchPetMetadata() async throws -> PetMetadataResponse {
        try await get(path: "pet-metadata")
    }

    // MARK: - 패치 공지 (announcements)

    struct AnnouncementRow: Decodable, Sendable {
        let version: String
        let title: String
        let body: String
        let publishedAt: Date
    }
    struct AnnouncementsResponse: Decodable, Sendable {
        /// 새 공지 — (since, current] 미열람 구간(최신 버전 먼저). 창 표시 여부는 이게 비어있는지로 판단.
        let announcements: [AnnouncementRow]
        /// 이전(이미 본) 공지 — since 이하 최근 N개. 구버전 서버는 미반환 → nil.
        let previous: [AnnouncementRow]?
    }

    /// 패치 공지. 새 공지(since, current] + 이전 공지(since 이하 최근 `previousCount`개)를 함께 받는다.
    /// 읽기 전용 public — HMAC 불필요. 서버가 semver 필터링하므로 새 공지가 빈 배열일 수 있음.
    func fetchAnnouncements(currentVersion: String, sinceVersion: String,
                            previousCount: Int) async throws -> AnnouncementsResponse {
        let q = [
            URLQueryItem(name: "current", value: currentVersion),
            URLQueryItem(name: "since", value: sinceVersion),
            URLQueryItem(name: "previous", value: String(previousCount)),
        ]
        return try await get(path: "announcements", queryItems: q)
    }

    /// 확성기 브라우즈용 — 전체 활성 공지(최신순). `since` 없이 호출하므로 모두 `announcements`로 온다.
    /// currentVersion이 있으면 그 버전 이하만(아직 못 받은 상위 버전 노트는 숨김), 없으면(dev) 전체.
    func fetchRecentAnnouncements(currentVersion: String?) async throws -> [AnnouncementRow] {
        var q: [URLQueryItem] = []
        if let v = currentVersion, !v.isEmpty { q.append(URLQueryItem(name: "current", value: v)) }
        let resp: AnnouncementsResponse = try await get(path: "announcements", queryItems: q.isEmpty ? nil : q)
        return resp.announcements
    }

    /// 게시글 작성. content는 trim 전 그대로 전송 — 서버가 trim + 검증.
    /// rate limit 위반 시 `.rateLimited(retryAfterSec:)` throw.
    func submitBoardPost(deviceId: String, content: String,
                         hmacKeyBase64: String) async throws -> PostBoardResponse {
        let payload = PostBoardPayload(content: content, deviceId: deviceId,
                                       ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = PostBoardRequest(payload: payload, signature: sig)
        return try await post(path: "post", body: req)
    }

    /// 좋아요 toggle. 서버가 INSERT/DELETE 결정. 응답의 (liked, count)로 UI 동기화.
    func likeBoardPost(deviceId: String, postId: Int,
                       hmacKeyBase64: String) async throws -> LikeResponse {
        let payload = LikePayload(deviceId: deviceId, postId: postId,
                                  ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = LikeRequest(payload: payload, signature: sig)
        return try await post(path: "like", body: req)
    }

    /// 본인 글 1분 이내 삭제. 윈도우 만료/타인 글이면 서버가 403 → `.http(403, _)` throw.
    /// 좋아요는 FK CASCADE로 자동 정리.
    func deleteBoardPost(deviceId: String, postId: Int,
                         hmacKeyBase64: String) async throws -> DeletePostResponse {
        let payload = DeletePostPayload(deviceId: deviceId, postId: postId,
                                        ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = DeletePostRequest(payload: payload, signature: sig)
        return try await post(path: "delete-post", body: req)
    }

    /// 계정 영구 삭제. 서버측 row + submissions 로그 모두 제거.
    func deleteAccount(deviceId: String, hmacKeyBase64: String) async throws {
        let payload = SubmitPayload(deviceId: deviceId, delta: 0, prevTotal: 0,
                                    ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.sign(payload: payload, keyBase64: hmacKeyBase64)
        let req = SubmitRequest(payload: payload, signature: sig, profileJson: nil,
                                appVersion: nil, osVersion: nil)
        try await postVoid(path: "delete", body: req)
    }

    /// 429 응답 body 디코딩용. Swift는 generic 함수 내부 nested struct 불가 → outer scope에 둠.
    private struct RateLimitedBody: Decodable { let retryAfterSec: Int? }

    // MARK: - HMAC

    /// payload를 sortedKeys JSON으로 정렬 후 HMAC-SHA256. 서버측도 동일 규칙으로 검증.
    /// hex 소문자 출력.
    static func sign(payload: SubmitPayload, keyBase64: String) throws -> String {
        try signEncodable(payload, keyBase64: keyBase64)
    }

    /// ClaimRewardPayload 서명. 위 sign과 동일 알고리즘이지만 별도 타입.
    static func signClaim(payload: ClaimRewardPayload, keyBase64: String) throws -> String {
        try signEncodable(payload, keyBase64: keyBase64)
    }

    /// SetPodiumMessagePayload 서명. 동일 알고리즘.
    static func signPodium(payload: SetPodiumMessagePayload, keyBase64: String) throws -> String {
        try signEncodable(payload, keyBase64: keyBase64)
    }

    private static func signEncodable<T: Encodable>(_ payload: T, keyBase64: String) throws -> String {
        guard let keyData = Data(base64Encoded: keyBase64) else {
            throw RankingError.decoding("invalid HMAC key base64")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try enc.encode(payload)
        let key = SymmetricKey(data: keyData)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return Data(mac).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - HTTP helpers

    /// 서명은 body 내부 `signature` 필드로 전달되며 헤더에는 anon key만 실음 — 호출 측에서
    /// `signed` 플래그를 따로 넘길 필요 없음 (v0.8.12 dead parameter 정리).
    private func buildPostRequest<Req: Encodable>(path: String, body: Req) throws -> URLRequest {
        guard let base = Self.baseURL, let anon = Self.anonKey else {
            throw RankingError.notConfigured
        }
        let url = base.appendingPathComponent("functions/v1/\(path)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(anon)", forHTTPHeaderField: "Authorization")
        req.setValue(anon, forHTTPHeaderField: "apikey")

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            req.httpBody = try enc.encode(body)
        } catch {
            throw RankingError.decoding("encode: \(error.localizedDescription)")
        }
        return req
    }

    private func post<Req: Encodable, Resp: Decodable>(path: String, body: Req) async throws -> Resp {
        let req = try buildPostRequest(path: path, body: body)
        return try await execute(req)
    }

    /// 응답 본문이 없는 endpoint 전용. `deleteAccount` 등에서 사용.
    private func postVoid<Req: Encodable>(path: String, body: Req) async throws {
        let req = try buildPostRequest(path: path, body: body)
        try await executeVoid(req)
    }

    private func get<Resp: Decodable>(path: String, queryItems: [URLQueryItem]? = nil) async throws -> Resp {
        guard let base = Self.baseURL, let anon = Self.anonKey else {
            throw RankingError.notConfigured
        }
        // appendingPathComponent로 path만 붙이고, query는 URLComponents로 따로 구성.
        // 단순 문자열 결합 시 `?`가 percent-encode되어 path의 일부가 되는 버그를 회피.
        let pathURL = base.appendingPathComponent("functions/v1/\(path)")
        var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let url = components?.url else { throw RankingError.notConfigured }
        var req = URLRequest(url: url)
        // 라이브 데이터(리더보드/게시판/운세) — 캐시된 옛 응답을 절대 쓰지 않는다.
        // 기본 정책은 URLSession.shared의 URLCache가 Cache-Control 없는 200 GET을 heuristic
        // 캐시해 새 필드(previousMonth.myRank 등)가 없는 옛 응답을 계속 내보내는 문제가 있었다.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(anon)", forHTTPHeaderField: "Authorization")
        req.setValue(anon, forHTTPHeaderField: "apikey")
        return try await execute(req)
    }

    // MARK: - 오늘의 개발 운세

    /// `daily_fortunes` row. 서버측에서 camelCase 변환 + `sajuJson` 은 다시 문자열로 직렬화.
    struct FortuneRow: Decodable, Sendable {
        let deviceId: String
        let fortuneDate: String     // "YYYY-MM-DD"
        let sajuJson: String        // SajuChart JSON
        let fortuneText: String
        let model: String?
        let createdAt: Date
        let cached: Bool            // 서버 캐시 hit 였는지 — 클라이언트 표시용 (선택)
    }

    struct FortuneResponse: Decodable, Sendable {
        let row: FortuneRow
    }

    private struct FortunePayload: Encodable {
        let date: String
        let dailyJson: String
        let deviceId: String
        let sajuJson: String
        let ts: Int64
    }
    private struct FortuneRequest: Encodable {
        let payload: FortunePayload
        let signature: String
    }

    /// 운세 한 번에 요청 — 서버가 (deviceId, date) row 조회 → 없으면 OpenAI 호출 → save → 반환.
    /// OpenAI 키는 서버 환경변수에 박혀 있어 클라이언트가 알 필요 없음.
    /// `sajuJson`/`dailyJson` 은 클라이언트가 결정론적 계산 후 JSON 문자열로 전달 (프롬프트 변수).
    func requestFortune(deviceId: String, hmacKeyBase64: String, date: String,
                        sajuJson: String, dailyJson: String) async throws -> FortuneRow {
        let payload = FortunePayload(
            date: date, dailyJson: dailyJson, deviceId: deviceId,
            sajuJson: sajuJson, ts: Int64(Date().timeIntervalSince1970)
        )
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = FortuneRequest(payload: payload, signature: sig)
        let resp: FortuneResponse = try await post(path: "fortune", body: req)
        return resp.row
    }

    /// 응답 statusline + body 만 검증. 본문 디코드가 없는 endpoint(`executeVoid`)와
    /// 공유하기 위해 추출. 404는 호출 측이 body 메시지로 분기 매핑하므로 여기선
    /// generic `.http(404, body)`만 throw — 사용자에게 정확한 메시지 노출.
    private func validateHTTPStatus(data: Data, response: URLResponse) throws {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0

        if code == 409 { throw RankingError.nicknameTaken }
        if code == 403 { throw RankingError.banned }
        if code == 412 { throw RankingError.privacyNotAccepted }
        if code == 429 {
            let s = (try? JSONDecoder().decode(RateLimitedBody.self, from: data))?.retryAfterSec ?? 60
            throw RankingError.rateLimited(retryAfterSec: s)
        }
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8)
            throw RankingError.http(code, body)
        }
    }

    /// 응답 본문이 없는 endpoint 전용 (`delete` 등). `execute<Resp>`의 generic 분기에서
    /// `EmptyResponse() as! Resp` force cast로 처리하던 경로를 타입 안전하게 분리.
    private func executeVoid(_ req: URLRequest) async throws {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RankingError.network(error.localizedDescription)
        }
        try validateHTTPStatus(data: data, response: response)
    }

    private func execute<Resp: Decodable>(_ req: URLRequest) async throws -> Resp {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RankingError.network(error.localizedDescription)
        }
        try validateHTTPStatus(data: data, response: response)
        let decoder = JSONDecoder()
        // Deno `new Date().toISOString()` 은 항상 fractional seconds 포함("…35.123Z").
        // PostgreSQL timestamptz 응답은 미세 분수초 또는 없는 형태 둘 다 가능.
        // `.iso8601` 기본은 fractional seconds 미지원 → fortune 응답 같은 곳에서 decode 실패.
        // 두 포맷 모두 지원하는 custom strategy 로 둘 다 커버.
        decoder.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let d = Self.iso8601WithFractional.date(from: s) { return d }
            if let d = Self.iso8601Basic.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(
                in: try dec.singleValueContainer(),
                debugDescription: "Invalid ISO 8601 date: \(s)"
            )
        }
        do {
            return try decoder.decode(Resp.self, from: data)
        } catch {
            // 디코딩 실패 raw 를 마스킹·캡해 stash — 버그리포트에서 첨부(#56). throw 동작은 불변.
            Self.captureDecodeFailure(req: req, data: data, response: response, error: error)
            throw RankingError.decoding(error.localizedDescription)
        }
    }

    /// 랭킹 응답 디코딩 실패 순간의 페이로드를 PII 마스킹 후 1건 보관(#56 — #54류 디버깅 사각지대).
    /// nonisolated static — UserDefaults/DebugLog 만 건드려 actor 격리가 필요 없다.
    private static func captureDecodeFailure(req: URLRequest, data: Data,
                                             response: URLResponse, error: Error) {
        let path = req.url?.lastPathComponent ?? "?"
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let failure = RankingDecodeFailure(
            path: path,
            status: status,
            errorDesc: error.localizedDescription,
            maskedJson: RankingResponseMask.maskedJSON(from: data),
            capturedAt: Date()
        )
        RankingDiagnosticStore.record(failure)
        DebugLog.log(" RankingAPI decode 실패 캡처: path=\(path) status=\(status) (\(data.count)B)")
    }

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso8601Basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
