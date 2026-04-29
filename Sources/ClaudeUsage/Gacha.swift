import Foundation

/// 가챠 엔진. 등급 분배 + 가중 랜덤 + 보유 상태 반영.
///
/// 분배 정책: 현실 동물 = Common, 의인화/판타지 = 상위 등급.
/// 종 수가 등급별로 16/9/4/1이라 종당 확률이 단조감소 (3.75/3.33/2.0/2.0%).
@MainActor
enum Gacha {
    static let pool: [Rarity: [PetKind]] = [
        .legendary: [.ninjaFrog],
        .epic:      [.maskDude, .ghost, .plant, .skull],
        .rare:      [.mushroom, .slime, .trunk, .radish, .rock1, .rock2, .rock3, .chameleon, .rino],
        .common:    [.fox, .wolf, .bear, .boar, .deer, .rabbit,
                     .angryPig, .bunny, .chicken, .duck, .blueBird, .fatBird,
                     .bat, .bee, .snail, .turtle],
    ]

    /// 환율 캘리브레이션 그레이스 기간 (이 기간 내엔 시드값 사용).
    static let calibrationGracePeriod: TimeInterval = 7 * 86400
    /// 첫 7일 동안 사용하는 시드 비용.
    static let seedPullCost: Int = 100
    /// 캘리브레이션 후 비용 안전 범위.
    static let pullCostBounds: ClosedRange<Int> = 50...2000

    /// 1뽑기 비용. 첫 7일은 `seedPullCost`, 이후 사용자 평균 일일 적립 × 3일 (안전 범위 내).
    static var pullCost: Int {
        let s = Settings.shared
        guard let firstAt = s.firstCreditedAt else { return seedPullCost }
        let elapsed = Date().timeIntervalSince(firstAt)
        if elapsed < calibrationGracePeriod { return seedPullCost }
        guard s.coinsTotalEarned > 0 else { return seedPullCost }
        let avgDaily = Double(s.coinsTotalEarned) / (elapsed / 86400)
        return min(pullCostBounds.upperBound, max(pullCostBounds.lowerBound, Int(avgDaily * 3)))
    }

    /// Rarity 가중 랜덤 → 등급 내 균등 랜덤.
    static func draw<RNG: RandomNumberGenerator>(using rng: inout RNG) -> (PetKind, Rarity) {
        let r = Double.random(in: 0..<1, using: &rng)
        var cumulative: Double = 0
        // 작은 등급(legendary) 먼저: cumulative 0.02 → 0.10 → 0.40 → 1.00
        let order: [Rarity] = [.legendary, .epic, .rare, .common]
        var rarity: Rarity = .common
        for tier in order {
            cumulative += tier.weight
            if r < cumulative { rarity = tier; break }
        }
        let kinds = pool[rarity] ?? []
        let kind = kinds.randomElement(using: &rng) ?? .fox
        return (kind, rarity)
    }

    static func draw() -> (PetKind, Rarity) {
        var rng = SystemRandomNumberGenerator()
        return draw(using: &rng)
    }

    /// 가챠권 또는 코인을 소비하고 한 번 뽑는다.
    /// - Parameter useTicket: true면 무료 가챠권 사용, false면 코인 차감.
    /// - Returns: 결과 `GachaPull` (kind, rarity, 새로 unlock된 variant).
    @discardableResult
    static func performPull(useTicket: Bool) throws -> GachaPull {
        let s = Settings.shared
        if useTicket {
            guard s.gachaTickets > 0 else { throw GachaError.noTickets }
            s.gachaTickets -= 1
        } else {
            guard s.coins >= pullCost else { throw GachaError.insufficientCoins }
            s.coins -= pullCost
        }

        let wasEmpty = s.ownedPets.isEmpty
        let (kind, rarity) = draw()
        var owned = s.ownedPets
        var newVariant: Int? = nil
        if owned[kind] == nil {
            owned[kind] = .initial()
        } else {
            var existing = owned[kind]!
            newVariant = existing.registerPull()
            owned[kind] = existing
        }
        s.ownedPets = owned

        // 첫 가챠 결과를 양쪽 차트의 활성 펫으로 자동 할당.
        if wasEmpty {
            s.petClaudeKind = kind
            s.petCursorKind = kind
            s.petClaudeVariant = 0
            s.petCursorVariant = 0
        }

        let pull = GachaPull(pulledAt: Date(), kind: kind, rarity: rarity, variantUnlocked: newVariant)
        DebugLog.log("Gacha: \(kind.rawValue) [\(rarity.rawValue)] count=\(owned[kind]!.count)" +
                     (newVariant != nil ? " newVariant=\(newVariant!)" : ""))
        return pull
    }
}

enum GachaError: Error, LocalizedError {
    case noTickets
    case insufficientCoins

    var errorDescription: String? {
        switch self {
        case .noTickets:         return "가챠권이 없습니다"
        case .insufficientCoins: return "코인이 부족합니다"
        }
    }
}
