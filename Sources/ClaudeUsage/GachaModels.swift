import Foundation
import SwiftUI

/// 한 펫 종에 대한 보유 상태.
/// - count: 가챠로 누적 뽑힌 횟수 (중복 포함)
/// - unlockedVariants: 보유한 색상 변종 (이로치). 0 = 기본, 1/2/3 = shiny tier, 4 = Prestige(홀로 애니)
/// - creditedShardUnits: variant 3(8유닛) 초과 오버플로우 중 이미 이로치 조각으로 지급한 정수 유닛(중복지급 방지)
struct PetOwnership: Codable, Hashable {
    var count: Int
    var unlockedVariants: Set<Int>
    var creditedShardUnits: Int = 0
    /// Prestige 누적 실패 시도 수(천장 카운터). 성공 시 0으로 리셋.
    var prestigeAttempts: Int = 0

    /// Prestige(홀로 애니) variant 인덱스. 이로치 조각으로 해금 시도해서 얻는다.
    static let prestigeVariant = 4
    /// 만렙(variant 3) 초과 오버플로우 1유닛당 지급하는 이로치 조각 수.
    static let shardsPerOverflowUnit = 3
    /// Prestige 해금 시도 1회 비용(이로치 조각).
    static let prestigeAttemptCost = 33
    /// Prestige 시도 성공 확률.
    static let prestigeSuccessChance = 0.15
    /// Prestige 천장 — 이 회차(누적 실패 +1) 시도는 확정 성공.
    static let prestigePityCeiling = 10
    /// 자동 해금 최고 임계(= variant 3 유닛). 이 위로가 오버플로우.
    static var overflowStartUnits: Double { variantUnitThresholds.last?.0 ?? 8.0 }

    /// 첫 뽑기 시 호출. count = 1, variant 0 unlock.
    static func initial() -> PetOwnership {
        PetOwnership(count: 1, unlockedVariants: [0])
    }

    /// 만렙(variant 3) 초과 진행분에서 이번에 새로 지급할 이로치 조각 수를 반환하고
    /// `creditedShardUnits`를 갱신(정수 유닛 단위, 중복지급 방지). variant 3 미해금이면 0.
    mutating func claimOverflowShards(usageSeconds: TimeInterval) -> Int {
        guard unlockedVariants.contains(3) else { return 0 }
        let overflow = Self.progressUnits(count: count, usageSeconds: usageSeconds) - Self.overflowStartUnits
        let totalUnits = overflow > 0 ? Int(overflow.rounded(.down)) : 0
        let newUnits = totalUnits - creditedShardUnits
        guard newUnits > 0 else { return 0 }
        creditedShardUnits = totalUnits
        return newUnits * Self.shardsPerOverflowUnit
    }

    /// 마이그레이션 시드 — 현재 오버플로우 유닛을 '이미 지급됨'으로 세팅(과거분 소급 지급 방지).
    mutating func seedCreditedShardUnits(usageSeconds: TimeInterval) {
        let overflow = Self.progressUnits(count: count, usageSeconds: usageSeconds) - Self.overflowStartUnits
        creditedShardUnits = overflow > 0 ? Int(overflow.rounded(.down)) : 0
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

extension PetOwnership {
    // creditedShardUnits는 신규 필드 — 구버전 저장 데이터엔 없으므로 decodeIfPresent로 기본 0 처리.
    // (동기화된 encode는 컴파일러 합성 사용. init(from:)을 extension에 둬 memberwise init도 유지.)
    private enum CodingKeys: String, CodingKey { case count, unlockedVariants, creditedShardUnits, prestigeAttempts }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        unlockedVariants = try c.decode(Set<Int>.self, forKey: .unlockedVariants)
        creditedShardUnits = try c.decodeIfPresent(Int.self, forKey: .creditedShardUnits) ?? 0
        prestigeAttempts = try c.decodeIfPresent(Int.self, forKey: .prestigeAttempts) ?? 0
    }
}

/// 사용자가 차트에 띄우려고 활성화한 펫 (kind + variant 페어).
struct PetSelection: Codable, Hashable {
    var kind: PetKind
    var variant: Int  // 0 = 기본, 1/2/3 = shiny tier
}

/// 재사용 가능한 명명된 파티 프리셋. 최대 `Settings.maxPartySize` 마리(종 유니크). `members[0]` = 리더.
/// 각 데이터소스(claude/cursor/codex)는 프리셋을 하나씩 "할당"해 참조한다 — 같은 프리셋을
/// 여러 소스에 할당하면 편집이 양쪽에 함께 반영된다(단일 소스 오브 트루스).
struct PartyPreset: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var members: [PetSelection]
}

/// 가챠 등급. common = 가장 흔함 → legendary → mythic = 가장 희귀(최상위).
/// mythic은 일반 코인 가챠에 등장하지 않고(weight 0), RP 프리미엄 가챠권으로만 뽑힌다.
enum Rarity: String, Codable, CaseIterable, Hashable {
    case common, rare, epic, legendary, mythic

    var displayName: String {
        switch self {
        case .common:    return "Common"
        case .rare:      return "Rare"
        case .epic:      return "Epic"
        case .legendary: return "Legendary"
        case .mythic:    return "Mythic"
        }
    }

    /// 등급 자체가 뽑힐 확률(일반 가챠 `drawKind`). 등급 내에선 종이 균등 배분.
    /// mythic = 0 — 일반 가챠 미등장(프리미엄 전용). 합은 legendary까지 1.0.
    var weight: Double {
        switch self {
        case .common:    return 0.60
        case .rare:      return 0.30
        case .epic:      return 0.08
        case .legendary: return 0.02
        case .mythic:    return 0.0
        }
    }

    /// 셋 보너스(`PetCollection.bonusCoins`) 산정에 쓰는 등급별 코인 가치.
    /// 가챠 weight와 inversely 가까운 곡선 — Common 100 → Legendary 2500 (25배).
    /// weight 비(0.60/0.02 = 30배)보다 살짝 완만 — 셋 한 개에 Legendary가 들어있다고
    /// 보너스가 폭주하지 않도록 의도적으로 압축. e.g., Vibe Coders(L×2 + E×2 + R×2 + C×2)
    /// = 7400 → ×1.5 = 11,100 coin (≈ 37 pulls 가치).
    var coinValue: Int {
        switch self {
        case .common:    return 100
        case .rare:      return 300
        case .epic:      return 800
        case .legendary: return 2500
        case .mythic:    return 5000
        }
    }

    /// 도감 헤더, 결과 카드, 인벤토리 띠 등 등급 시각화에 공통으로 쓰는 색상.
    /// (이전엔 `GachaView.rarityColor`와 `GachaPetCard.rarityColor` 두 곳에 동일 매핑이
    /// 중복되어 있었음 — enum prop으로 단일화.)
    var color: Color {
        switch self {
        case .common:    return .gray
        case .rare:      return .blue
        case .epic:      return .purple
        case .legendary: return .orange
        // 최상위 — legendary(orange)와 대비되는 강렬한 진홍/금빛. 그라데이션은 카드 UI에서 별도.
        case .mythic:    return Color(red: 0.86, green: 0.08, blue: 0.24)
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

/// 10연차 결과 1건 — `commit` 후 확정 상태를 담는다. 결과 그리드의 halo 판정(신규=등급색/중복=회색)과
/// 흐림 처리에 쓰인다. `isNew`는 그 칸 commit *직전* 보유 여부 기준 — 같은 종이 배치 안에서 두 번
/// 나오면 첫 칸 isNew=true, 둘째 칸 isNew=false로 정확히 갈린다.
struct MultiPullResult: Hashable {
    let pull: GachaPull
    let isNew: Bool
    let count: Int
}
