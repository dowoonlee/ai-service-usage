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

    @MainActor
    static func current(from settings: Settings) -> ProfileState {
        ProfileState(
            card: settings.trainerCard,
            trainerID: settings.trainerID,
            stats: TrainerStats.compute(from: settings),
            clearedBadges: Array(settings.clearedBadges),
            completedCollections: Array(settings.completedCollections)
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
}
