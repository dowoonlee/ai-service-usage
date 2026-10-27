import Foundation

/// 연말 리캡용 게임 이벤트 1건.
///
/// 보유 상태(`ownedPets` 등)는 누적 결과만 남아서 "언제 무엇을 얻었나"를 되짚을 수 없다.
/// 리캡에서 시간 축이 필요한 사실만 여기에 append-only로 쌓는다.
///
/// 펫·등급은 enum이 아니라 rawValue 문자열로 둔다 — 나중에 `PetKind` 케이스가 바뀌어도
/// 지난 줄이 디코딩 실패로 통째로 사라지지 않게.
struct RecapEvent: Codable, Hashable {
    enum Kind: String, Codable {
        case gachaPull      // pet, rarity, isNew, variant(이번에 해금된 이로치)
        case prestige       // pet, result("success" | "failure")
        case gymBadge       // detail = BadgeID.key
        case arenaRanked    // result("me" | "opp" | 그 외), value = 레이팅 변화
    }

    var at: Date
    var kind: Kind
    var pet: String? = nil
    var rarity: String? = nil
    var isNew: Bool? = nil
    var variant: Int? = nil
    var result: String? = nil
    var detail: String? = nil
    var value: Int? = nil
}

enum RecapLog {
    static let store = JSONLStore<RecapEvent>(
        filename: "recap-events.jsonl",
        label: "ClaudeUsage.RecapEvents",
        directory: AppEnv.dataDirectory
    )

    static func record(_ event: RecapEvent) {
        store.append(event)
    }

    /// 1년치 전부. 뽑기가 하루 수십 번이어도 연 2만 줄 안쪽이라 상한은 넉넉히 둔다.
    static func loadAll() -> [RecapEvent] {
        store.loadRecent(limit: 100_000)
    }
}
