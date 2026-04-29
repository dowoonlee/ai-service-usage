import Foundation

/// 사용량 기반으로 가챠 코인을 적립하는 ledger. 모든 적립은 **사용량 비례**.
///
/// Source:
///   - **Claude 5h / 7d**: 같은 윈도우 안에서의 사용률(`fiveHourPct`/`sevenDayPct`)
///     변화량(delta) × 환율. resetAt이 변경되면 baseline만 갱신하고 적립은 0.
///   - **Cursor**: 신규 `CursorEvent`의 `chargedCents` × 환율 (Ultra만 — Pro는 이벤트 미발생).
///   - **Wellness**: 펫 nudge 1분 이내 클릭 시 정액 (`ViewModel.dismissWellnessNudge`).
@MainActor
final class CoinLedger {
    static let shared = CoinLedger()
    private init() {}

    /// 1 cent = 1 coin.
    static let cursorCentToCoin: Double         = 1.0
    /// Claude 5h 윈도우 사용률 1% = N coin (한 윈도우 100% 채울 시 50 coin).
    static let claudeFiveHourPctToCoin: Double  = 0.5
    /// Claude 7d 윈도우 사용률 1% = N coin (한 주 100% 채울 시 100 coin).
    static let claudeSevenDayPctToCoin: Double  = 1.0

    /// 적립 시 호출해서 coins + totalEarned + firstCreditedAt 갱신.
    private func credit(_ amount: Int) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.coins += amount
        s.coinsTotalEarned += amount
        if s.firstCreditedAt == nil { s.firstCreditedAt = Date() }
    }

    /// Claude snapshot에서 사용량 delta로 적립.
    /// - 같은 `resetAt` 안에서는 직전 본 pct 대비 delta(>0) × 환율.
    /// - `resetAt`이 변경되면 새 윈도우 시작 → baseline만 갱신.
    /// - 첫 폴링은 baseline만 기록 (소급 적립 방지).
    func evaluateClaude(snapshot: UsageSnapshot) {
        let s = Settings.shared
        // 5-hour 윈도우
        if let resetAt = snapshot.fiveHourResetAt, let pct = snapshot.fiveHourPct {
            if let lastReset = s.lastClaudeFiveHourReset,
               let lastPct = s.lastClaudeFiveHourPctSeen,
               resetAt == lastReset {
                let delta = pct - lastPct
                let earned = Int(delta * Self.claudeFiveHourPctToCoin)
                if earned > 0 {
                    credit(earned)
                    DebugLog.log("CoinLedger: Claude 5h Δ\(String(format: "%.1f", delta))% → +\(earned) coin (total=\(s.coins))")
                }
            }
            s.lastClaudeFiveHourReset = resetAt
            s.lastClaudeFiveHourPctSeen = pct
        }
        // 7-day 윈도우
        if let resetAt = snapshot.sevenDayResetAt, let pct = snapshot.sevenDayPct {
            if let lastReset = s.lastClaudeSevenDayReset,
               let lastPct = s.lastClaudeSevenDayPctSeen,
               resetAt == lastReset {
                let delta = pct - lastPct
                let earned = Int(delta * Self.claudeSevenDayPctToCoin)
                if earned > 0 {
                    credit(earned)
                    DebugLog.log("CoinLedger: Claude 7d Δ\(String(format: "%.1f", delta))% → +\(earned) coin (total=\(s.coins))")
                }
            }
            s.lastClaudeSevenDayReset = resetAt
            s.lastClaudeSevenDayPctSeen = pct
        }
    }

    /// Cursor 신규 이벤트 기반 적립.
    /// `lastCursorEventCredited` 이후의 이벤트만 chargedCents 합산 → coin.
    func evaluateCursor(newEvents: [CursorEvent]) {
        guard !newEvents.isEmpty else { return }
        let s = Settings.shared
        let cutoff = s.lastCursorEventCredited ?? .distantPast
        let unprocessed = newEvents.filter { $0.timestamp > cutoff }
        guard !unprocessed.isEmpty else { return }
        let cents = unprocessed.reduce(0.0) { $0 + $1.chargedCents }
        let earned = Int(cents * Self.cursorCentToCoin)
        if earned > 0 {
            credit(earned)
            DebugLog.log("CoinLedger: Cursor +\(earned) coin (\(unprocessed.count) events, \(cents) cents) (total=\(s.coins))")
        }
        if let latest = unprocessed.map({ $0.timestamp }).max() {
            s.lastCursorEventCredited = latest
        }
    }
}
