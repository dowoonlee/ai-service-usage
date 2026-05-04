import Foundation

/// 사용량 기반으로 가챠 코인을 적립하는 ledger. 모든 적립은 **사용량 비례**.
///
/// Source:
///   - **Claude 5h / 7d**: 같은 윈도우 안에서의 사용률(`fiveHourPct`/`sevenDayPct`)
///     변화량(delta) × 환율. resetAt이 변경되면 baseline만 갱신.
///   - **Cursor**: 신규 `CursorEvent`의 `chargedCents` × 환율 (Ultra만).
///   - **Wellness**: 펫 nudge 1분 이내 클릭 시 정액 (`creditWellness(amount:)`).
///
/// **소수부 carry**: 폴링마다 발생하는 `Int(...)` 절단 손실을 막기 위해 source별
/// `*CoinFraction`에 잔여 소수부를 누적, 다음 폴링에 합산. 5h 100% 채울 시 정확히 50 coin
/// (이전엔 Δ ≈ 1.67%/poll → `Int(0.835)=0`이 60번 누적되어 0이 됐음).
@MainActor
final class CoinLedger {
    static let shared = CoinLedger()
    private init() {}

    /// 1 cent = 1 coin.
    static let cursorCentToCoin: Double         = 1.0
    /// Claude 5h 윈도우를 한 번 100% 채웠을 때 받는 코인 (Pro 기준, plan multiplier 적용 전).
    static let claudeFiveHourMaxCoin: Double    = 50
    /// Claude 7d 윈도우 100% 채웠을 때 받는 코인 (Pro 기준).
    static let claudeSevenDayMaxCoin: Double    = 100

    /// 누적 % 위치 → 누적 코인 비율. 양 끝(0%, 100%)은 고정, 중간 구간은 concave.
    /// shape(0)=0, shape(1)=1, 0<x<1에서 shape(x) > x → 초반 적립률↑/후반 적립률↓.
    /// sqrt 사용 — log 대비 단순하고 0 근처 너무 가파르지 않음. "log scale 굳이 아니어도 OK"라는 결정.
    nonisolated static func curve(_ x: Double) -> Double {
        let clamped = max(0, min(1, x))
        return clamped.squareRoot()
    }

    /// Claude plan별 코인 multiplier. plan 라벨의 5x/20x를 그대로 곱하면 Pro 사용자와 격차가
    /// 너무 커서 의욕 저하 — 보수적으로 절반(또는 1/5) 정도 가중. Free=0.5 / Pro=1 / Max 5x=2 /
    /// Max 20x=4 / Enterprise=1.5. planName이 nil이거나 매칭 실패 시 1.0 (안전한 기본).
    nonisolated static func planMultiplier(_ planName: String?) -> Double {
        guard let name = planName?.lowercased() else { return 1.0 }
        if name.contains("max 20")   { return 4.0 }
        if name.contains("max 5") || name.contains("max") { return 2.0 }
        if name.contains("enterprise") { return 1.5 }
        if name.contains("pro") || name.contains("team") { return 1.0 }
        if name.contains("free") { return 0.5 }
        return 1.0
    }

    /// 적립 시 호출해서 coins + totalEarned + firstCreditedAt 갱신.
    /// `source`는 Vibe 도장(Claude/Cursor) 카운터 누적용 — wellness/contributor/badge bonus는 nil.
    private func credit(_ amount: Int, source: CoinSource? = nil) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.coins += amount
        s.coinsTotalEarned += amount
        if s.firstCreditedAt == nil { s.firstCreditedAt = Date() }
        switch source {
        case .claude: s.claudeCoinsEarned += amount
        case .cursor: s.cursorCoinsEarned += amount
        case .none:   break
        }
    }

    /// 소수부를 carry에 누적, 정수부만 즉시 적립.
    /// - Returns: 이번에 정수로 떨어진 적립 코인 (로깅 용).
    private func creditWithCarry(amount: Double,
                                 fraction: ReferenceWritableKeyPath<Settings, Double>,
                                 source: CoinSource? = nil) -> Int {
        let s = Settings.shared
        let total = amount + s[keyPath: fraction]
        let whole = Int(total.rounded(.down))
        s[keyPath: fraction] = total - Double(whole)
        if whole > 0 { credit(whole, source: source) }
        return whole
    }

    private enum CoinSource { case claude, cursor }

    /// Wellness nudge 보상 진입점. credit 정책 (totalEarned, firstCreditedAt)을 통일.
    func creditWellness(amount: Int) {
        credit(amount)
        DebugLog.log("CoinLedger: Wellness +\(amount) coin (total=\(Settings.shared.coins))")
    }

    /// 외부 기여자 PR 머지 보너스. PR 1개 = 50 coin (정액).
    /// dedupe는 호출 측(`ContributorBonus`)에서 `Settings.creditedPRNumbers`로 처리.
    static let coinPerContributorPR: Int = 50
    func creditContributorBonus(prCount: Int) {
        guard prCount > 0 else { return }
        let amount = prCount * Self.coinPerContributorPR
        credit(amount)
        DebugLog.log("CoinLedger: Contributor +\(amount) coin (\(prCount) PR) (total=\(Settings.shared.coins))")
    }

    /// Claude snapshot에서 사용량 delta로 적립.
    /// - 같은 `resetAt` 안에서는 누적 % 위치에 대한 곡선값 delta × max coin × planMultiplier.
    ///   linear가 아닌 concave(sqrt) 곡선 — 초반 적립률↑/후반 적립률↓, 양 끝(0%, 100%)은 고정.
    /// - `resetAt`이 변경되면 새 윈도우 시작 → baseline만 갱신.
    /// - 첫 폴링은 baseline만 기록 (소급 적립 방지).
    func evaluateClaude(snapshot: UsageSnapshot) {
        let s = Settings.shared
        let multiplier = Self.planMultiplier(snapshot.planName)
        // 5-hour 윈도우
        if let resetAt = snapshot.fiveHourResetAt, let pct = snapshot.fiveHourPct {
            if let lastReset = s.lastClaudeFiveHourReset,
               let lastPct = s.lastClaudeFiveHourPctSeen,
               resetAt == lastReset, pct > lastPct {
                let prev = Self.curve(lastPct / 100.0) * Self.claudeFiveHourMaxCoin
                let curr = Self.curve(pct / 100.0) * Self.claudeFiveHourMaxCoin
                let raw = (curr - prev) * multiplier
                if raw > 0 {
                    let earned = creditWithCarry(amount: raw, fraction: \.claudeFiveHourCoinFraction, source: .claude)
                    if earned > 0 {
                        DebugLog.log("CoinLedger: Claude 5h \(String(format: "%.1f→%.1f", lastPct, pct))% (×\(multiplier)) → +\(earned) coin (total=\(s.coins))")
                    }
                }
            }
            s.lastClaudeFiveHourReset = resetAt
            s.lastClaudeFiveHourPctSeen = pct
        }
        // 7-day 윈도우
        if let resetAt = snapshot.sevenDayResetAt, let pct = snapshot.sevenDayPct {
            if let lastReset = s.lastClaudeSevenDayReset,
               let lastPct = s.lastClaudeSevenDayPctSeen,
               resetAt == lastReset, pct > lastPct {
                let prev = Self.curve(lastPct / 100.0) * Self.claudeSevenDayMaxCoin
                let curr = Self.curve(pct / 100.0) * Self.claudeSevenDayMaxCoin
                let raw = (curr - prev) * multiplier
                if raw > 0 {
                    let earned = creditWithCarry(amount: raw, fraction: \.claudeSevenDayCoinFraction, source: .claude)
                    if earned > 0 {
                        DebugLog.log("CoinLedger: Claude 7d \(String(format: "%.1f→%.1f", lastPct, pct))% (×\(multiplier)) → +\(earned) coin (total=\(s.coins))")
                    }
                }
            }
            s.lastClaudeSevenDayReset = resetAt
            s.lastClaudeSevenDayPctSeen = pct
        }
        BadgeRegistry.evaluate()
    }

    /// Cursor 신규 이벤트 기반 적립. `lastCursorEventCredited` 이후의 chargedCents 합산 → 소수부 carry.
    func evaluateCursor(newEvents: [CursorEvent]) {
        guard !newEvents.isEmpty else { return }
        let s = Settings.shared
        let cutoff = s.lastCursorEventCredited ?? .distantPast
        let unprocessed = newEvents.filter { $0.timestamp > cutoff }
        guard !unprocessed.isEmpty else { return }
        let cents = unprocessed.reduce(0.0) { $0 + $1.chargedCents }
        let raw = cents * Self.cursorCentToCoin
        let earned = creditWithCarry(amount: raw, fraction: \.cursorCoinFraction, source: .cursor)
        if earned > 0 {
            DebugLog.log("CoinLedger: Cursor +\(earned) coin (\(unprocessed.count) events, \(cents) cents) (total=\(s.coins))")
        }
        if let latest = unprocessed.map({ $0.timestamp }).max() {
            s.lastCursorEventCredited = latest
        }
        BadgeRegistry.evaluate()
    }
}
