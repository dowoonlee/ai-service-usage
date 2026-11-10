import Foundation

/// 시즌 1회성 사실 기록 consumer — "12월 25일에 AI를 썼다", "1월 1일에 AI를 썼다".
///
/// `CardTitle.codedOnChristmas` / `.newYearFirstDay`의 근거. `UsageEvent`가 KST 그날에 들어오면
/// `seasonalFlags`에 `codedOn:<yyyy>-12-25` / `codedOn:<yyyy>-01-01`을 남긴다. 연도 키라 매년 다시
/// 기록되지만 칭호는 하나다.
/// 날짜 경계는 잔디·서버 보상과 같은 KST(`UsageGrassModel.dayKey`).
@MainActor
final class SeasonFlagLedger: UsageConsumer {
    static let shared = SeasonFlagLedger()
    private init() {}

    /// 기록 대상 날짜(`-MM-dd` 접미). 칭호 해금 판정(`CardTitle.unlocked`)이 같은 접미를 본다.
    nonisolated static let recordedDays = ["-12-25", "-01-01"]

    func consume(_ event: UsageEvent) {
        let key = UsageGrassModel.dayKey(event.timestamp)   // yyyy-MM-dd
        guard Self.recordedDays.contains(where: { key.hasSuffix($0) }) else { return }
        let flag = "codedOn:\(key)"
        let s = Settings.shared
        guard !s.seasonalFlags.contains(flag) else { return }
        s.seasonalFlags.insert(flag)
        DebugLog.log("SeasonFlagLedger: \(flag)")
    }
}
