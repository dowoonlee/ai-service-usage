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
    case flag        // 길드 깃발 — 길드 소속이면 그 길드 로고, 아니면 기본 도트 깃발

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
        case .flag:      return "깃발"
        }
    }

    /// 구매 가격 (RP). 카탈로그 총합 8800 (기존 5000 + 파티클 3×400 + 궤적 2×700 + 깃발 1200).
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
        // 길드 정체성을 두르는 아이템이라 궤적류 중 상위. rainbow(2000) 아래로 둔다.
        case .flag:      return 1200
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
        case .flag:      return "flag.fill"
        }
    }

    /// 코스메틱 타입 — 장착은 타입당 1개(배타). 상점도 타입별로 묶어 보여준다.
    var category: EffectCategory {
        switch self {
        case .glow, .aura:                          return .light
        case .trail, .rainbow, .stardust, .flame,
             .flag:                                 return .trail
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

/// RP 증감 1건의 기록. "언제 얼마가 왜" 들어왔는지 확인할 수 없어 정상 적립조차 "안 들어온다"로
/// 체감되던 문제(#191)의 대응 — `RankPointLedger`가 모든 증감의 단일 경유점이라 여기서만 쌓으면
/// 누락이 없다. `amount`는 부호 있는 값(적립 +, 소비 −).
struct RPHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let amount: Int
    /// ledger reason 코드 원문 (예: `rank.weekly.2026-W30.5`, `effect.aura.fox`). 표시용 문구는
    /// `label`이 파생 — 원문을 보존해야 나중에 표기를 바꿔도 과거 기록이 살아난다.
    let reason: String

    init(amount: Int, reason: String, date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.amount = amount
        self.reason = reason
    }

    /// reason 코드 → 사용자용 한국어 라벨. 알 수 없는 코드는 적립/사용으로만 표기해 앞으로
    /// 새 reason이 추가돼도 UI가 깨지지 않는다.
    var label: String {
        // reason 코드의 구분자가 소스마다 다르다 — 정산은 `rank.weekly.2026-W30.5`(점),
        // 이펙트 구매는 `effect:fox:aura`(콜론). 종류 판정은 첫 토큰만 보므로 둘 다 받는다.
        let head = String(reason.prefix { $0 != "." && $0 != ":" })
        let parts = reason.split(separator: ".").map(String.init)
        switch head {
        case "rank":
            // rank.<periodType>.<period>.<rank> — 예: rank.weekly.2026-W30.5
            guard parts.count >= 4 else { return "순위 정산" }
            let kind: String
            switch parts[1] {
            case "weekly":         kind = "주간 정산"
            case "monthly":        kind = "월간 정산"
            case "guild-monthly":  kind = "길드 시상"
            default:               kind = "순위 정산"
            }
            return "\(kind) \(parts[2]) · \(parts[3])위"
        case "grant":
            let key = parts.dropFirst().joined(separator: ".")
            if key.hasPrefix("pvp-season") { return "아레나 시즌 보상" }
            return "보상 지급"
        case "contributor": return "기여자 보너스"
        case "coffee":      return "커피 후원 감사 보상"
        case "effect":
            // effect:<petKind>:<effectKind> — 이펙트 이름까지 보여준다.
            let fields = reason.split(separator: ":").map(String.init)
            if fields.count >= 3, let kind = EffectKind(rawValue: fields[2]) {
                return "이펙트 구매 · \(kind.displayName)"
            }
            return "이펙트 구매"
        case "premiumTicket": return "프리미엄 가챠권 구매"
        case "guild":       return parts.count > 1 && parts[1] == "rename" ? "길드명 변경" : "길드"
        default:            return amount >= 0 ? "적립" : "사용"
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
        record(amount, reason: reason)
        DebugLog.log("RankPointLedger: +\(amount) RP (\(reason)) (total=\(s.rp))")
    }

    /// 보관 상한 — 주간+월간 정산이 연 60건 남짓이라 100건이면 1년 이상 남는다.
    /// UserDefaults에 통째로 직렬화되므로 무한 성장은 막는다.
    static let historyLimit = 100

    /// 증감 1건 기록. credit/spend 양쪽이 호출 — 여기 한 곳만 거치면 이력이 새지 않는다.
    private func record(_ amount: Int, reason: String) {
        let s = Settings.shared
        var h = s.rpHistory
        h.append(RPHistoryEntry(amount: amount, reason: reason))
        if h.count > Self.historyLimit { h.removeFirst(h.count - Self.historyLimit) }
        s.rpHistory = h
    }

    /// 외부 기여자 PR 머지 보너스. PR 1개 = `rpPerContributorPR` RP.
    /// (v0.10에 coin → RP 교체. 이후 500 → 1,000으로 올리면서 coin 2,000도 함께 지급 —
    /// RP만으로는 코스메틱 외 쓸 데가 없어 기여 보상이 체감되지 않았다.)
    static let rpPerContributorPR: Int = 1000
    func creditContributorBonus(prCount: Int) {
        guard prCount > 0 else { return }
        creditReward(prCount * Self.rpPerContributorPR, reason: "contributor.\(prCount)PR")
    }

    /// RP 단가 상향(500 → 1,000)의 소급 차액 적립. 1회성.
    ///
    /// 차액 500은 **그 시점의 역사값이라 상수로 고정**한다. `rpPerContributorPR`에서 빼는 식으로
    /// 쓰면 다음 인상 때 이 소급액까지 같이 커져서, 아직 플래그를 안 거친 사용자가 당시 정책과
    /// 다른 금액을 받는다(`creditContributorBonusUpgrade`가 실제로 그 상태였다).
    private static let contributorRPBackfillDelta = 500
    func creditContributorRPBackfill(prCount: Int) {
        guard prCount > 0 else { return }
        creditReward(prCount * Self.contributorRPBackfillDelta, reason: "contributor.backfill.\(prCount)PR")
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
        record(-amount, reason: reason)
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

    /// 길드명 변경 비용 (RP). 길드장만 소비하며, 서버 rename 성공 응답 후 차감한다
    /// (생성권·데코와 동일한 "실패 시 보존" 원칙 — 차감은 `GuildView.performRename`이 직접 수행).
    static let guildRenameCostRP: Int = 300

    /// 길드 로고 변경 비용 (RP). rename과 같은 "실패 시 보존" 원칙으로 서버 성공 응답 후 차감.
    /// rename보다 싼 이유는 이름과 달리 유일성 제약이 없고 되돌리기가 쉬워서 — 남용 억제만 하면 된다.
    static let guildLogoCostRP: Int = 200

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
