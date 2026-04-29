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

    /// 소수부를 carry에 누적, 정수부만 즉시 적립.
    /// - Returns: 이번에 정수로 떨어진 적립 코인 (로깅 용).
    private func creditWithCarry(amount: Double, fraction: ReferenceWritableKeyPath<Settings, Double>) -> Int {
        let s = Settings.shared
        let total = amount + s[keyPath: fraction]
        let whole = Int(total.rounded(.down))
        s[keyPath: fraction] = total - Double(whole)
        if whole > 0 { credit(whole) }
        return whole
    }

    /// Wellness nudge 보상 진입점. credit 정책 (totalEarned, firstCreditedAt)을 통일.
    func creditWellness(amount: Int) {
        credit(amount)
        DebugLog.log("CoinLedger: Wellness +\(amount) coin (total=\(Settings.shared.coins))")
    }

    /// Claude snapshot에서 사용량 delta로 적립.
    /// - 같은 `resetAt` 안에서는 직전 본 pct 대비 delta(>0) × 환율 (소수부 carry).
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
                if delta > 0 {
                    let raw = delta * Self.claudeFiveHourPctToCoin
                    let earned = creditWithCarry(amount: raw, fraction: \.claudeFiveHourCoinFraction)
                    if earned > 0 {
                        DebugLog.log("CoinLedger: Claude 5h Δ\(String(format: "%.1f", delta))% → +\(earned) coin (total=\(s.coins))")
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
               resetAt == lastReset {
                let delta = pct - lastPct
                if delta > 0 {
                    let raw = delta * Self.claudeSevenDayPctToCoin
                    let earned = creditWithCarry(amount: raw, fraction: \.claudeSevenDayCoinFraction)
                    if earned > 0 {
                        DebugLog.log("CoinLedger: Claude 7d Δ\(String(format: "%.1f", delta))% → +\(earned) coin (total=\(s.coins))")
                    }
                }
            }
            s.lastClaudeSevenDayReset = resetAt
            s.lastClaudeSevenDayPctSeen = pct
        }
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
        let earned = creditWithCarry(amount: raw, fraction: \.cursorCoinFraction)
        if earned > 0 {
            DebugLog.log("CoinLedger: Cursor +\(earned) coin (\(unprocessed.count) events, \(cents) cents) (total=\(s.coins))")
        }
        if let latest = unprocessed.map({ $0.timestamp }).max() {
            s.lastCursorEventCredited = latest
        }
    }
}
