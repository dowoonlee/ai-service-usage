import Foundation

/// 사용량 기반으로 가챠 코인을 적립하는 ledger.
///
/// 두 source:
///   - **Claude**: 5h/7d 윈도우가 새로 리셋될 때마다 정액 지급
///     (재지급 방지: `Settings.lastClaudeFiveHourReset`/`lastClaudeSevenDayReset` 비교)
///   - **Cursor**: 신규 `CursorEvent`의 `chargedCents` × 환율 (Ultra만; Pro는 이벤트 fetch 안 함)
///
/// 환율은 M3.3에서 사용자별 평균 적립 페이스 기준으로 자동 캘리브레이션 예정.
/// 현재 값은 시드(static).
@MainActor
final class CoinLedger {
    static let shared = CoinLedger()
    private init() {}

    static let cursorCentToCoin: Double      = 1.0   // 1 cent = 1 coin
    static let claudeFiveHourResetCoin: Int  = 30    // 5h 윈도우 리셋 1회 = 30 coin
    static let claudeSevenDayResetCoin: Int  = 200   // 7d 윈도우 리셋 1회 = 200 coin

    /// 적립 시 호출해서 coins 증가 + totalEarned/firstCreditedAt 추적.
    /// 이 두 값은 Gacha.pullCost(동적 환율)의 분자/분모로 쓰인다.
    private func credit(_ amount: Int) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.coins += amount
        s.coinsTotalEarned += amount
        if s.firstCreditedAt == nil { s.firstCreditedAt = Date() }
    }

    /// Claude snapshot 기반 적립.
    /// `fiveHourResetAt`이 마지막 적립 시각보다 새 값이면 정액 지급.
    /// 첫 폴링은 baseline만 기록하고 적립 안 함 (앱 설치 직전 발생한 리셋을 소급 지급하지 않기 위해).
    func evaluateClaude(snapshot: UsageSnapshot) {
        let s = Settings.shared
        if let resetAt = snapshot.fiveHourResetAt {
            if let last = s.lastClaudeFiveHourReset {
                if resetAt > last {
                    credit(Self.claudeFiveHourResetCoin)
                    s.lastClaudeFiveHourReset = resetAt
                    DebugLog.log("CoinLedger: Claude 5h reset → +\(Self.claudeFiveHourResetCoin) coin (total=\(s.coins))")
                }
            } else {
                s.lastClaudeFiveHourReset = resetAt
            }
        }
        if let resetAt = snapshot.sevenDayResetAt {
            if let last = s.lastClaudeSevenDayReset {
                if resetAt > last {
                    credit(Self.claudeSevenDayResetCoin)
                    s.lastClaudeSevenDayReset = resetAt
                    DebugLog.log("CoinLedger: Claude 7d reset → +\(Self.claudeSevenDayResetCoin) coin (total=\(s.coins))")
                }
            } else {
                s.lastClaudeSevenDayReset = resetAt
            }
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
