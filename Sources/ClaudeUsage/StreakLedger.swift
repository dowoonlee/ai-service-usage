import Foundation

/// 사용량 스트릭 원장. UsageEvent를 받아 "실제 usage가 발생한 연속 일수"를 세고, 그날 첫
/// 이벤트에 딱 한 번 코인 보너스를 지급한다.
///
/// Heartbeat(폴링 생존 streak, `ViewModel.updateGymCountersOnCycleStart`)와의 차이:
///   * Heartbeat 는 앱이 살아서 폴링만 하면 오른다 → "사용" 여부와 무관.
///   * StreakLedger 는 pureValue > 0 인 UsageEvent 가 와야만 오른다 → 실제 AI 사용 필요 =
///     조작 불가. 사용량이 아주 적어 코인 carry 만 쌓이고 정수 적립이 0인 날도 "사용함"으로 인정.
///
/// CoinLedger / VPLedger 와 나란히 UsageConsumer 로 등록된다 (ViewModel.init). 한 폴링 cycle 에
/// 여러 소스 이벤트(claude 5h/7d, cursor, codex …)가 broadcast 되어도 `usageStreakLastDay` 로
/// 그날 첫 1회만 발동하도록 자연 dedup 된다.
///
/// 날짜 판정은 `Calendar.current`(사용자 로컬) 기준 — Heartbeat 와 동일. "사용자에게 자연스러운
/// 오늘"은 로컬 타임존이 맞고, 서버 고정 KST 를 쓰는 퀴즈(daily-quiz)와는 판정 주체가 다르다.
@MainActor
final class StreakLedger: UsageConsumer {
    static let shared = StreakLedger()
    private init() {}

    // MARK: - 보상 곡선

    /// 매일 기본 보상의 상한. 초반엔 낮게 시작해 8일차에 이 값으로 수렴.
    /// `reward`가 nonisolated라 상수도 nonisolated (CoinLedger/VPLedger 경제 상수와 동일 패턴).
    nonisolated static let dailyCap: Int = 50
    /// 스트릭 마일스톤 → 1회성 추가 보너스. 장기 유지 인센티브.
    nonisolated static let milestones: [Int: Int] = [7: 100, 30: 500, 100: 2000]

    /// 스트릭 일수 → 그날 지급할 코인.
    /// daily = min(dailyCap, 10 + streak×5)  → day1=15 … day8+ 50 고정 (passive 수급이라 상한).
    /// milestone = 해당 일수에 도달한 날만 가산. 퀴즈(하이리스크)와 달리 이쪽은 자동 수급이라 소액 유지.
    nonisolated static func reward(forStreak streak: Int) -> Int {
        guard streak > 0 else { return 0 }
        let daily = min(dailyCap, 10 + streak * 5)
        return daily + (milestones[streak] ?? 0)
    }

    // MARK: - UsageConsumer

    func consume(_ event: UsageEvent) {
        // pureValue 는 Producer 계약상 항상 양수 → consume 호출 자체가 "실제 사용" 신호.
        let s = Settings.shared
        let cal = Calendar.current
        let now = Date()

        if let last = s.usageStreakLastDay {
            if cal.isDate(last, inSameDayAs: now) { return }   // 오늘 이미 판정됨 — 재발동 방지
            if let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)),
               cal.isDate(last, inSameDayAs: yesterday) {
                s.usageStreak += 1                              // 연속 — 스트릭 증가
            } else {
                s.usageStreak = 1                               // 하루 이상 공백 — 리셋
            }
        } else {
            s.usageStreak = 1                                   // 최초 사용
        }
        s.usageStreakLastDay = now

        let reward = Self.reward(forStreak: s.usageStreak)
        // 스트릭은 "행동 보너스"이므로 사용량 카운터(②)·VP(③)에는 영향 없음 — creditBonus 경유.
        CoinLedger.shared.creditBonus(reward, reason: "streak.\(s.usageStreak)d")
        DebugLog.log("StreakLedger: 사용량 스트릭 \(s.usageStreak)일 → +\(reward) coin")
    }
}
