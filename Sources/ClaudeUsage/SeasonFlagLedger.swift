import Foundation

/// 시즌 1회성 사실 기록 consumer — 지금은 "12월 25일에 AI를 썼다" 하나.
///
/// `CardTitle.codedOnChristmas`의 근거. `UsageEvent`가 KST 12/25에 들어오면 `seasonalFlags`에
/// `codedOn:<yyyy>-12-25`를 남긴다. 연도 키라 매년 다시 기록되지만 칭호는 하나다.
/// 날짜 경계는 잔디·서버 보상과 같은 KST(`UsageGrassModel.dayKey`).
@MainActor
final class SeasonFlagLedger: UsageConsumer {
    static let shared = SeasonFlagLedger()
    private init() {}

    func consume(_ event: UsageEvent) {
        let key = UsageGrassModel.dayKey(event.timestamp)   // yyyy-MM-dd
        guard key.hasSuffix("-12-25") else { return }
        let flag = "codedOn:\(key)"
        let s = Settings.shared
        guard !s.seasonalFlags.contains(flag) else { return }
        s.seasonalFlags.insert(flag)
        DebugLog.log("SeasonFlagLedger: \(flag)")
    }
}
