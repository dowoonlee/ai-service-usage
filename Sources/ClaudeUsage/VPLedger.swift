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

        let total = raw + s.rankingScoreFractionVP
        let whole = Int(total.rounded(.down))
        s.rankingScoreFractionVP = total - Double(whole)
        if whole > 0 {
            s.rankingScoreEarnedVP += whole
            DebugLog.log("VPLedger: +\(whole) VP (source=\(event.source.rawValue), total=\(s.rankingScoreEarnedVP))")
        }
    }
}
