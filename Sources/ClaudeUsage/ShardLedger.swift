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

    /// Prestige 해금 시도 결과.
    enum PrestigeAttemptResult: Equatable {
        case success                 // 성공(확률 또는 천장) — variant 4 해금
        case failure(pity: Int)      // 실패 — 누적 실패(천장 카운터) 값
        case notReady                // 조건 미충족(미만렙/이미 보유/잔액 부족)
    }

    /// 해당 펫에 Prestige 해금 시도가 가능한지 — 만렙(variant 3) + Prestige 미보유 + 조각 충분.
    func canAttemptPrestige(_ kind: PetKind) -> Bool {
        guard let o = Settings.shared.ownedPets[kind] else { return false }
        return o.unlockedVariants.contains(3)
            && !o.unlockedVariants.contains(PetOwnership.prestigeVariant)
            && Settings.shared.shinyShards >= PetOwnership.prestigeAttemptCost
    }

    /// Prestige 해금 1회 시도 — 조각 차감 후 확률(성공 시 variant 4 해금) 또는 천장(확정) 판정.
    /// 실패 시 누적 실패(천장 카운터) 증가, 성공 시 0으로 리셋.
    @discardableResult
    func attemptPrestige(_ kind: PetKind) -> PrestigeAttemptResult {
        let s = Settings.shared
        guard var o = s.ownedPets[kind],
              o.unlockedVariants.contains(3),
              !o.unlockedVariants.contains(PetOwnership.prestigeVariant),
              s.shinyShards >= PetOwnership.prestigeAttemptCost else { return .notReady }

        s.shinyShards -= PetOwnership.prestigeAttemptCost
        let attemptIndex = o.prestigeAttempts + 1                     // 이번이 몇 번째 시도인지
        let pity = attemptIndex >= PetOwnership.prestigePityCeiling   // 천장 도달 → 확정
        let success = pity || Double.random(in: 0..<1) < PetOwnership.prestigeSuccessChance

        if success {
            o.unlockedVariants.insert(PetOwnership.prestigeVariant)
            o.prestigeAttempts = 0
            s.ownedPets[kind] = o
            DebugLog.log("ShardLedger: Prestige 성공 [\(kind.rawValue)] \(attemptIndex)회차\(pity ? "(천장)" : "") (조각 total=\(s.shinyShards))")
            return .success
        } else {
            o.prestigeAttempts = attemptIndex
            s.ownedPets[kind] = o
            DebugLog.log("ShardLedger: Prestige 실패 [\(kind.rawValue)] pity=\(attemptIndex)/\(PetOwnership.prestigePityCeiling) (조각 total=\(s.shinyShards))")
            return .failure(pity: attemptIndex)
        }
    }
}
