import Foundation

// ============================================================================
// 코인 / VP 적립 체계 — Design Doc
// ============================================================================
//
// 4개의 카운터가 1개의 입력에서 갈라져 나가는 구조. 입력 종류별로 진입점이 다르며,
// 각 카운터는 자신의 책임만 갖는다.
//
//   ① Settings.coins / coinsTotalEarned
//      모든 적립의 최종 도착점. coins=잔액(가챠 소비), coinsTotalEarned=누적(임계 평가).
//      반드시 CoinLedger의 메서드 경유 — 직접 mutate 금지 (Gacha 차감만 예외).
//
//   ② Settings.claudeCoinsEarned / cursorCoinsEarned
//      ①의 부분집합 — 사용량 소스만 분기 누적. 도장(Vibe Coder 카테고리),
//      칭호(.vibeCoder/.vibeMaster) 등에서 임계 평가에 사용.
//
//   ③ Settings.rankingScoreEarnedVP
//      "사용량의 USD 가치" 추정 — 보드 제출 source-of-truth. ①②와 완전 독립.
//      가격 비례 환산이라 plan multiplier 무관, 사용량 자체에 비례.
//
//   ④ Settings.firstCreditedAt
//      첫 적립 시각. 평균 일일 적립 / 사용 일수 계산용 (Day One/Veteran/Long Hauler 칭호).
//      ①과 함께 갱신.
//
// ──────────── 입력 → 도착점 매핑 ────────────
//
//   "사용량 비례 적립":
//     Claude 5h/7d pct delta, Cursor Ultra cents, Cursor Pro/Free request delta 등
//     → UsageEventProducer가 UsageEvent emit → UsageEventBus broadcast
//     → CoinLedger.consume(event)이 ①② 갱신
//     → VPLedger.consume(event)이 ③ 갱신
//     → ④는 CoinLedger.credit() 내부에서 갱신
//
//   "행동/달성 보너스" (Wellness, PR, Collection, Badge, 일회성 캠페인 등):
//     → 해당 source가 CoinLedger.creditBonus/creditWellness/creditContributorBonus
//        /creditCollectionBonus 직접 호출
//     → ①과 ④만 갱신. ②③ 영향 없음 (의도적 — "사용량 비례"가 아님).
//
//   "Gacha 차감":
//     → Gacha.swift 내부에서 settings.coins -= price 직접 mutate (잔액 감소만, 누적 영향 X)
//
// ──────────── 신규 적립 추가 가이드 ────────────
//
//   사용량 소스 (예: Gemini API):
//     1. UsageSource enum에 case 추가
//     2. UsageEventProducer에 ingestXxx() 추가 — pureValue, coinFactor, vpFactor 정의
//     3. ViewModel에서 ingestXxx() 호출
//     4. 끝. CoinLedger/VPLedger는 자동 처리.
//
//   행동 보너스 (예: "친구 초대 +500 coin"):
//     1. 트리거 위치에서 CoinLedger.shared.creditBonus(500, reason: "invite") 호출
//     2. 끝.
//
//   ②(vibe counter)에 영향 줘야 하는 새 분류 (드물 것):
//     UsageSource.vibeCategory 분기 + Settings 필드 + CoinSource enum 확장.
//
// ============================================================================

/// 사용량 기반 가챠 코인 적립 ledger.
///
/// UsageConsumer로서 UsageEvent를 받아 ①② 갱신. 사용량 외 보너스는 직접 메서드 호출.
@MainActor
final class CoinLedger: UsageConsumer {
    static let shared = CoinLedger()
    private init() {}

    // MARK: - Plan economics (namespace)

    /// 1 cent = 0.1 coin. v0.6.x balance patch — 1:1이면 Ultra 한 달 한도($400)가 40,000 coin
    /// 폭주. 1/10로 낮춰 Ultra 한 달 max ~4,000 coin (가챠 ~20회/월).
    static let cursorCentToCoin: Double         = 0.1
    /// Claude 5h 윈도우 100% 채울 때 받는 coin (Pro 기준, plan multiplier 적용 전).
    static let claudeFiveHourMaxCoin: Double    = 30
    /// Claude 7d 윈도우 100% 채울 때 받는 coin (Pro 기준).
    static let claudeSevenDayMaxCoin: Double    = 60
    /// Codex 5h/7d 윈도우 만점 coin — Claude와 동일 스케일(30/60).
    static let codexFiveHourMaxCoin: Double     = 30
    static let codexSevenDayMaxCoin: Double     = 60
    /// Codex free monthly 창 만점 coin. `claudeMaxPureCoinPerMonth`(4578)와 동일 값으로 잡아
    /// 월 풀 사용 시 pureValue 합이 4578 → VP = 4578 × (codexPlanPriceVP("free")=500 / 4578) = 500,
    /// Claude/Cursor Free(~500 VP)와 형평. 5h/7d(30/60)와 스케일이 다른 건 의도 — monthly는 한 달에
    /// 한 번만 0→100% 채우는 단일 창이라 만점이 곧 한 달치 전체다.
    static let codexMonthlyMaxCoin: Double      = claudeMaxPureCoinPerMonth

    /// 누적 % 위치 → 누적 coin 비율. 0/1은 고정, 중간은 concave (sqrt). 초반 적립률↑.
    nonisolated static func curve(_ x: Double) -> Double {
        let clamped = max(0, min(1, x))
        return clamped.squareRoot()
    }

    /// Claude plan별 coin multiplier. Free=0.5 / Pro·Team=1 / Max 5x=1.5 / Max 20x=2.5 / Enterprise=1.5.
    nonisolated static func planMultiplier(_ planName: String?) -> Double {
        guard let name = planName?.lowercased() else { return 1.0 }
        if name.contains("max 20")   { return 2.5 }
        if name.contains("max 5") || name.contains("max") { return 1.5 }
        if name.contains("enterprise") { return 1.5 }
        if name.contains("pro") || name.contains("team") { return 1.0 }
        if name.contains("free") { return 0.5 }
        return 1.0
    }

    /// Codex plan별 coin multiplier (결정 A). 가격 동급 Claude와 일치 — Plus($20)=1.0 / Pro($200)=2.5.
    /// Claude의 planMultiplier와 분리한 이유: "pro" 문자열이 Claude Pro(1.0)와 Codex Pro(2.5)로 의미가 달라
    /// 같은 함수로 합치면 오분류된다. "prolite"도 pro 계열로 흡수.
    nonisolated static func codexPlanMultiplier(_ planName: String?) -> Double {
        guard let name = planName?.lowercased() else { return 1.0 }
        if name.contains("pro") { return 2.5 }
        if name.contains("plus") { return 1.0 }
        if name.contains("business") || name.contains("team") || name.contains("enterprise") { return 1.5 }
        if name.contains("free") { return 0.5 }
        return 1.0
    }

    // MARK: - VP economics (namespace)

    /// Claude plan별 한 달 max VP (= 가격 cents). Free는 Pro의 1/4 floor.
    nonisolated static func claudePlanPriceVP(_ planName: String?) -> Int {
        guard let name = planName?.lowercased() else { return 2000 }
        if name.contains("max 20") { return 20000 }
        if name.contains("max 5") || name.contains("max") { return 10000 }
        if name.contains("enterprise") { return 10000 }
        if name.contains("pro") || name.contains("team") { return 2000 }
        if name.contains("free") { return 500 }
        return 2000
    }

    /// Codex plan별 한 달 max VP (결정 B). Claude와 동일 환산 스케일 — Plus($20)=2000 / Pro($200)=20000 cents.
    nonisolated static func codexPlanPriceVP(_ planName: String?) -> Int {
        guard let name = planName?.lowercased() else { return 2000 }
        if name.contains("pro") { return 20000 }
        if name.contains("plus") { return 2000 }
        if name.contains("business") || name.contains("team") || name.contains("enterprise") { return 10000 }
        if name.contains("free") { return 500 }
        return 2000
    }

    /// Cursor plan별 한 달 max VP. Ultra는 chargedCents 그대로 (pay-per-use, $400 cap).
    nonisolated static func cursorPlanPriceVP(_ plan: CursorPlan?) -> Int {
        guard let plan else { return 0 }
        switch plan {
        case .ultra:    return 40000
        case .pro:      return 2000
        case .business: return 4000
        case .free:     return 500
        case .unknown:  return 2000
        }
    }

    /// 이론치 한 달 max pure Claude coin (planMultiplier 미적용).
    /// 5h 4.8회/일 × 30일 × 30 coin + 7d 4.3회/월 × 60 coin ≈ 4578. VP 정규화 분모.
    static let claudeMaxPureCoinPerMonth: Double = 4578

    // MARK: - UsageConsumer

    /// 사용량 이벤트 → 가챠 코인 적립. coinFactor가 0이면 적립 안 함 (Pro/Free Cursor 등).
    /// VibeCategory에 따라 ②(claudeCoinsEarned/cursorCoinsEarned) 분기.
    func consume(_ event: UsageEvent) {
        let coinAmount = event.pureValue * event.context.coinFactor
        guard coinAmount > 0 else { return }
        let source: CoinSource
        switch event.source.vibeCategory {
        case .claude: source = .claude
        case .cursor: source = .cursor
        case .codex:  source = .codex
        }
        let earned = creditWithCarry(amount: coinAmount,
                                     fraction: event.source.coinFractionKeyPath,
                                     source: source)
        if earned > 0 {
            DebugLog.log("CoinLedger: \(event.source.rawValue) +\(earned) coin (total=\(Settings.shared.coins))")
        }
    }

    // MARK: - 사용량 외 적립 (event bus 우회 — 의도적, VP 영향 없음)

    /// 행동/달성 보너스 통합 진입점. Badge, 일회성 캠페인 등. ① + ④만 갱신.
    /// 직접 `s.coins +=` mutate는 절대 금지 — 항상 본 메서드 경유.
    func creditBonus(_ amount: Int, reason: String) {
        guard amount > 0 else { return }
        credit(amount)
        DebugLog.log("CoinLedger: Bonus +\(amount) coin (\(reason)) (total=\(Settings.shared.coins))")
    }

    /// Wellness nudge 보상 (1분 내 클릭 시 정액).
    func creditWellness(amount: Int) {
        credit(amount)
        DebugLog.log("CoinLedger: Wellness +\(amount) coin (total=\(Settings.shared.coins))")
    }

    /// 외부 기여자 PR 머지 보너스. PR 1개 = 1,000 coin.
    static let coinPerContributorPR: Int = 1000
    func creditContributorBonus(prCount: Int) {
        guard prCount > 0 else { return }
        let amount = prCount * Self.coinPerContributorPR
        credit(amount)
        DebugLog.log("CoinLedger: Contributor +\(amount) coin (\(prCount) PR) (total=\(Settings.shared.coins))")
    }

    /// v0.6.10 PR 보너스 단가 상향(50 → 1000)의 소급 차액 적립. 1회성.
    func creditContributorBonusUpgrade(prCount: Int) {
        guard prCount > 0 else { return }
        let perPRDelta = Self.coinPerContributorPR - 50
        let amount = perPRDelta * prCount
        guard amount > 0 else { return }
        credit(amount)
        DebugLog.log("CoinLedger: Contributor upgrade +\(amount) coin (\(prCount) PR × +\(perPRDelta)) (total=\(Settings.shared.coins))")
    }

    /// 펫 컬렉션 컴플리트 보너스. rarity 합 × 1.5.
    func creditCollectionBonus(_ c: PetCollection) {
        let amount = c.bonusCoins
        credit(amount)
        DebugLog.log("CoinLedger: Collection [\(c.displayName)] +\(amount) coin (total=\(Settings.shared.coins))")
    }

    // MARK: - 코인 소비 (구매)

    /// 동적 맵(테마) 구매. 무료/이미 보유/잔액 부족이면 false.
    /// 잔액만 차감 (누적 coinsTotalEarned 불변 — 소비. Gacha 차감과 동일 정책).
    @discardableResult
    func purchaseTheme(_ theme: PetTheme) -> Bool {
        let s = Settings.shared
        guard !theme.isFree, !s.ownedThemes.contains(theme.rawValue) else { return false }
        guard spend(theme.price, reason: "맵 [\(theme.displayName)]") else { return false }
        s.ownedThemes.insert(theme.rawValue)
        return true
    }

    /// 파티 프리셋 슬롯 1개 구매. 비용은 `nextPartyPresetSlotCost`(2000부터 구매당 +1000).
    /// 성공 시 코인 차감 + 구매 슬롯 카운터 증가 → `maxPartyPresets`가 1 늘어난다.
    func purchasePartyPresetSlot() -> Bool {
        let s = Settings.shared
        guard spend(s.nextPartyPresetSlotCost, reason: "파티 프리셋 슬롯") else { return false }
        s.purchasedPartyPresetSlots += 1
        return true
    }

    /// 길드 생성권 가격 — 10연차(2,700)·파티 슬롯 첫 구매(2,000)보다 약간 높은 "결단" 가격.
    static let guildPermitCost = 3_000

    /// 길드 데코/테마 기부 지출 (P2b) — 서버 반영 성공 응답 **후** 차감 (생성권 원칙: 실패 시
    /// 보존). 호출 측이 사전 잔액 검증을 하므로 여기선 음수만 방어.
    func spendGuildDecor(_ cost: Int, item: String) {
        let s = Settings.shared
        s.coins = max(0, s.coins - cost)
        DebugLog.log("CoinLedger: 길드 기부 [\(item)] -\(cost) coin (total=\(s.coins))")
    }

    /// 길드 생성권 구매 (소모품). 소모는 GuildView가 서버 guild-create 성공 응답 후 직접 차감 —
    /// 서버 실패 시 생성권이 보존되도록 (가챠 roll/commit 분리와 동일한 사용자 우선 원칙).
    func purchaseGuildPermit() -> Bool {
        let s = Settings.shared
        guard spend(Self.guildPermitCost, reason: "길드 생성권") else { return false }
        s.guildPermits += 1
        return true
    }

    // MARK: - 내부 helpers

    /// 코인 차감 (구매 공통). 잔액 부족이면 차감하지 않고 false. `RankPointLedger.spend`와 동형 —
    /// 누적 `coinsTotalEarned`는 불변(소비라 `credit`과 대칭). 각 구매 메서드는 이 헬퍼로 잔액을
    /// 깎은 뒤 자기 부수효과(테마 보유·슬롯/생성권 카운터)만 처리한다.
    @discardableResult
    private func spend(_ amount: Int, reason: String) -> Bool {
        guard amount > 0 else { return false }
        let s = Settings.shared
        guard s.coins >= amount else { return false }
        s.coins -= amount
        DebugLog.log("CoinLedger: -\(amount) coin (\(reason)) (total=\(s.coins))")
        return true
    }

    private enum CoinSource { case claude, cursor, codex }

    /// ① + ④ + (옵션) ② 갱신. 모든 적립의 공통 진입.
    private func credit(_ amount: Int, source: CoinSource? = nil) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.coins += amount
        s.coinsTotalEarned += amount
        if s.firstCreditedAt == nil { s.firstCreditedAt = Date() }
        switch source {
        case .claude: s.claudeCoinsEarned += amount
        case .cursor: s.cursorCoinsEarned += amount
        case .codex:  s.codexCoinsEarned += amount
        case .none:   break
        }
    }

    /// 소수부를 carry에 누적, 정수부만 즉시 적립.
    /// - Returns: 이번에 정수로 떨어진 적립 coin.
    @discardableResult
    private func creditWithCarry(amount: Double,
                                 fraction: ReferenceWritableKeyPath<Settings, Double>,
                                 source: CoinSource? = nil) -> Int {
        let s = Settings.shared
        var frac = s[keyPath: fraction]
        let whole = consumeFractionalCarry(amount: amount, into: &frac)
        s[keyPath: fraction] = frac
        if whole > 0 { credit(whole, source: source) }
        return whole
    }
}

/// 소수 누적 carry — 정수부를 반환하고 소수부는 fraction에 누적해 다음 호출에 합산한다.
/// 폴링마다 Int(...) 절단으로 소수 적립이 사라지는 것을 막는다. CoinLedger·VPLedger가 공유.
func consumeFractionalCarry(amount: Double, into fraction: inout Double) -> Int {
    let total = amount + fraction
    let whole = Int(total.rounded(.down))
    fraction = total - Double(whole)
    return whole
}
