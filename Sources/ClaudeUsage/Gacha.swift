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
    static let seedPullCost: Int = 300
    /// 캘리브레이션 후 비용 안전 범위.
    static let pullCostBounds: ClosedRange<Int> = 50...2000
    /// 평균 일일 적립의 몇 배를 1뽑기 비용으로 할지. 일주일에 2번 ≈ 3.5일치.
    static let pullCostDayMultiplier: Double = 3.5

    /// 1뽑기 비용. 첫 7일은 `seedPullCost`, 이후 사용자 평균 일일 적립 × `pullCostDayMultiplier` (안전 범위 내).
    static var pullCost: Int {
        let s = Settings.shared
        guard let firstAt = s.firstCreditedAt else { return seedPullCost }
        let elapsed = Date().timeIntervalSince(firstAt)
        if elapsed < calibrationGracePeriod { return seedPullCost }
        guard s.coinsTotalEarned > 0 else { return seedPullCost }
        let avgDaily = Double(s.coinsTotalEarned) / (elapsed / 86400)
        return min(pullCostBounds.upperBound, max(pullCostBounds.lowerBound, Int(avgDaily * pullCostDayMultiplier)))
    }

    /// Rarity 가중 랜덤 → 등급 내 균등 랜덤. (kind, rarity) 결정만.
    static func drawKind<RNG: RandomNumberGenerator>(using rng: inout RNG) -> (PetKind, Rarity) {
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

    static func drawKind() -> (PetKind, Rarity) {
        var rng = SystemRandomNumberGenerator()
        return drawKind(using: &rng)
    }

    /// 잔액만 차감하고 결과(kind, rarity)를 결정한다.
    /// **보유 상태(`ownedPets`)는 변경하지 않음** — `commit(_:)`을 부화 애니메이션
    /// 완료 시점에 호출해서 반영해야 한다 (인벤토리 미리 해금되는 버그 방지).
    /// 반환되는 GachaPull의 `variantUnlocked`는 nil; commit 후의 결과로 채워진다.
    @discardableResult
    static func roll(useTicket: Bool) throws -> GachaPull {
        let s = Settings.shared
        if useTicket {
            guard s.gachaTickets > 0 else { throw GachaError.noTickets }
            s.gachaTickets -= 1
        } else {
            guard s.coins >= pullCost else { throw GachaError.insufficientCoins }
            s.coins -= pullCost
        }
        let (kind, rarity) = drawKind()
        return GachaPull(pulledAt: Date(), kind: kind, rarity: rarity, variantUnlocked: nil)
    }

    /// `roll(useTicket:)` 결과를 보유 상태에 반영. 부화 애니메이션의 hatched 진입 시점에 호출.
    /// - Returns: `variantUnlocked`가 채워진 새 `GachaPull` (UI 표시용).
    @discardableResult
    static func commit(_ pull: GachaPull) -> GachaPull {
        let s = Settings.shared
        let wasEmpty = s.ownedPets.isEmpty
        var owned = s.ownedPets
        var newVariant: Int? = nil
        if owned[pull.kind] == nil {
            owned[pull.kind] = .initial()
        } else {
            var existing = owned[pull.kind]!
            newVariant = existing.registerPull()
            owned[pull.kind] = existing
        }
        s.ownedPets = owned
        // 첫 가챠 결과를 양쪽 차트의 활성 펫으로 자동 할당.
        if wasEmpty {
            s.petClaudeKind = pull.kind
            s.petCursorKind = pull.kind
            s.petClaudeVariant = 0
            s.petCursorVariant = 0
        }
        DebugLog.log("Gacha commit: \(pull.kind.rawValue) [\(pull.rarity.rawValue)] count=\(owned[pull.kind]!.count)" +
                     (newVariant != nil ? " newVariant=\(newVariant!)" : ""))
        return GachaPull(pulledAt: pull.pulledAt, kind: pull.kind, rarity: pull.rarity,
                         variantUnlocked: newVariant)
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
