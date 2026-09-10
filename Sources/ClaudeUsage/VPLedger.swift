import Foundation

/// 랭킹 VP 적립 ledger. UsageEvent를 받아 `Settings.rankingScoreEarnedVP`만 갱신.
/// 코인 경제와 완전 독립 — 새 사용량 소스 추가해도 본 클래스 수정 불필요.
///
/// 적립 공식:
///   vpAmount = event.pureValue × event.context.vpFactor
///   (소수부는 fraction에 누적해 다음 event에 합산 — 절단 손실 방지)
@MainActor
final class VPLedger: UsageConsumer {
    static let shared = VPLedger()
    private init() {}

    func consume(_ event: UsageEvent) {
        let s = Settings.shared
        let raw = event.pureValue * event.context.vpFactor
        guard raw > 0 else { return }

        var frac = s.rankingScoreFractionVP
        let whole = consumeFractionalCarry(amount: raw, into: &frac)
        s.rankingScoreFractionVP = frac
        if whole > 0 {
            s.rankingScoreEarnedVP += whole
            DebugLog.log("VPLedger: +\(whole) VP (source=\(event.source.rawValue), total=\(s.rankingScoreEarnedVP))")
        }
    }

    /// 환산식 오류로 과소 적립됐던 몫의 소급 지급. `consume`과 달리 이벤트가 아니라 이미 계산된
    /// 정수를 받는다 — 소급은 지난 사용량의 재계산이라 되살릴 원본 이벤트가 없다.
    /// VP는 사용량 비례 값이므로 보너스(coin 전용 `creditBonus`)로 우회하지 않고 여기로 들어온다.
    func creditBackfill(_ amount: Int, reason: String) {
        guard amount > 0 else { return }
        let s = Settings.shared
        s.rankingScoreEarnedVP += amount
        DebugLog.log("VPLedger: backfill +\(amount) VP (\(reason), total=\(s.rankingScoreEarnedVP))")
    }
}
