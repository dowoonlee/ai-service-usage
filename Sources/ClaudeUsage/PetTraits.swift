import Foundation

/// 펫 종별 metadata — 렌더링과 무관한 게임 로직용 속성.
///
/// `PetDefinition`(prefix/cellSize/suffixes/theme/facing)은 *렌더링용*이므로 거기에 게임
/// 속성을 섞으면 매번 시그니처가 늘어나고 75 case의 라인을 통째로 다시 손대야 한다.
/// 여기 extension은 trait당 한 매핑 함수만 추가하면 되도록 분리 — 미래에 element/archetype
/// 같은 속성을 추가할 때 기존 라인은 건드리지 않는다.
extension PetKind {
    /// 어느 컬렉션(셋 보너스 단위)에 속하는지. 1:1 매핑 — 모든 종이 정확히 하나에 속한다.
    /// 진실 소스는 `PetCollection.members`(도감/그리드 순서까지 정의)이고, 여기서는 그 역인덱스를
    /// 캐시해 O(1) 조회. 새 펫의 컬렉션 소속은 `members`에만 추가하면 양방향이 일관 유지된다.
    var collection: PetCollection { Self.collectionByKind[self] ?? .mainframe }

    nonisolated static let collectionByKind: [PetKind: PetCollection] = {
        var map: [PetKind: PetCollection] = [:]
        for c in PetCollection.allCases {
            for k in c.members { map[k] = c }
        }
        return map
    }()

    /// `Gacha.pool` 역인덱스 캐시(`[PetKind: Rarity]`). pool이 nonisolated static let이라
    /// 한 번만 빌드해 두고 O(1) 조회. `PetCollection.bonusCoins`·인벤토리 렌더에서 자주 호출돼
    /// 매 호출 선형 탐색(O(79))을 피한다.
    nonisolated static let rarityIndex: [PetKind: Rarity] = {
        var index: [PetKind: Rarity] = [:]
        for (rarity, kinds) in Gacha.pool {
            for kind in kinds { index[kind] = rarity }
        }
        return index
    }()

    /// pool에 없는 kind(이론상 없음)는 nil 반환 — 호출 측에서 Common 가치로 fallback.
    static func rarityFor(_ kind: PetKind) -> Rarity? {
        rarityIndex[kind]
    }
}
