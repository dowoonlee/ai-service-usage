import Foundation

// ============================================================================
// Codex 7d 스케일 교정 소급
// ============================================================================
//
// OpenAI가 2026-07 중 Plus/Pro 응답에서 5h 창을 빼면서, 7d 하나만 남은 계정은 월 적립이
// 정책 목표의 5.6%로 떨어졌다 (배경: `CoinLedger.codexSevenDayOnlyMaxCoin`). 스케일을 고치면
// 그 시점부터는 맞지만 이미 과소 적립된 몫은 돌아오지 않으므로, 로컬 스냅샷을 다시 훑어
// **이번 달치**를 계산해 돌려준다.
//
// 소급 시작을 2026-09-01로 자르는 건 정책 결정이다. 5h 창이 사라진 7월까지 거슬러 올라가면
// 금액이 커지는 것도 문제지만, 그보다 오래된 구간은 스냅샷 compaction(8MB 초과 시 뒤쪽 4MB만
// 유지)으로 기기마다 남아 있는 범위가 달라 "누구는 받고 누구는 못 받는" 결과가 된다.

@MainActor
enum CodexBackfill {
    struct Amounts: Equatable {
        var vp: Int
        var coins: Int
        static let zero = Amounts(vp: 0, coins: 0)
        var isEmpty: Bool { vp <= 0 && coins <= 0 }
    }

    /// 한 폴 사이클에 흘려보내는 상한.
    ///
    /// 한 번에 다 주면 안 되는 이유는 서버 캡이다 — `_shared/caps.ts`는 제출 delta를
    /// `elapsed × 0.05/sec`(floor 5,000)로 자르고, **절삭을 클라에 알리지 않는다**. 넘긴 만큼은
    /// 조용히 사라진다. 실측 소급액이 5,052 VP였으니 정확히 그 함정에 걸리는 크기다.
    /// 1,000이면 정상 적립이 겹쳐도 floor에 한참 못 미치고, 5분 주기로 한 시간이면 다 나간다.
    static let drainPerCycle = 1_000

    /// 스냅샷 스캔 상한. 10분 폴이면 한 달치가 ~4,300건이라 여유를 둔 값.
    private static let snapshotScanLimit = 6_000

    /// 소급 구간의 시작 — 2026-09-01 00:00 로컬. **실행 시점의 "이번 달"이 아니라 고정 날짜다.**
    /// 마이그레이션이 도는 시점은 사용자가 업데이트를 받는 때라 사람마다 다르다. `Date()` 기준으로
    /// 달을 잡으면 10월에 업데이트한 사람은 9월 과소 적립분을 영영 못 받는다.
    ///
    /// 끝은 자르지 않는다 — 교정 전 버전을 계속 쓰는 동안에도 과소 적립은 이어지므로, 업데이트가
    /// 늦은 사람은 9/1부터 그 업데이트 시점까지 전 구간이 소급 대상이 되는 게 맞다.
    private static let backfillWindowStart = DateComponents(
        calendar: .current, timeZone: .current, year: 2026, month: 9, day: 1).date

    /// 소급 구간(2026-09-01~)의 미지급분.
    static func computeOwed(snapshots: [CodexSnapshot]? = nil) -> Amounts {
        guard let since = backfillWindowStart else { return .zero }
        let rows = snapshots ?? SnapshotStore.codex.loadRecent(limit: snapshotScanLimit)
        return compute(snapshots: rows, since: since)
    }

    /// `UsageEventProducer.ingestWindow`와 **같은 상태 머신**을 스냅샷 위에 다시 돌려, 그때 적립된
    /// pure와 새 스케일의 pure 차이를 누적한다. 창 판정(60s slack)과 baseline 후퇴 금지를 그대로
    /// 재현해야 실제 적립분과 어긋나지 않는다 — 창별 min→max로 뭉뚱그리면 창 경계가 흔들린 구간
    /// (실제로 7d resetAt은 폴마다 수십 초씩 밀린다)에서 값이 달라진다.
    ///
    /// `since` 이전 스냅샷도 상태 머신에는 먹인다. baseline을 이어받지 않으면 이번 달 첫 스냅샷의
    /// 상승분이 통째로 새 적립처럼 잡힌다.
    static func compute(snapshots: [CodexSnapshot], since: Date) -> Amounts {
        var lastReset: Date?
        var lastPct: Double?
        var vp = 0.0
        var coins = 0.0

        for snap in snapshots.sorted(by: { $0.takenAt < $1.takenAt }) {
            guard let resetAt = snap.sevenDayResetAt, let pct = snap.sevenDayPct else { continue }
            let sameWindow = lastReset.map { abs($0.timeIntervalSince(resetAt)) <= 60 } ?? false

            if sameWindow, let last = lastPct, pct > last, snap.takenAt >= since {
                // 그때 쓰인 만점(60)과 지금 쓸 만점의 차 — 5h가 함께 온 스냅샷이면 0이라 자동 제외된다.
                let missingMax = UsageEventProducer.codexSevenDayScale(snap) - CoinLedger.codexSevenDayMaxCoin
                if missingMax > 0 {
                    let ratio = CoinLedger.curve(pct / 100.0) - CoinLedger.curve(last / 100.0)
                    let missingPure = ratio * missingMax
                    vp += missingPure * Double(CoinLedger.codexPlanPriceVP(snap.planName))
                        / CoinLedger.claudeMaxPureCoinPerMonth
                    coins += missingPure * CoinLedger.codexPlanMultiplier(snap.planName)
                }
            }

            if sameWindow, let last = lastPct {
                lastPct = max(last, pct)
            } else {
                lastPct = pct
            }
            lastReset = resetAt
        }
        return Amounts(vp: Int(vp.rounded()), coins: Int(coins.rounded()))
    }

    /// 대기열에서 이번 사이클 몫을 꺼내 실제 원장에 넣는다. 남은 잔액이 없으면 아무것도 하지 않는다.
    /// `limit`이 nil이면 `drainPerCycle`. 기본 인자로 두지 않는 건 그 프로퍼티가 MainActor 격리라
    /// 기본값 표현식이 nonisolated 컨텍스트에서 평가돼 Swift 6에서 에러가 되기 때문.
    @discardableResult
    static func drain(limit: Int? = nil) -> Amounts {
        let cap = limit ?? drainPerCycle
        let s = Settings.shared
        let vp = min(max(0, s.pendingCodexBackfillVP), cap)
        let coins = min(max(0, s.pendingCodexBackfillCoins), cap)
        guard vp > 0 || coins > 0 else { return .zero }

        if vp > 0 {
            s.pendingCodexBackfillVP -= vp
            VPLedger.shared.creditBackfill(vp, reason: "codex-7d-scale")
        }
        if coins > 0 {
            s.pendingCodexBackfillCoins -= coins
            CoinLedger.shared.creditCodexBackfill(coins)
        }
        DebugLog.log("CodexBackfill: 지급 VP +\(vp) / coin +\(coins) (잔여 VP \(s.pendingCodexBackfillVP), coin \(s.pendingCodexBackfillCoins))")
        return Amounts(vp: vp, coins: coins)
    }
}
