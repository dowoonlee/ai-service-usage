import Foundation

/// 한 펫 종에 대한 보유 상태.
/// - count: 가챠로 누적 뽑힌 횟수 (중복 포함)
/// - unlockedVariants: 보유한 색상 변종 (이로치). 0 = 기본, 1/2/3 = shiny tier
struct PetOwnership: Codable, Hashable {
    var count: Int
    var unlockedVariants: Set<Int>

    /// 첫 뽑기 시 호출. count = 1, variant 0 unlock.
    static func initial() -> PetOwnership {
        PetOwnership(count: 1, unlockedVariants: [0])
    }

    /// 한 번 더 뽑힌 결과를 반영. count++, 합산 진행도(가챠 중복 + 사용 시간) 임계 도달 시 variant unlock.
    /// - Parameter usageSeconds: 해당 종의 `Settings.petUsageSeconds[kind]` 현재 누적치 (합산 평가용).
    /// - Returns: 이번 호출로 새로 unlock된 variant index (없으면 nil)
    mutating func registerPull(usageSeconds: TimeInterval) -> Int? {
        count += 1
        return updateUnlocks(usageSeconds: usageSeconds)
    }

    /// 누적 사용 시간 변경을 반영. 합산 진행도 재평가만 — 카운터 자체는 변하지 않음.
    /// - Parameter totalSeconds: 해당 종의 `Settings.petUsageSeconds[kind]` 누적치.
    /// - Returns: 이번 호출로 새로 unlock된 variant index (없으면 nil)
    mutating func registerUsage(totalSeconds: TimeInterval) -> Int? {
        return updateUnlocks(usageSeconds: totalSeconds)
    }

    /// 가챠 중복 + 사용 시간을 합산 unit으로 환산해서 variant 해금 평가.
    private mutating func updateUnlocks(usageSeconds: TimeInterval) -> Int? {
        let units = Self.progressUnits(count: count, usageSeconds: usageSeconds)
        for (threshold, variant) in Self.variantUnitThresholds
        where units >= threshold && !unlockedVariants.contains(variant) {
            unlockedVariants.insert(variant)
            return variant
        }
        return nil
    }

    /// 합산 진행 단위 환산. 5 중복 = 1 unit, 4일 사용 = 1 unit (variant 1 단독 임계 등가).
    /// 1 pull = 0.2u, 1초 = 1/(4·86400)u → 가챠와 사용 시간을 더해서 variant 해금 평가에 사용.
    static let pullUnit: Double = 1.0 / 5.0
    static let secondUnit: Double = 1.0 / (4.0 * 86400)

    /// variant 1/2/3 = 1/3/8 unit. 가챠 단독 = 5/15/40 중복, 사용 단독 = 4일/12일/32일과 등가.
    /// 두 경로가 합산되므로 mixed 사용자는 더 빨리 해금. e.g., 가챠 4중복(0.8u) + 1d(0.25u) = 1.05u → variant 1.
    static let variantUnitThresholds: [(Double, Int)] = [(1.0, 1), (3.0, 2), (8.0, 3)]

    /// 합산 progress unit 계산. UI 게이지·해금 평가가 같은 식을 쓰도록 한 곳에 둠.
    static func progressUnits(count: Int, usageSeconds: TimeInterval) -> Double {
        Double(count) * pullUnit + usageSeconds * secondUnit
    }
}

/// 사용자가 차트에 띄우려고 활성화한 펫 (kind + variant 페어).
struct PetSelection: Codable, Hashable {
    var kind: PetKind
    var variant: Int  // 0 = 기본, 1/2/3 = shiny tier
}

/// 가챠 등급. common = 가장 흔함 → legendary = 가장 희귀.
enum Rarity: String, Codable, CaseIterable, Hashable {
    case common, rare, epic, legendary

    var displayName: String {
        switch self {
        case .common:    return "Common"
        case .rare:      return "Rare"
        case .epic:      return "Epic"
        case .legendary: return "Legendary"
        }
    }

    /// 등급 자체가 뽑힐 확률. 등급 내에선 종이 균등 배분.
    var weight: Double {
        switch self {
        case .common:    return 0.60
        case .rare:      return 0.30
        case .epic:      return 0.08
        case .legendary: return 0.02
        }
    }
}

/// 가챠 1회 이력 — `JSONLStore<GachaPull>`로 영속 가능 (M4 인벤토리 표시용).
struct GachaPull: Codable, Hashable {
    var pulledAt: Date
    var kind: PetKind
    var rarity: Rarity
    /// 이번 뽑기로 새로 unlock된 variant index. nil = 새 variant 없음 (단순 중복).
    var variantUnlocked: Int?
}
