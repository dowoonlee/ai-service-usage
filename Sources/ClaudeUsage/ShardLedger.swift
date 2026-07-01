import Foundation

/// 이로치 조각(shiny shard) 원장. 만렙(variant 3) 펫의 오버플로우로만 적립되고, Prestige(홀로 이로치)
/// 해금에만 소비된다. CoinLedger / RankPointLedger와 동일하게 잔액 변경의 단일 진입점.
@MainActor
final class ShardLedger {
    static let shared = ShardLedger()
    private init() {}

    /// 오버플로우 적립. 잔액만 증가 (적립 판정·중복방지는 `PetOwnership.claimOverflowShards`가 담당).
    func credit(_ amount: Int) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.shinyShards += amount
        DebugLog.log("ShardLedger: 이로치 조각 +\(amount) (total=\(s.shinyShards))")
    }

    /// 해당 펫에 Prestige(홀로 이로치, variant 4) 해금 가능한지 — 만렙(variant 3) + 미보유.
    func canPurchasePrestige(_ kind: PetKind) -> Bool {
        guard let o = Settings.shared.ownedPets[kind] else { return false }
        return o.unlockedVariants.contains(3)
            && !o.unlockedVariants.contains(PetOwnership.prestigeVariant)
    }

    /// Prestige 해금 — 가격만큼 조각 차감 + variant 4 unlock. 조건 미충족/잔액 부족이면 false.
    @discardableResult
    func purchasePrestige(_ kind: PetKind) -> Bool {
        let s = Settings.shared
        guard canPurchasePrestige(kind), var o = s.ownedPets[kind] else { return false }
        let cost = PetOwnership.prestigeCost
        guard s.shinyShards >= cost else { return false }
        s.shinyShards -= cost
        o.unlockedVariants.insert(PetOwnership.prestigeVariant)
        s.ownedPets[kind] = o
        DebugLog.log("ShardLedger: Prestige 해금 [\(kind.rawValue)] -\(cost) 조각 (total=\(s.shinyShards))")
        return true
    }
}
