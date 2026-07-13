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
        // initialCoins 폐기 — 신규 등록은 항상 서버 total_coins=0부터. 과거 누적값 한방 인정이
        // submit cap을 우회하는 farming 통로였음. 옵트인 이후 사용량만 submitDelta로 누적.
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
        /// 본인의 미수령 통합 보상(ops grant) — RP·코인 공용. currency로 원장 분기. 구버전 서버 nil.
        let pendingGrant: PendingGrant?
        /// 호출자의 현재 테넌트 slug — 배지 표시용. 익명/미등록·구버전 서버는 nil("public" 취급).
        let tenant: String?
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
        /// 월간 순위 RP 보상 (rp_rewards 원장 금액). RP 정산 전 period/구버전 서버는 nil.
        let rewardRp: Int?
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

    /// 통합 ops 보상 — 운영이 RP·코인을 임의 인원에게 지급하는 per-device 원장(reward_grants).
    /// podium/정산/메달과 무관 — 부작용 없이 currency로 원장만 골라 적립.
    struct PendingGrant: Decodable, Sendable {
        let currency: String                // "rp" | "coin"
        let amount: Int                     // 지급액
        let grantKey: String                // dedup 키 = claim 서명의 period 슬롯
        /// dedup key — grant_key 자체(캠페인/사유 슬러그, device당 UNIQUE). Settings.claimedGrants에 매칭.
        var dedupKey: String { grantKey }
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
        /// rp 원장 내 트랙 — "monthly" | "weekly" | "guild-monthly" (P2a). 같은 (period, rank)에
        /// 개인·길드 보상이 공존할 수 있어 서버가 정확한 row를 고르도록 전달. 서명 밖 평문.
        let periodType: String?
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

    /// 게시글 댓글 (flat, 대댓글 없음). 좋아요는 게시글과 동일 방식.
    struct BoardComment: Decodable, Identifiable, Sendable, Hashable {
        let id: Int
        let nickname: String
        let content: String
        let createdAt: Date
        let isMine: Bool
        let likeCount: Int
        let likedByMe: Bool
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
        /// 이 글의 댓글 (시간순). 구버전 서버는 미반환 → 디코딩 기본 빈 배열.
        let comments: [BoardComment]

        enum CodingKeys: String, CodingKey {
            case id, nickname, content, createdAt, isMine, likeCount, likedByMe, likers, comments
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(Int.self, forKey: .id)
            nickname = try c.decode(String.self, forKey: .nickname)
            content = try c.decode(String.self, forKey: .content)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            isMine = try c.decode(Bool.self, forKey: .isMine)
            likeCount = try c.decode(Int.self, forKey: .likeCount)
            likedByMe = try c.decode(Bool.self, forKey: .likedByMe)
            likers = try c.decodeIfPresent([BoardLiker].self, forKey: .likers) ?? []
            comments = try c.decodeIfPresent([BoardComment].self, forKey: .comments) ?? []
        }
        /// optimistic 업데이트용 수동 생성자.
        init(id: Int, nickname: String, content: String, createdAt: Date, isMine: Bool,
             likeCount: Int, likedByMe: Bool, likers: [BoardLiker], comments: [BoardComment]) {
            self.id = id; self.nickname = nickname; self.content = content
            self.createdAt = createdAt; self.isMine = isMine; self.likeCount = likeCount
            self.likedByMe = likedByMe; self.likers = likers; self.comments = comments
        }
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
        /// 댓글 최대 길이. nil이면 BoardView fallback(200).
        let commentMaxLen: Int?
        /// 본인 댓글 삭제 윈도우(초). nil이면 BoardView fallback(60s).
        let deleteCommentWindowSec: Int?
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

    // MARK: 댓글 payload/request/response
    struct CommentPayload: Encodable {
        let deviceId: String
        let postId: Int
        let content: String
        let ts: Int64
    }
    struct CommentRequest: Encodable {
        let payload: CommentPayload
        let signature: String
    }
    struct CommentResponse: Decodable {
        let accepted: Bool
        let commentId: Int?
        let createdAt: Date?
    }
    struct CommentLikePayload: Encodable {
        let deviceId: String
        let commentId: Int
        let ts: Int64
    }
    struct CommentLikeRequest: Encodable {
        let payload: CommentLikePayload
        let signature: String
    }
    struct DeleteCommentPayload: Encodable {
        let deviceId: String
        let commentId: Int
        let ts: Int64
    }
    struct DeleteCommentRequest: Encodable {
        let payload: DeleteCommentPayload
        let signature: String
    }
    struct DeleteCommentResponse: Decodable {
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
        /// 계정의 랭킹 점수 모드. true면 zeroBaseline 계정(서버 total_coins = baseline 이후 증가분)
        /// → 클라가 현재 VP를 새 baseline으로 잡아야 over-credit 안 남. 구버전 서버는 nil → 레거시
        /// 절대 모드로 처리(안전). 자세한 분기는 SettingsView recover 흐름 참조.
        let usesZeroBaseline: Bool?
    }

    // MARK: - Guild models

    /// guild-manage 액션. rawValue가 서버 payload의 `action` 필드 (snake_case).
    enum GuildManageAction: String {
        case kick
        case rotateCode = "rotate_code"
        case disband
        case setFurniture = "set_furniture"
        case invite
        case cancelInvite = "cancel_invite"
        case rename
    }

    struct GuildCreatePayload: Encodable {
        let deviceId: String
        let name: String
        let ts: Int64
    }
    struct GuildCreateRequest: Encodable {
        let payload: GuildCreatePayload
        let signature: String
    }
    struct GuildCreateResponse: Decodable, Sendable {
        let guildId: String
        let name: String
        let inviteCode: String
    }

    struct GuildJoinPayload: Encodable {
        let deviceId: String
        let inviteCode: String
        let ts: Int64
    }
    struct GuildJoinRequest: Encodable {
        let payload: GuildJoinPayload
        let signature: String
    }
    struct GuildJoinResponse: Decodable, Sendable {
        let guildId: String
        let name: String
        let memberCount: Int
    }

    struct GuildLeavePayload: Encodable {
        let deviceId: String
        let ts: Int64
    }
    struct GuildLeaveRequest: Encodable {
        let payload: GuildLeavePayload
        let signature: String
    }
    struct GuildLeaveResponse: Decodable, Sendable {
        let ok: Bool
        let cooldownUntil: Date?
    }

    /// targetDeviceId는 kick 외에는 "" — canonical 직렬화 형태를 액션과 무관하게 고정
    /// (서버 verify 객체와 정확히 일치해야 서명 통과). layout은 set_furniture에서만 존재
    /// ("setId:x:lane;…" 가구 좌표 직렬화) — nil이면 키 자체가 직렬화에서 빠지고, 서버도
    /// 같은 조건으로 canonical을 재현한다.
    struct GuildManagePayload: Encodable {
        let action: String
        let deviceId: String
        let targetDeviceId: String
        let layout: String?
        /// invite 전용 — 초대할 닉네임. nil이면 키 자체가 직렬화에서 빠진다(서버 present-only).
        let targetNickname: String?
        /// cancel_invite 전용 — 취소할 초대 id.
        let inviteId: String?
        /// rename 전용 — 새 길드명. nil이면 키 자체가 직렬화에서 빠진다(서버 present-only).
        let newName: String?
        let ts: Int64
    }
    struct GuildManageRequest: Encodable {
        let payload: GuildManagePayload
        let signature: String
    }
    struct GuildManageResponse: Decodable, Sendable {
        let ok: Bool
        /// rotate_code 응답에만 — 새 초대 코드.
        let inviteCode: String?
        /// set_furniture 응답에만 — 반영된 가구 배치 직렬화.
        let officeFurniture: String?
        /// rename 응답에만 — 반영된 새 길드명.
        let name: String?
    }

    /// 사무실 액션 payload — 액션 무관 고정 형태 {action, deviceId, item, slot, ts}.
    /// place_decor: slot 0..9, item=kind. remove_decor: slot 0..9, item "".
    /// set_theme: item "floor"|"wall", slot=테마 index.
    /// (set_spot은 자동 배치 전환으로 클라이언트에서 폐기 — 서버 액션은 하위 호환용으로 잔존.)
    struct GuildOfficePayload: Encodable {
        let action: String
        let deviceId: String
        let item: String
        let slot: Int
        let ts: Int64
    }
    struct GuildOfficeRequest: Encodable {
        let payload: GuildOfficePayload
        let signature: String
    }
    struct GuildOfficeResponse: Decodable, Sendable {
        let ok: Bool
        let slot: Int?
    }

    struct GuildInfoPayload: Encodable {
        let deviceId: String
        let ts: Int64
    }
    struct GuildInfoRequest: Encodable {
        let payload: GuildInfoPayload
        let signature: String
    }

    struct GuildMember: Decodable, Identifiable, Sendable {
        let nickname: String
        let monthlyVP: Int
        /// 이번 달 길드 점수(상위 5명 합산)에 반영 중인 멤버 — 리스트 ★ 표시.
        let isTopContributor: Bool
        let officeSlot: Int?
        let isLeader: Bool
        let isMe: Bool
        let joinedAt: Date
        let githubLogin: String?
        let profileJson: ProfileState?
        /// 길드장 요청 응답에만 포함 — kick 타겟팅용. 일반 멤버에게는 서버가 내려주지 않는다.
        let deviceId: String?
        var id: String { nickname }
    }
    struct GuildInfo: Decodable, Sendable {
        let id: String
        let name: String
        /// 멤버 전원 공개 (공유용). 재발급은 길드장만.
        let inviteCode: String
        let isLeader: Bool
        let floorTheme: Int
        let wallTheme: Int
        /// 가구 자유 배치 직렬화("setId:x:lane;…"). 빈 문자열/nil → 기본 배치.
        /// 렌더 전 `OfficeLayout.sanitizedPlacements`로 검증.
        let officeFurniture: String?
        let createdAt: Date
        let score: Int
        let rank: Int?
        let memberCount: Int
    }
    /// P2b 데코 — P1 서버는 항상 빈 배열이지만 응답 형태를 미리 고정.
    struct GuildFurnitureItem: Decodable, Sendable {
        let slotId: Int
        let itemKind: String
        /// 기부자 명판 — 탈퇴(FK SET NULL)·구버전 서버는 nil.
        let donorNickname: String?
    }
    /// 길드장이 보낸 대기중 초대 (guild-info sentInvites — 길드장에게만 채워짐).
    struct GuildSentInvite: Decodable, Sendable, Identifiable {
        let inviteId: String
        let nickname: String?
        let expiresAt: Date
        var id: String { inviteId }
    }
    /// 피초대자가 받은 초대 (guild-invite list).
    struct GuildReceivedInvite: Decodable, Sendable, Identifiable {
        let inviteId: String
        let guildId: String
        let guildName: String
        let inviterNickname: String?
        let memberCount: Int
        let expiresAt: Date
        var id: String { inviteId }
    }
    struct GuildInfoResponse: Decodable, Sendable {
        let guild: GuildInfo
        let members: [GuildMember]
        let furniture: [GuildFurnitureItem]
        /// 길드장이 보낸 대기중 초대. 구버전 서버는 키가 없어 nil → 빈 배열로 취급.
        let sentInvites: [GuildSentInvite]?
    }

    struct GuildLeaderboardEntry: Decodable, Identifiable, Sendable {
        let rank: Int
        let guildId: String
        let name: String
        let score: Int
        let memberCount: Int
        var id: String { guildId }
    }
    struct MyGuildSummary: Decodable, Sendable {
        let guildId: String
        let name: String
        let score: Int
        let memberCount: Int
        let rank: Int
    }
    /// 직전 달 길드 시상대 (P2a) — guild_monthly_winners 동결 스냅샷.
    struct GuildPreviousMonthEntry: Decodable, Identifiable, Sendable {
        let rank: Int
        let name: String
        let score: Int
        let memberCount: Int
        /// 정산 시점 길드장 — 시상대 아바타용 스냅샷.
        let leaderNickname: String?
        let leaderProfileJson: ProfileState?
        var id: Int { rank }
    }
    struct GuildPreviousMonth: Decodable, Sendable {
        let period: String                  // "YYYY-MM"
        /// 내 길드가 시상대에 있으면 그 rank — 하이라이트용.
        let myGuildRank: Int?
        let entries: [GuildPreviousMonthEntry]
    }

    struct GuildLeaderboardResponse: Decodable, Sendable {
        let entries: [GuildLeaderboardEntry]
        let myGuild: MyGuildSummary?
        let total: Int
        let periodResetAt: Date?
        /// 직전 달 길드 시상대 — P1 서버/정산 전 period는 nil.
        let previousMonth: GuildPreviousMonth?
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
        /// 길드 관련 서버 거부 — 서버 error 코드 그대로 (already_in_guild / name_taken /
        /// slot_taken / not_in_guild / invalid_code / not_leader / …). 호출 측이 코드로 분기.
        case guildConflict(String)
        /// 길드 재가입 쿨다운 (탈퇴/추방 후 7일). until은 서버가 body에 포함.
        case guildCooldown(until: Date?)
        /// 테넌트(skax 등) 편입 관련 서버 거부 — 서버 error 코드 그대로 (domain_not_allowed /
        /// already_gated / bad_code / code_expired / …). 호출 측이 코드로 분기.
        case tenantError(String)
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
            case .guildConflict(let code):
                switch code {
                case "already_in_guild":    return "이미 길드에 소속되어 있습니다."
                case "name_taken":          return "이미 사용 중인 길드 이름입니다."
                case "invalid_guild_name":  return "길드 이름 형식이 올바르지 않습니다 (2~24자)."
                case "slot_taken":          return "방금 다른 멤버가 그 자리에 앉았습니다."
                case "not_in_guild":        return "길드에 소속되어 있지 않습니다."
                case "invalid_code":        return "초대 코드가 올바르지 않습니다."
                case "not_leader":          return "길드장만 할 수 있는 작업입니다."
                case "target_not_in_guild": return "대상이 이미 길드에 없습니다."
                case "cannot_kick_self":    return "자기 자신은 추방할 수 없습니다."
                default:                    return "길드 요청이 거부되었습니다 (\(code))."
                }
            case .guildCooldown(let until):
                if let until {
                    let days = max(0, Int(ceil(until.timeIntervalSinceNow / 86_400)))
                    if days >= 1 { return "탈퇴/추방 후 재가입 쿨다운 중입니다 — 약 \(days)일 남음." }
                    let hours = max(1, Int(ceil(until.timeIntervalSinceNow / 3_600)))
                    return "탈퇴/추방 후 재가입 쿨다운 중입니다 — 약 \(hours)시간 남음."
                }
                return "탈퇴/추방 후 재가입 쿨다운 중입니다."
            case .tenantError(let code):
                switch code {
                case "domain_not_allowed":  return "허용된 도메인의 이메일만 인증할 수 있습니다."
                case "invalid_email":       return "이메일 형식이 올바르지 않습니다."
                case "already_gated":       return "이미 인증된 소속이라 다시 바꿀 수 없습니다."
                case "bad_code":            return "인증 코드가 올바르지 않습니다."
                case "code_expired":        return "인증 코드가 만료되었습니다. 다시 요청하세요."
                case "no_pending_code":     return "먼저 인증 코드를 요청하세요."
                case "too_many_attempts":   return "시도 횟수를 초과했습니다. 다시 요청하세요."
                case "mail_failed", "mail_not_configured":
                    return "인증 메일 발송에 실패했습니다. 잠시 후 다시 시도하세요."
                case "cross_tenant":        return "다른 소속의 콘텐츠에는 접근할 수 없습니다."
                default:                    return "인증 요청이 거부되었습니다 (\(code))."
                }
            case .http(let code, let msg):
                return "서버 오류 \(code)\(msg.map { ": \($0)" } ?? "")"
            case .decoding(let s):     return "응답 디코딩 오류(랭킹): \(s)"
            case .network(let s):      return "네트워크 오류: \(s)"
            }
        }
    }

    // MARK: - Public API

    /// 첫 옵트인 시 호출. 서버가 hmacKey + recoveryCode 발급. 성공 시 Keychain/Settings 갱신.
    /// 닉네임 중복 시 `.nicknameTaken` throw — 호출 측이 다른 닉네임으로 재시도.
    func register(deviceId: String, nickname: String,
                  githubLogin: String?, githubUserId: Int?,
                  profileJson: ProfileState?) async throws -> RegisterResponse {
        let req = RegisterRequest(deviceId: deviceId, nickname: nickname,
                                  githubLogin: githubLogin, githubUserId: githubUserId,
                                  profileJson: profileJson)
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
                     periodType: String? = nil,
                     hmacKeyBase64: String) async throws -> ClaimRewardResponse {
        // 서명 페이로드는 {deviceId, period, rank, ts}로 불변 — rewardType/periodType은 서명에
        // 넣지 않는다 (서버 verifyHmac과 일치 + 기존 coins claim 호환). request 레벨 라우팅 필드.
        let payload = ClaimRewardPayload(deviceId: deviceId, period: period, rank: rank,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signClaim(payload: payload, keyBase64: hmacKeyBase64)
        let req = ClaimRewardRequest(payload: payload, signature: sig,
                                     rewardType: rewardType, periodType: periodType)
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

    // MARK: - 테넌트 (완전 격리형 멀티테넌시) — docs/plans/tenant.md

    /// 인증 폼 도메인 드롭다운 소스. `[로컬파트] @ [도메인 ▼]` 채우기용. 인증 불필요(공개 목록).
    struct TenantDomain: Decodable, Sendable, Identifiable {
        let domain: String        // 예: "sk.com"
        let label: String         // 표시용(없으면 domain)
        let tenant: String        // 편입될 테넌트 slug (예: "skax")
        let tenantName: String    // 테넌트 표시명 (예: "SKAX")
        var id: String { domain }
    }
    struct TenantDomainsResponse: Decodable, Sendable { let domains: [TenantDomain] }

    struct TenantVerifyRequestResponse: Decodable, Sendable {
        let ok: Bool
        let tenant: String
        let expiresInSec: Int
    }
    struct TenantVerifyConfirmResponse: Decodable, Sendable {
        let ok: Bool
        let tenant: String
    }

    struct TenantAnnouncementRow: Decodable, Sendable, Identifiable {
        let id: Int
        let title: String
        let body: String
        let publishedAt: Date
    }
    struct TenantAnnouncementsResponse: Decodable, Sendable {
        let tenant: String
        let announcements: [TenantAnnouncementRow]
    }

    // HMAC 서명 페이로드 — 서버 verifyHmac 대상과 필드 일치(키는 encoder가 정렬).
    private struct TenantVerifyRequestPayload: Encodable {
        let deviceId: String
        let email: String
        let ts: Int64
    }
    private struct TenantVerifyRequestBody: Encodable {
        let payload: TenantVerifyRequestPayload
        let signature: String
    }
    private struct TenantVerifyConfirmPayload: Encodable {
        let code: String
        let deviceId: String
        let ts: Int64
    }
    private struct TenantVerifyConfirmBody: Encodable {
        let payload: TenantVerifyConfirmPayload
        let signature: String
    }

    /// 선택 가능한 이메일 도메인 목록 (드롭다운).
    func fetchTenantDomains() async throws -> TenantDomainsResponse {
        try await get(path: "tenant-domains")
    }

    /// 게이트 테넌트 편입용 이메일 OTP 발송. 성공 시 6자리 코드가 해당 이메일로 전송된다.
    /// 도메인 불일치/이미 편입/레이트리밋은 `.tenantError(code)`로 던진다.
    func requestTenantVerification(deviceId: String, email: String,
                                   hmacKeyBase64: String) async throws -> TenantVerifyRequestResponse {
        let payload = TenantVerifyRequestPayload(deviceId: deviceId, email: email,
                                                 ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let body = TenantVerifyRequestBody(payload: payload, signature: sig)
        return try await post(path: "tenant-verify-request", body: body)
    }

    /// OTP 코드 확인 → 게이트 테넌트로 편입(one-way). 성공 시 서버가 tenant_id 갱신 + 타 테넌트 길드 자동탈퇴.
    /// 코드 불일치/만료는 `.tenantError(code)`.
    func confirmTenantVerification(deviceId: String, code: String,
                                   hmacKeyBase64: String) async throws -> TenantVerifyConfirmResponse {
        let payload = TenantVerifyConfirmPayload(code: code, deviceId: deviceId,
                                                 ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let body = TenantVerifyConfirmBody(payload: payload, signature: sig)
        return try await post(path: "tenant-verify-confirm", body: body)
    }

    /// 호출자 테넌트의 전용 공지(전역 패치공지와 별개). 읽기 전용 — HMAC 불필요.
    func fetchTenantAnnouncements(deviceId: String?) async throws -> TenantAnnouncementsResponse {
        let q = deviceId.map { [URLQueryItem(name: "deviceId", value: $0)] }
        return try await get(path: "tenant-announcements", queryItems: q)
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

    /// 댓글 작성. content는 trim 전 그대로 전송 — 서버가 trim + 검증. rate limit 위반 시 429.
    func submitComment(deviceId: String, postId: Int, content: String,
                       hmacKeyBase64: String) async throws -> CommentResponse {
        let payload = CommentPayload(deviceId: deviceId, postId: postId, content: content,
                                     ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = CommentRequest(payload: payload, signature: sig)
        return try await post(path: "comment", body: req)
    }

    /// 댓글 좋아요 toggle. 응답의 (liked, count)로 UI 동기화.
    func likeComment(deviceId: String, commentId: Int,
                     hmacKeyBase64: String) async throws -> LikeResponse {
        let payload = CommentLikePayload(deviceId: deviceId, commentId: commentId,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = CommentLikeRequest(payload: payload, signature: sig)
        return try await post(path: "comment-like", body: req)
    }

    /// 본인 댓글 60초 이내 삭제. 윈도우 만료/타인 댓글이면 서버 403.
    func deleteComment(deviceId: String, commentId: Int,
                       hmacKeyBase64: String) async throws -> DeleteCommentResponse {
        let payload = DeleteCommentPayload(deviceId: deviceId, commentId: commentId,
                                           ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let req = DeleteCommentRequest(payload: payload, signature: sig)
        return try await post(path: "delete-comment", body: req)
    }

    // MARK: - Guild

    /// 길드 창설. 생성권 차감은 호출 측(GuildView)이 성공 응답 후 수행.
    /// 이름 충돌 `.guildConflict("name_taken")`, 쿨다운 `.guildCooldown` throw.
    func createGuild(deviceId: String, name: String,
                     hmacKeyBase64: String) async throws -> GuildCreateResponse {
        let payload = GuildCreatePayload(deviceId: deviceId, name: name,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-create",
                              body: GuildCreateRequest(payload: payload, signature: sig))
    }

    /// 초대 코드로 가입. 잘못된 코드 `.guildConflict("invalid_code")`, 쿨다운 `.guildCooldown`.
    func joinGuild(deviceId: String, inviteCode: String,
                   hmacKeyBase64: String) async throws -> GuildJoinResponse {
        let payload = GuildJoinPayload(deviceId: deviceId, inviteCode: inviteCode,
                                       ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-join",
                              body: GuildJoinRequest(payload: payload, signature: sig))
    }

    /// 탈퇴. 길드장이면 서버 트리거가 최고참 승계, 마지막 멤버면 길드 자동 해체.
    func leaveGuild(deviceId: String, hmacKeyBase64: String) async throws -> GuildLeaveResponse {
        let payload = GuildLeavePayload(deviceId: deviceId,
                                        ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-leave",
                              body: GuildLeaveRequest(payload: payload, signature: sig))
    }

    /// 길드장 액션 (kick / 코드 재발급 / 해체 / 가구 재배치 / 초대 발송·취소 / 길드명 변경).
    /// kick 외에는 targetDeviceId 생략, furniture는 setFurniture에서만, targetNickname은 invite에서만,
    /// inviteId는 cancelInvite에서만, newName은 rename에서만
    /// (나머지는 nil → canonical에서 키 제외, 서버 present-only와 일치).
    func manageGuild(deviceId: String, action: GuildManageAction, targetDeviceId: String? = nil,
                     furniture: String? = nil, targetNickname: String? = nil, inviteId: String? = nil,
                     newName: String? = nil,
                     hmacKeyBase64: String) async throws -> GuildManageResponse {
        let payload = GuildManagePayload(action: action.rawValue, deviceId: deviceId,
                                         targetDeviceId: targetDeviceId ?? "",
                                         layout: furniture,
                                         targetNickname: targetNickname,
                                         inviteId: inviteId,
                                         newName: newName,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-manage",
                              body: GuildManageRequest(payload: payload, signature: sig))
    }

    // MARK: - 길드 초대 (피초대자 액션 — guild-invite)

    struct GuildInvitePayload: Encodable {
        let action: String
        let deviceId: String
        /// accept/decline 전용 — nil이면 키 제외 (list). 서버 present-only와 일치.
        let inviteId: String?
        let ts: Int64
    }
    struct GuildInviteRequest: Encodable {
        let payload: GuildInvitePayload
        let signature: String
    }
    struct GuildInviteListResponse: Decodable, Sendable {
        let invites: [GuildReceivedInvite]
    }

    private func inviteAction<R: Decodable>(action: String, inviteId: String?,
                                            deviceId: String, hmacKeyBase64: String) async throws -> R {
        let payload = GuildInvitePayload(action: action, deviceId: deviceId, inviteId: inviteId,
                                         ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-invite",
                              body: GuildInviteRequest(payload: payload, signature: sig))
    }

    /// 내가 받은 대기중 초대 목록. 무소속이든 소속이든 조회 가능(빈 배열 폴백).
    func listGuildInvites(deviceId: String,
                          hmacKeyBase64: String) async throws -> [GuildReceivedInvite] {
        let resp: GuildInviteListResponse = try await inviteAction(
            action: "list", inviteId: nil, deviceId: deviceId, hmacKeyBase64: hmacKeyBase64)
        return resp.invites
    }

    /// 초대 수락 → 해당 길드 가입. 자격 재검사 실패 시 guildConflict/guildCooldown.
    func acceptGuildInvite(deviceId: String, inviteId: String,
                           hmacKeyBase64: String) async throws -> GuildJoinResponse {
        try await inviteAction(action: "accept", inviteId: inviteId,
                               deviceId: deviceId, hmacKeyBase64: hmacKeyBase64)
    }

    /// 초대 거절 (거절 후 그 길드는 24h 재초대 쿨다운).
    @discardableResult
    func declineGuildInvite(deviceId: String, inviteId: String,
                            hmacKeyBase64: String) async throws -> GuildManageResponse {
        try await inviteAction(action: "decline", inviteId: inviteId,
                               deviceId: deviceId, hmacKeyBase64: hmacKeyBase64)
    }

    /// guild-office 공통 호출 — 액션별 래퍼가 아래에.
    private func officeAction(deviceId: String, action: String, item: String, slot: Int,
                              hmacKeyBase64: String) async throws -> GuildOfficeResponse {
        let payload = GuildOfficePayload(action: action, deviceId: deviceId, item: item,
                                         slot: slot, ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-office",
                              body: GuildOfficeRequest(payload: payload, signature: sig))
    }

    /// 데코 배치/교체 구매 (P2b, 멤버 누구나 — 기부 모델). 코인 차감은 호출 측이 성공 후 수행.
    func placeDecor(deviceId: String, slot: Int, itemKind: String,
                    hmacKeyBase64: String) async throws -> GuildOfficeResponse {
        try await officeAction(deviceId: deviceId, action: "place_decor", item: itemKind,
                               slot: slot, hmacKeyBase64: hmacKeyBase64)
    }

    /// 데코 제거 (기부자 본인 또는 길드장 — 아니면 `.guildConflict("not_leader")`).
    func removeDecor(deviceId: String, slot: Int,
                     hmacKeyBase64: String) async throws -> GuildOfficeResponse {
        try await officeAction(deviceId: deviceId, action: "remove_decor", item: "", slot: slot,
                               hmacKeyBase64: hmacKeyBase64)
    }

    /// 인테리어 테마 변경 (길드장 전용). kind = "floor"(0..8) | "wall"(0..3).
    func setOfficeTheme(deviceId: String, kind: String, themeIndex: Int,
                        hmacKeyBase64: String) async throws -> GuildOfficeResponse {
        try await officeAction(deviceId: deviceId, action: "set_theme", item: kind,
                               slot: themeIndex, hmacKeyBase64: hmacKeyBase64)
    }

    /// 내 길드 상세. 무길드면 `.guildConflict("not_in_guild")` throw — 호출 측이 온보딩 분기.
    func fetchGuildInfo(deviceId: String, hmacKeyBase64: String) async throws -> GuildInfoResponse {
        let payload = GuildInfoPayload(deviceId: deviceId,
                                       ts: Int64(Date().timeIntervalSince1970))
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "guild-info",
                              body: GuildInfoRequest(payload: payload, signature: sig))
    }

    /// 길드 월간 랭킹 — 미등록/미가입도 조회 가능 (온보딩 "구경" 리스트).
    func fetchGuildLeaderboard(deviceId: String?) async throws -> GuildLeaderboardResponse {
        var items: [URLQueryItem] = []
        if let deviceId, !deviceId.isEmpty {
            items.append(URLQueryItem(name: "deviceId", value: deviceId))
        }
        return try await get(path: "guild-leaderboard", queryItems: items.isEmpty ? nil : items)
    }

    // MARK: - DM (쪽지, E2EE)

    /// 스레드 요약 (dm-inbox). 본문은 ciphertext — 클라가 복호(수신분)/로컬 echo(발신분)로 미리보기.
    struct DMThread: Decodable, Sendable, Identifiable {
        let peerDevice: String
        let peerNickname: String?
        let peerIdPub: String?
        let lastId: String
        let lastCiphertext: String
        let lastSenderIdPub: String
        let lastFromMe: Bool
        let lastAt: Date
        let unreadCount: Int
        var id: String { peerDevice }
    }
    struct DMInboxResponse: Decodable, Sendable { let threads: [DMThread] }

    /// 스레드 한 메시지 (dm-thread). fromMe면 로컬 echo, 아니면 HPKE 복호.
    struct DMMessage: Decodable, Sendable, Identifiable {
        let id: String
        let fromMe: Bool
        let ciphertext: String
        let senderIdPub: String
        let createdAt: Date
        let readAt: Date?
    }
    struct DMThreadResponse: Decodable, Sendable {
        let peerNickname: String?
        let messages: [DMMessage]
    }
    struct DMKeyResponse: Decodable, Sendable { let deviceId: String; let x25519Pub: String }
    struct DMSendResponse: Decodable, Sendable { let id: String; let createdAt: Date }

    struct DMKeysPayload: Encodable {
        let action: String
        let deviceId: String
        let x25519Pub: String?
        let targetNickname: String?
        let ts: Int64
    }
    struct DMKeysRequest: Encodable { let payload: DMKeysPayload; let signature: String }
    struct DMSendPayload: Encodable {
        let deviceId: String
        let targetNickname: String
        let ciphertext: String
        let senderIdPub: String
        let ts: Int64
    }
    struct DMSendRequest: Encodable { let payload: DMSendPayload; let signature: String }
    struct DMInboxPayload: Encodable { let deviceId: String; let ts: Int64 }
    struct DMInboxRequest: Encodable { let payload: DMInboxPayload; let signature: String }
    struct DMThreadPayload: Encodable { let deviceId: String; let peerDevice: String; let ts: Int64 }
    struct DMThreadRequest: Encodable { let payload: DMThreadPayload; let signature: String }
    struct DMReadPayload: Encodable {
        let deviceId: String; let peerDevice: String; let upToTs: Int64; let ts: Int64
    }
    struct DMReadRequest: Encodable { let payload: DMReadPayload; let signature: String }
    struct DMDeletePayload: Encodable { let deviceId: String; let peerDevice: String; let ts: Int64 }
    struct DMDeleteRequest: Encodable { let payload: DMDeletePayload; let signature: String }
    struct DMOkResponse: Decodable, Sendable { let ok: Bool }

    /// 수신 정책 + 차단 (dm-settings). 모든 액션이 갱신 후 현재 상태를 돌려준다.
    struct DMBlockedPeer: Decodable, Sendable, Identifiable {
        let device: String
        let nickname: String?
        var id: String { device }
    }
    struct DMSettingsResponse: Decodable, Sendable {
        let allowFrom: String            // anyone | guild | none
        let blocked: [DMBlockedPeer]
    }
    struct DMSettingsPayload: Encodable {
        let action: String
        let deviceId: String
        let allowFrom: String?
        let targetNickname: String?
        let targetDevice: String?
        let ts: Int64
    }
    struct DMSettingsRequest: Encodable { let payload: DMSettingsPayload; let signature: String }

    private func nowTs() -> Int64 { Int64(Date().timeIntervalSince1970) }

    /// 내 신원 공개키 게시(신규/rotate).
    func dmPublishKey(deviceId: String, x25519Pub: String, hmacKeyBase64: String) async throws {
        let payload = DMKeysPayload(action: "publish", deviceId: deviceId, x25519Pub: x25519Pub,
                                    targetNickname: nil, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let _: DMOkResponse = try await post(path: "dm-keys",
                                             body: DMKeysRequest(payload: payload, signature: sig))
    }

    /// 상대 공개키 조회 (닉네임). 미게시면 `.guildConflict("no_key")` throw.
    func dmFetchKey(deviceId: String, targetNickname: String,
                    hmacKeyBase64: String) async throws -> DMKeyResponse {
        let payload = DMKeysPayload(action: "fetch", deviceId: deviceId, x25519Pub: nil,
                                    targetNickname: targetNickname, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "dm-keys", body: DMKeysRequest(payload: payload, signature: sig))
    }

    /// 암호문 발신. 반려는 `.guildConflict("cannot_send")` 등.
    @discardableResult
    func dmSend(deviceId: String, targetNickname: String, ciphertext: String, senderIdPub: String,
                hmacKeyBase64: String) async throws -> DMSendResponse {
        let payload = DMSendPayload(deviceId: deviceId, targetNickname: targetNickname,
                                    ciphertext: ciphertext, senderIdPub: senderIdPub, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "dm-send", body: DMSendRequest(payload: payload, signature: sig))
    }

    func dmInbox(deviceId: String, hmacKeyBase64: String) async throws -> [DMThread] {
        let payload = DMInboxPayload(deviceId: deviceId, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let resp: DMInboxResponse = try await post(path: "dm-inbox",
                                                   body: DMInboxRequest(payload: payload, signature: sig))
        return resp.threads
    }

    func dmThread(deviceId: String, peerDevice: String,
                  hmacKeyBase64: String) async throws -> DMThreadResponse {
        let payload = DMThreadPayload(deviceId: deviceId, peerDevice: peerDevice, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "dm-thread", body: DMThreadRequest(payload: payload, signature: sig))
    }

    func dmRead(deviceId: String, peerDevice: String, upToTs: Int64,
                hmacKeyBase64: String) async throws {
        let payload = DMReadPayload(deviceId: deviceId, peerDevice: peerDevice, upToTs: upToTs, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let _: DMOkResponse = try await post(path: "dm-read",
                                             body: DMReadRequest(payload: payload, signature: sig))
    }

    /// 특정 상대와의 대화를 내 쪽에서 삭제(tombstone). 상대 사본은 유지("나만 삭제").
    func dmDeleteThread(deviceId: String, peerDevice: String, hmacKeyBase64: String) async throws {
        let payload = DMDeletePayload(deviceId: deviceId, peerDevice: peerDevice, ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        let _: DMOkResponse = try await post(path: "dm-delete",
                                             body: DMDeleteRequest(payload: payload, signature: sig))
    }

    // MARK: - 수신 정책 · 차단 (dm-settings)

    private func dmSettingsAction(action: String, deviceId: String, hmacKeyBase64: String,
                                  allowFrom: String? = nil, targetNickname: String? = nil,
                                  targetDevice: String? = nil) async throws -> DMSettingsResponse {
        let payload = DMSettingsPayload(action: action, deviceId: deviceId, allowFrom: allowFrom,
                                        targetNickname: targetNickname, targetDevice: targetDevice,
                                        ts: nowTs())
        let sig = try Self.signEncodable(payload, keyBase64: hmacKeyBase64)
        return try await post(path: "dm-settings",
                              body: DMSettingsRequest(payload: payload, signature: sig))
    }

    func dmGetSettings(deviceId: String, hmacKeyBase64: String) async throws -> DMSettingsResponse {
        try await dmSettingsAction(action: "get", deviceId: deviceId, hmacKeyBase64: hmacKeyBase64)
    }
    @discardableResult
    func dmSetAllowFrom(deviceId: String, allowFrom: String,
                        hmacKeyBase64: String) async throws -> DMSettingsResponse {
        try await dmSettingsAction(action: "set", deviceId: deviceId,
                                   hmacKeyBase64: hmacKeyBase64, allowFrom: allowFrom)
    }
    @discardableResult
    func dmBlock(deviceId: String, targetNickname: String,
                 hmacKeyBase64: String) async throws -> DMSettingsResponse {
        try await dmSettingsAction(action: "block", deviceId: deviceId,
                                   hmacKeyBase64: hmacKeyBase64, targetNickname: targetNickname)
    }
    @discardableResult
    func dmUnblock(deviceId: String, targetDevice: String,
                   hmacKeyBase64: String) async throws -> DMSettingsResponse {
        try await dmSettingsAction(action: "unblock", deviceId: deviceId,
                                   hmacKeyBase64: hmacKeyBase64, targetDevice: targetDevice)
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
    /// 길드 endpoint의 에러 body — `{ "error": "...", "until": "ISO" }`. 전역 상태코드 매핑
    /// (409→nicknameTaken, 403→banned)이 길드 의미와 충돌해서 body 코드로 먼저 분기한다.
    private struct ServerErrorBody: Decodable {
        let error: String?
        let until: String?
    }

    /// body의 error 코드가 길드/초대/쪽지 도메인이면 전역 상태코드 매핑(409→닉네임중복 등)보다
    /// 우선해 `guildConflict(code)`로 던진다. 호출 측이 코드로 친절한 메시지 분기.
    /// ⚠️ `rate_limited`(429)는 게시판(post/comment)과 공유되므로 넣지 않는다 — 429 경로가
    ///    `rateLimited(retryAfterSec)`로 처리(게시판 카운트다운 유지). DM은 mapError가 별도 처리.
    private static let domainErrorCodes: Set<String> = [
        // 길드
        "already_in_guild", "name_taken", "invalid_guild_name", "slot_taken",
        "not_in_guild", "invalid_code", "not_leader", "target_not_in_guild",
        "cannot_kick_self", "guild_not_found",
        // 초대
        "cannot_invite", "cannot_invite_self", "already_invited",
        "invite_not_found", "invite_expired", "redecline_cooldown", "too_many_pending",
        // 쪽지
        "no_key", "cannot_send", "cannot_send_self", "cannot_block",
    ]

    /// 테넌트 편입 전용 error 코드 — tenant 엔드포인트에서만 반환되므로 전역 매핑(409→닉네임중복)보다
    /// 우선해도 다른 endpoint와 충돌 없음. `rate_limited`는 제외(429 경로 공유).
    private static let tenantErrorCodes: Set<String> = [
        "domain_not_allowed", "invalid_email", "already_gated",
        "bad_code", "code_expired", "no_pending_code", "too_many_attempts",
        "mail_failed", "mail_not_configured",
        // 교차 테넌트 상호작용 거부(403) — body 코드 우선 처리해 전역 403→banned 오매핑 방지.
        "cross_tenant",
    ]

    private func validateHTTPStatus(data: Data, response: URLResponse) throws {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard !(200..<300).contains(code) else { return }

        // 길드 도메인 에러 — 전역 상태코드 매핑보다 먼저 (409/403의 의미가 endpoint마다 다름).
        if let body = try? JSONDecoder().decode(ServerErrorBody.self, from: data),
           let errCode = body.error {
            if errCode == "join_cooldown" {
                let until = body.until.flatMap {
                    Self.iso8601WithFractional.date(from: $0) ?? Self.iso8601Basic.date(from: $0)
                }
                throw RankingError.guildCooldown(until: until)
            }
            if Self.domainErrorCodes.contains(errCode) {
                throw RankingError.guildConflict(errCode)
            }
            if Self.tenantErrorCodes.contains(errCode) {
                throw RankingError.tenantError(errCode)
            }
        }

        if code == 409 { throw RankingError.nicknameTaken }
        if code == 403 { throw RankingError.banned }
        if code == 412 { throw RankingError.privacyNotAccepted }
        if code == 429 {
            let s = (try? JSONDecoder().decode(RateLimitedBody.self, from: data))?.retryAfterSec ?? 60
            throw RankingError.rateLimited(retryAfterSec: s)
        }
        let body = String(data: data, encoding: .utf8)
        throw RankingError.http(code, body)
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
