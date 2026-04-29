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

    /// 한 번 더 뽑힌 결과를 반영. count++, 임계 도달 시 새 variant unlock.
    /// - Returns: 이번 호출로 새로 unlock된 variant index (없으면 nil)
    mutating func registerPull() -> Int? {
        count += 1
        // 5중복 → variant 1, 15 → 2, 40 → 3
        let thresholds: [(Int, Int)] = [(5, 1), (15, 2), (40, 3)]
        for (cnt, variant) in thresholds where count >= cnt && !unlockedVariants.contains(variant) {
            unlockedVariants.insert(variant)
            return variant
        }
        return nil
    }

    /// 누적 사용 시간 기반 variant unlock 체크. 가챠 중복(5/15/40)과 평행한 두 번째 진입 경로.
    /// 4일/8일/12일 누적 → variant 1/2/3. 실제 누적 카운터는 변하지 않고 `unlockedVariants`만 갱신.
    /// - Parameter totalSeconds: 해당 종의 `Settings.petUsageSeconds[kind]` 누적치.
    /// - Returns: 이번 호출로 새로 unlock된 variant index (없으면 nil)
    mutating func registerUsage(totalSeconds: TimeInterval) -> Int? {
        let thresholds: [(TimeInterval, Int)] = PetOwnership.usageThresholds
        for (sec, variant) in thresholds where totalSeconds >= sec && !unlockedVariants.contains(variant) {
            unlockedVariants.insert(variant)
            return variant
        }
        return nil
    }

    /// 사용 시간 → variant index 매핑. UI에서도 동일 값을 참조하도록 한 곳에 둠.
    /// `(임계초, variant 인덱스)` 오름차순.
    static let usageThresholds: [(TimeInterval, Int)] = [
        (4 * 86400, 1),
        (8 * 86400, 2),
        (12 * 86400, 3),
    ]
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
