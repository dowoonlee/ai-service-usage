import Foundation

/// 일별 VP 누적 consumer — 리포트 탭 사용량 잔디(`UsageGrassView`)의 데이터.
///
/// `StreakLedger`는 "오늘 썼나"만 기록하고 `VPLedger`는 총합만 올리므로, 하루 단위 농도를 그릴 값이
/// 없었다. 이 consumer는 같은 `UsageEvent`에서 VP 환산값을 KST 날짜별로 더한다. 코인·VP·스트릭과
/// 같은 독립 consumer 패턴 — 기존 ledger는 건드리지 않는다.
///
/// 날짜 경계는 **KST**(`SajuEngine.kstDayFormatter`). 서버 일일 보상(`reward_grants`)과 퀴즈가 KST로
/// 끊기므로 로컬 자정을 쓰면 밤 11시대 사용분이 서버와 다른 칸에 들어간다.
@MainActor
final class DailyUsageLedger: UsageConsumer {
    static let shared = DailyUsageLedger()
    private init() {}

    /// 보관 일수. 농도 사분위는 최근 30일 최대값 기준이라 그 이상은 표시에 쓰이지 않는다.
    nonisolated static let retentionDays = 90

    func consume(_ event: UsageEvent) {
        let raw = event.pureValue * event.context.vpFactor
        guard raw > 0 else { return }
        let s = Settings.shared
        var map = s.dailyVP
        let key = UsageGrassModel.dayKey(event.timestamp)
        map[key, default: 0] += raw
        Self.prune(&map, now: event.timestamp)
        s.dailyVP = map
    }

    /// `now` 기준 `retentionDays`보다 오래된 키 제거. 키가 `yyyy-MM-dd`라 문자열 비교가 날짜 비교다.
    nonisolated static func prune(_ map: inout [String: Double], now: Date) {
        guard let cutoffDate = Calendar.kst.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        let cutoff = UsageGrassModel.dayKey(cutoffDate)
        map = map.filter { $0.key >= cutoff }
    }
}

extension Calendar {
    /// KST, 월요일 시작 — 잔디 격자·일별 키가 서버 날짜 경계와 같게.
    nonisolated static let kst: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = SajuEngine.kst
        c.firstWeekday = 2
        return c
    }()
}
