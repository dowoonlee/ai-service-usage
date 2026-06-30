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
    // 신규 — 파티클류 (발밑/주변 입자)
    case heart       // 하트
    case star        // 별
    case petal       // 꽃잎
    // 신규 — 궤적류 (이동 시 뒤로 흐름)
    case stardust    // 별가루
    case flame       // 불꽃

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .footsteps: return "발자국"
        case .glow:      return "후광"
        case .trail:     return "잔상"
        case .aura:      return "오라"
        case .rainbow:   return "무지개"
        case .heart:     return "하트"
        case .star:      return "별"
        case .petal:     return "꽃잎"
        case .stardust:  return "별가루"
        case .flame:     return "불꽃"
        }
    }

    /// 구매 가격 (RP). 카탈로그 총합 7600 (기존 5000 + 신규 파티클 3×400 + 궤적 2×700).
    /// rainbow가 최상급(2000, 1등 한 달치). 펫 단위 귀속이라 "한 펫에 다 사는" 비용일 뿐. 배포 후 튜닝.
    var price: Int {
        switch self {
        case .footsteps: return 300
        case .glow:      return 600
        case .trail:     return 600
        case .aura:      return 1500
        case .rainbow:   return 2000
        case .heart, .star, .petal: return 400
        case .stardust, .flame:     return 700
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
        case .heart:     return "heart.fill"
        case .star:      return "star.fill"
        case .petal:     return "leaf.fill"
        case .stardust:  return "wand.and.stars"
        case .flame:     return "flame.fill"
        }
    }

    /// 코스메틱 타입 — 장착은 타입당 1개(배타). 상점도 타입별로 묶어 보여준다.
    var category: EffectCategory {
        switch self {
        case .glow, .aura:                          return .light
        case .trail, .rainbow, .stardust, .flame:   return .trail
        case .footsteps, .heart, .star, .petal:     return .particle
        }
    }
}

/// 코스메틱 타입(카테고리). 한 펫은 타입당 최대 1개를 장착한다.
enum EffectCategory: String, CaseIterable, Identifiable {
    case light       // 광원 (펫 뒤 glow/aura)
    case trail       // 궤적 (이동 시 뒤로 흐름)
    case particle    // 파티클 (발밑/주변 입자)

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .light:    return "광원"
        case .trail:    return "궤적"
        case .particle: return "파티클"
        }
    }
    /// 카테고리 헤더 아이콘 (SF Symbol).
    var iconName: String {
        switch self {
        case .light:    return "sun.max.fill"
        case .trail:    return "wind"
        case .particle: return "sparkles"
        }
    }
}

/// RP 적립/소비 ledger. 코인 경제(`CoinLedger`)와 완전 독립이며, 사용량 이벤트(`UsageConsumer`)에는
/// 참여하지 않는다 — faucet은 랭킹 순위 보상(`creditReward`), sink는 이펙트 구매(`purchaseEffect`)와
/// 프리미엄 가챠권 구매(`purchasePremiumTicket`).
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

    /// 외부 기여자 PR 머지 보너스. PR 1개 = `rpPerContributorPR` RP.
    /// (v0.10 이전엔 coin 지급이었으나 RP로 교체 — 기여 = 코스메틱 화폐.)
    static let rpPerContributorPR: Int = 500
    func creditContributorBonus(prCount: Int) {
        guard prCount > 0 else { return }
        creditReward(prCount * Self.rpPerContributorPR, reason: "contributor.\(prCount)PR")
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
        // 구매 즉시 장착 — 사면 바로 보이도록 (타입당 1슬롯: 같은 category 교체).
        equip(effect, for: kind)
        DebugLog.log("RankPointLedger: 이펙트 구매+장착 \(kind.rawValue) ← \(effect.rawValue)")
        return true
    }

    /// 이펙트 장착 — 같은 category의 기존 장착을 해제하고(타입당 1슬롯) 이 이펙트를 장착.
    /// 보유 여부는 호출 측이 보장한다. 끄기는 `toggleEquip`이 처리.
    func equip(_ effect: EffectKind, for kind: PetKind) {
        let s = Settings.shared
        var equipped = s.equippedEffects
        var set = equipped[kind] ?? []
        set = set.filter { $0.category != effect.category }
        set.insert(effect)
        equipped[kind] = set
        s.equippedEffects = equipped
    }

    /// RP 프리미엄 가챠권 1장 가격. 랭킹 월 1등 수입(2000 RP) 대비 ~0.75개월치 — "신중한 한 방".
    static let premiumTicketCostRP: Int = 1500

    /// RP로 프리미엄 가챠권 1장 구매 — 잔액 차감 + `premiumTickets += 1`을 한 트랜잭션으로.
    /// 잔액 부족이면 차감하지 않고 `false`. (이펙트와 달리 중복 개념 없는 소모성 재화.)
    @discardableResult
    func purchasePremiumTicket() -> Bool {
        let s = Settings.shared
        guard spend(Self.premiumTicketCostRP, reason: "premiumTicket") else { return false }
        s.premiumTickets += 1
        DebugLog.log("RankPointLedger: 프리미엄 가챠권 구매 (premiumTickets=\(s.premiumTickets))")
        return true
    }

    /// 보유한 이펙트의 장착 상태를 토글한다. 미보유면 무시(보유한 것만 장착 가능).
    func toggleEquip(_ effect: EffectKind, for kind: PetKind) {
        let s = Settings.shared
        guard s.petEffects[kind]?.contains(effect) == true else { return }
        if s.equippedEffects[kind]?.contains(effect) == true {
            var equipped = s.equippedEffects
            equipped[kind]?.remove(effect)
            s.equippedEffects = equipped
            DebugLog.log("RankPointLedger: 장착 해제 \(kind.rawValue) \(effect.rawValue)")
        } else {
            equip(effect, for: kind)   // 같은 category 배타 (타입당 1슬롯)
            DebugLog.log("RankPointLedger: 장착 \(kind.rawValue) ← \(effect.rawValue) (\(effect.category.rawValue))")
        }
    }
}
