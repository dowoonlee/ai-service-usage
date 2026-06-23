import Foundation

/// 랭킹 보드용 직렬화 가능한 트레이너 프로필 상태. 보드 행 + 호버 popover 렌더에 필요한
/// 모든 입력을 한 묶음으로 캡슐화. 서버는 opaque JSONB로 저장만, 해석은 수신측 클라이언트.
///
/// 변조 위험: 누군가가 자기가 클리어 안 한 뱃지를 `clearedBadges`에 끼워 보낼 수 있음.
/// 50명 + 수동 큐레이션이라 수용 가능한 트레이드오프 — 보드 표시 fake는 가능하지만 코인은
/// 서버 측 HMAC 서명된 submit으로만 늘어남.
struct ProfileState: Codable, Sendable {
    let card: TrainerCard
    let trainerID: String
    let stats: TrainerStats
    /// 클리어한 도장 뱃지 키 — "category.tier" 형식.
    let clearedBadges: [String]
    /// 컴플리트한 컬렉션 — `PetCollection.rawValue`.
    let completedCollections: [String]
    /// 로컬 상태 백업 — recover 시 새 디바이스에서 펫 인벤토리·코인 잔액·설정을 복원하는 페이로드.
    /// 본인만 받아야 하는 데이터 — `leaderboard` edge function이 응답 빌드 시 이 키를 strip하고,
    /// `recover-by-code`/`recover-by-github` 응답에만 포함된다. 옛 클라이언트와의 호환성을 위해
    /// 옵셔널 — 미지원 클라이언트는 nil로 디코딩.
    let backup: BackupPayload?
    /// `card.avatar.kind`에 장착된 RP 코스메틱 이펙트 (`EffectKind.rawValue`). 시상대/보드 펫 렌더용.
    /// 옛 클라이언트 호환 옵셔널 — 미지원 클라는 nil로 디코딩(이펙트 미표시).
    let equippedEffects: [String]?

    @MainActor
    static func current(from settings: Settings) -> ProfileState {
        ProfileState(
            card: settings.trainerCard,
            trainerID: settings.trainerID,
            stats: TrainerStats.compute(from: settings),
            clearedBadges: Array(settings.clearedBadges),
            completedCollections: Array(settings.completedCollections),
            backup: BackupPayload.current(from: settings),
            equippedEffects: (settings.equippedEffects[settings.trainerCard.avatar.kind] ?? []).map(\.rawValue)
        )
    }

    /// `ProfileState`로부터 TrainerCardView의 badges 입력 재구성. 받은 측은 원 사용자의
    /// Settings에 접근 못 하므로 cleared/available을 clearedBadges 존재 여부로 추론.
    @MainActor
    func badgeRowsForRender() -> [TrainerCardView.BadgeRow] {
        let clearedSet = Set(clearedBadges)
        return BadgeCategory.allCases.map { cat in
            let cleared = BadgeTier.allCases.contains { tier in
                clearedSet.contains(BadgeID(category: cat, tier: tier).key)
            }
            // 원격 사용자의 isAvailable(s)는 모름 — cleared면 available로 간주, 아니면 미활성.
            return TrainerCardView.BadgeRow(
                category: cat,
                cleared: cleared,
                available: cleared
            )
        }
    }

    @MainActor
    func collectionRowsForRender() -> [(collection: PetCollection, complete: Bool)] {
        let completeSet = Set(completedCollections)
        return PetCollection.allCases.map { c in
            (c, completeSet.contains(c.rawValue))
        }
    }

    /// 새 디바이스 복구용 백업 페이로드. 펫 인벤토리·코인 잔액·사용자 설정 등 "잃으면 아쉬운"
    /// 로컬 상태를 캡슐화. 누적/dedup용 카운터(예: claimedPodiumPeriods, creditedPRNumbers)는
    /// 재지급 방지에 필수라 함께 포함. 디바이스 종속 값(예: rankingDeviceID, lastWellnessShownAt)은
    /// 의도적으로 제외 — 서버가 복구 시 새로 발급/리셋.
    ///
    /// PetKind dictionary key는 String raw로 변환 — JSONEncoder는 enum-keyed dict를
    /// `[key, value, key, value, ...]` 배열로 인코딩해서 jsonb object로 안 들어감.
    ///
    /// `v`는 스키마 버전. 미래에 필드를 추가/제거하면 증가시킨다 — 복구 측이 unknown 버전이면
    /// 호환되는 필드만 머지하고 로그를 남기는 방어 로직을 둘 수 있게.
    struct BackupPayload: Codable, Sendable {
        let v: Int

        // 펫 인벤토리
        let ownedPets: [String: PetOwnership]?
        let petUsageSeconds: [String: TimeInterval]?
        let pendingHighlights: [String]?
        let petClaudeKind: String?
        let petCursorKind: String?
        let petClaudeVariant: Int?
        let petCursorVariant: Int?

        // 경제 상태 (가챠 코인 ledger — rankingScoreEarnedVP와 별개)
        let coins: Int?
        let gachaTickets: Int?
        let coinsTotalEarned: Int?
        let firstCreditedAt: Date?

        // 보상 dedup (재지급 방지 필수)
        let claimedPodiumPeriods: [String]?
        let creditedPRNumbers: [Int]?
        let completedCollections: [String]?
        let clearedBadges: [String]?

        // 칭호 인벤토리
        let ownedTitles: [String]?

        // 사용자 설정
        let notifyEnabled: Bool?
        let notifyThresholds: [Int]?
        let showMenuBar: Bool?
        let showGitHubLoginInCard: Bool?

        // 운세 dedup
        let dailyFortuneLastShownDate: Date?

        @MainActor
        static func current(from s: Settings) -> BackupPayload {
            // PetKind → String 변환. enum dict를 jsonb object로 보내려는 의도적 매핑.
            let owned = Dictionary(uniqueKeysWithValues: s.ownedPets.map { ($0.key.rawValue, $0.value) })
            let usage = Dictionary(uniqueKeysWithValues: s.petUsageSeconds.map { ($0.key.rawValue, $0.value) })
            let highlights = s.pendingHighlights.map { $0.rawValue }

            return BackupPayload(
                v: 1,
                ownedPets: owned,
                petUsageSeconds: usage,
                pendingHighlights: highlights,
                petClaudeKind: s.petClaudeKind.rawValue,
                petCursorKind: s.petCursorKind.rawValue,
                petClaudeVariant: s.petClaudeVariant,
                petCursorVariant: s.petCursorVariant,
                coins: s.coins,
                gachaTickets: s.gachaTickets,
                coinsTotalEarned: s.coinsTotalEarned,
                firstCreditedAt: s.firstCreditedAt,
                claimedPodiumPeriods: Array(s.claimedPodiumPeriods),
                creditedPRNumbers: Array(s.creditedPRNumbers),
                completedCollections: Array(s.completedCollections),
                clearedBadges: Array(s.clearedBadges),
                ownedTitles: Array(s.ownedTitles),
                notifyEnabled: s.notifyEnabled,
                notifyThresholds: s.notifyThresholds,
                showMenuBar: s.showMenuBar,
                showGitHubLoginInCard: s.showGitHubLoginInCard,
                dailyFortuneLastShownDate: s.dailyFortuneLastShownDate
            )
        }
    }
}
