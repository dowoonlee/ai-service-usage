import Foundation

// RP(Rank Point) 코스메틱 경제 — 랭킹 순위 보상으로만 적립되는 화폐 + 그걸로 사는 WalkingCat 이펙트.
// 코인 경제(CoinLedger)와 수급처가 완전히 분리된다: coins=사용량(진행), RP=순위(과시).
// 설계 전문은 docs/DESIGN_RP_ECONOMY.md.

/// RP로 구매하는 WalkingCat 코스메틱 이펙트. `Settings.petEffects`에 `PetKind` 단위로 귀속된다
/// (variant/이로치 무관 — "여우"를 사면 여우 모든 색에 적용). 이로치(색, `WalkingCat.hueDegrees`)와
/// 직교 — 색 위에 파티클/광원을 얹으므로 시각적으로 겹치지 않는다.
enum EffectKind: String, CaseIterable, Identifiable, Codable {
    case footsteps   // 발자국 파티클
    case glow        // 후광
    case trail       // 잔상
    case aura        // 풀 오라 (프리미엄)
    case rainbow     // Nyan Cat 무지개 트레일 (프리미엄)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .footsteps: return "발자국"
        case .glow:      return "후광"
        case .trail:     return "잔상"
        case .aura:      return "오라"
        case .rainbow:   return "무지개"
        }
    }

    /// 구매 가격 (RP). 카탈로그 총합 5000 = 1등 월수입(2000)의 2.5개월치.
    /// rainbow가 최상급(2000, 1등 한 달치). cf. docs/DESIGN_RP_ECONOMY.md. 배포 후 텔레메트리로 튜닝.
    var price: Int {
        switch self {
        case .footsteps: return 300
        case .glow:      return 600
        case .trail:     return 600
        case .aura:      return 1500
        case .rainbow:   return 2000
        }
    }

    /// 상점 칩 아이콘 (SF Symbol).
    var iconName: String {
        switch self {
        case .footsteps: return "pawprint.fill"
        case .glow:      return "sun.max.fill"
        case .trail:     return "wind"
        case .aura:      return "sparkles"
        case .rainbow:   return "rainbow"
        }
    }
}

/// RP 적립/소비 ledger. 코인 경제(`CoinLedger`)와 완전 독립이며, 사용량 이벤트(`UsageConsumer`)에는
/// 참여하지 않는다 — faucet은 랭킹 순위 보상(`creditReward`), sink는 이펙트 구매(`purchaseEffect`)뿐.
/// `Settings.rp`는 항상 본 ledger 경유로만 변경한다 (직접 mutate 금지 — `CoinLedger`와 동일 규약).
@MainActor
final class RankPointLedger {
    static let shared = RankPointLedger()
    private init() {}

    /// 랭킹 순위 보상 적립. claim 경로(서버 정산 수령)에서 호출.
    func creditReward(_ amount: Int, reason: String) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.rp += amount
        s.rpTotalEarned += amount
        DebugLog.log("RankPointLedger: +\(amount) RP (\(reason)) (total=\(s.rp))")
    }

    /// RP 차감. 잔액이 부족하면 차감하지 않고 `false`를 반환한다.
    @discardableResult
    func spend(_ amount: Int, reason: String) -> Bool {
        guard amount > 0 else { return false }
        let s = Settings.shared
        guard s.rp >= amount else {
            DebugLog.log("RankPointLedger: spend \(amount) RP 실패 — 잔액 부족 (\(s.rp))")
            return false
        }
        s.rp -= amount
        DebugLog.log("RankPointLedger: -\(amount) RP (\(reason)) (balance=\(s.rp))")
        return true
    }

    /// 이펙트 구매 — 잔액 차감 + `petEffects`(보유) 추가 + `equippedEffects`(자동 장착)를 한 트랜잭션으로.
    /// 이미 보유했거나(중복 결제 방지) 잔액이 부족하면 `false`를 반환하고 아무것도 바꾸지 않는다.
    @discardableResult
    func purchaseEffect(_ effect: EffectKind, for kind: PetKind) -> Bool {
        let s = Settings.shared
        if s.petEffects[kind]?.contains(effect) == true { return false }   // 이미 보유
        guard spend(effect.price, reason: "effect:\(kind.rawValue):\(effect.rawValue)") else { return false }
        var owned = s.petEffects
        owned[kind, default: []].insert(effect)
        s.petEffects = owned
        // 구매 즉시 장착 — 사면 바로 보이도록.
        var equipped = s.equippedEffects
        equipped[kind, default: []].insert(effect)
        s.equippedEffects = equipped
        DebugLog.log("RankPointLedger: 이펙트 구매+장착 \(kind.rawValue) ← \(effect.rawValue)")
        return true
    }

    /// 보유한 이펙트의 장착 상태를 토글한다. 미보유면 무시(보유한 것만 장착 가능).
    func toggleEquip(_ effect: EffectKind, for kind: PetKind) {
        let s = Settings.shared
        guard s.petEffects[kind]?.contains(effect) == true else { return }
        var equipped = s.equippedEffects
        if equipped[kind]?.contains(effect) == true {
            equipped[kind]?.remove(effect)
        } else {
            equipped[kind, default: []].insert(effect)
        }
        s.equippedEffects = equipped
        DebugLog.log("RankPointLedger: 장착 토글 \(kind.rawValue) \(effect.rawValue) → \(equipped[kind]?.contains(effect) == true ? "on" : "off")")
    }
}
