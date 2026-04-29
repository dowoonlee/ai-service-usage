import Foundation
import Combine

/// `dismissWellnessNudge`의 결과. 호출 측 (WalkingCat)에서 코인 popping
/// 애니메이션을 띄울지 결정하는 데 사용.
enum WellnessDismissResult {
    case rewarded(Int)   // 보상 받은 코인 수
    case noReward
}

@MainActor
final class ViewModel: ObservableObject {
    // Claude
    @Published var claudeCurrent: UsageSnapshot?
    @Published var claudeHistory: [UsageSnapshot] = []
    @Published var claudeLoading: Bool = false
    @Published var claudeError: String?
    @Published var claudeLastSuccess: Date?
    @Published var claudeNeedsLogin: Bool = false

    // Cursor
    @Published var cursorCurrent: CursorSnapshot?
    @Published var cursorHistory: [CursorSnapshot] = []
    @Published var cursorEvents: [CursorEvent] = []          // 현재 billing 기간 이벤트 (시간순)
    @Published var cursorLoading: Bool = false
    @Published var cursorError: String?
    @Published var cursorLastSuccess: Date?
    @Published var cursorNeedsSetup: Bool = false   // Cursor 앱 미설치/미로그인

    // Shared
    @Published var now: Date = Date()

    // 펫이 외치는 휴식 권유 말풍선. nil이면 표시 안 함.
    // 최근 1시간 동안 거의 쉬지 않고 사용 중이고, 마지막 표시로부터 1시간 이상 지났을 때 설정됨.
    @Published var wellnessNudge: String?
    private var lastWellnessShownAt: Date?

    // Section collapse
    @Published var claudeCollapsed: Bool {
        didSet { UserDefaults.standard.set(claudeCollapsed, forKey: "section.claude.collapsed") }
    }
    @Published var cursorCollapsed: Bool {
        didSet { UserDefaults.standard.set(cursorCollapsed, forKey: "section.cursor.collapsed") }
    }

    private var pollTask: Task<Void, Never>?
    private var clockTimer: Timer?

    /// 펫 사용 시간 누적용 마지막 tick 시각. 앱 첫 실행 직후 nil → 첫 tick은 무크레딧 (앱 종료 중 시간을 보정).
    /// 인메모리만 — 재실행 시 다시 nil로 시작.
    private var lastPetUsageTickAt: Date?

    /// 한 번의 polling tick에서 펫 사용 시간으로 인정할 최대 초 (sleep/suspend 보호).
    /// 폴링 주기 300s × 2 = 600s. 노트북 sleep 후 깨면 첫 tick은 600s 까지만 인정.
    private static let petUsageMaxCreditPerTick: TimeInterval = 600

    init() {
        let d = UserDefaults.standard
        self.claudeCollapsed = d.bool(forKey: "section.claude.collapsed")
        self.cursorCollapsed = d.bool(forKey: "section.cursor.collapsed")

        self.claudeHistory = SnapshotStore.claude.loadRecent()
        self.claudeCurrent = self.claudeHistory.last
        self.claudeLastSuccess = self.claudeCurrent?.takenAt
        // 시작 시 Keychain을 직접 읽지 않는다(프롬프트 유발). 첫 refresh가 needsLogin을 갱신함.
        self.claudeNeedsLogin = false

        self.cursorHistory = SnapshotStore.cursor.loadRecent()
        self.cursorCurrent = self.cursorHistory.last
        self.cursorLastSuccess = self.cursorCurrent?.takenAt

        self.cursorEvents = SnapshotStore.cursorEvents.loadRecent(limit: 20000)
            .sorted { $0.timestamp < $1.timestamp }

        startClock()
    }

    func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date()
                self.evaluateWellnessNudge()
            }
        }
    }

    // MARK: - Wellness nudge

    // 1시간 동안 거의 쉬지 않고 사용 중이면 휴식 권유 말풍선을 띄운다.
    // 5분 폴링 간격이라 1시간 = 12 스냅샷, 그 중 flat(델타 < 0.1%)이 2개 이하일 때 "계속 일하는 중"으로 본다.
    // 한 번 띄우면 1시간 쿨다운.
    static let wellnessIntervalSec: TimeInterval = 60 * 60
    /// nudge 표시 후 이 시간 내에 클릭하면 보상.
    static let wellnessRewardWindow: TimeInterval = 60
    /// 보상 코인 수.
    static let wellnessRewardCoins: Int = 30

    private func evaluateWellnessNudge() {
        guard wellnessNudge == nil else { return }
        let intervalSec = Self.wellnessIntervalSec
        if let last = lastWellnessShownAt, now.timeIntervalSince(last) < intervalSec { return }

        // 인터벌 동안 사용자가 활동(델타 > 0.1%)했어야 트리거. 안 쓰던 사람한테 휴식하라고 권할 필요 없음.
        let windowAgo = now.addingTimeInterval(-intervalSec)
        let recent = claudeHistory.filter { $0.takenAt >= windowAgo }
        // 폴링 5분 주기 → 인터벌 동안 최소 2 스냅샷은 있어야 델타 비교 가능
        guard recent.count >= 2 else {
            // 히스토리 부족 시: 첫 호출에서 lastWellnessShownAt만 세팅 → 다음 인터벌 후부터 정상 동작
            if lastWellnessShownAt == nil { lastWellnessShownAt = now }
            return
        }

        var hadActivity = false
        for i in 1..<recent.count {
            guard let curr = recent[i].fiveHourPct, let prev = recent[i - 1].fiveHourPct else { continue }
            if curr - prev > 0.1 { hadActivity = true; break }
        }
        guard hadActivity else { return }

        wellnessNudge = Quotes.randomWellness()
        lastWellnessShownAt = now
    }

    /// nudge 클릭 처리. 표시 후 `wellnessRewardWindow`(60s) 이내면 코인 보상.
    /// - Returns: 보상 여부와 금액. 호출 측이 popping 애니메이션 트리거에 사용.
    @discardableResult
    func dismissWellnessNudge() -> WellnessDismissResult {
        defer { wellnessNudge = nil }
        let elapsed = lastWellnessShownAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed < Self.wellnessRewardWindow else { return .noReward }
        let amount = Self.wellnessRewardCoins
        // credit 정책(totalEarned/firstCreditedAt 추적)을 한곳에서만 관리하기 위해 CoinLedger 경유.
        CoinLedger.shared.creditWellness(amount: amount)
        return .rewarded(amount)
    }

    /// 임박한 resetAt 직전(=`resetGuard`초 전)에 마지막 관측 폴링이 잡히도록 sleep을 단축.
    /// 윈도우 끝 사용분이 코인 적립에서 누락되는 걸 막기 위함 — 그 폴링의 pct가 윈도우 종료 pct로
    /// 기록되고, 다음(=normal interval) 폴링은 새 윈도우라서 자연스럽게 rebase된다.
    /// 30s buffer는 refresh의 네트워크 라운드트립(특히 Ultra cursor event 페이지네이션)이
    /// resetAt을 넘겨버려 새 윈도우 baseline을 받아오는 걸 막기 위한 안전 마진.
    static let resetGuard: TimeInterval = 30
    static let minSleep: TimeInterval = 5

    func startPolling(interval: TimeInterval = 300) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshClaude()
                await self.refreshCursor()
                self.accumulatePetUsage()
                let sleepSec = self.nextPollDelay(maxInterval: interval)
                try? await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
            }
        }
    }

    /// 폴링 tick마다 호출 — 현재 차트에 배치된 펫(`petClaudeKind`/`petCursorKind`)에 실시간 누적.
    /// 양쪽 차트가 같은 종이면 더블카운트 (한 tick에 2배 누적). pet enable 토글이 꺼진 차트는 누적 제외.
    /// 임계 초과 시 `PetOwnership.registerUsage`가 variant unlock을 트리거하고 그 결과를 로그.
    private func accumulatePetUsage() {
        let now = Date()
        defer { lastPetUsageTickAt = now }
        // 첫 tick: 크레딧 없이 기준 시각만 잡음 (앱이 막 켜진 시점부터 카운트 시작)
        guard let last = lastPetUsageTickAt else { return }

        // 실제 경과 시간 — sleep/suspend 후 폭주 방지를 위해 최대치 캡.
        let elapsed = max(0, now.timeIntervalSince(last))
        let credited = min(elapsed, Self.petUsageMaxCreditPerTick)
        guard credited > 0 else { return }

        let s = Settings.shared
        var usage = s.petUsageSeconds
        var owned = s.ownedPets

        @MainActor func creditOne(_ kind: PetKind) {
            usage[kind, default: 0] += credited
            guard var o = owned[kind] else { return }
            if let v = o.registerUsage(totalSeconds: usage[kind] ?? 0) {
                DebugLog.log("Pet usage unlock: \(kind.rawValue) variant \(v) @ \(Int((usage[kind] ?? 0) / 86400))d")
                // 도감 강조 — 사용자가 직접 슬롯 클릭해 확인하기 전까지 NEW 뱃지 유지.
                s.pendingHighlights.insert(kind)
            }
            owned[kind] = o
        }

        if s.petClaudeEnabled { creditOne(s.petClaudeKind) }
        if s.petCursorEnabled { creditOne(s.petCursorKind) }

        s.petUsageSeconds = usage
        s.ownedPets = owned
    }

    func nextPollDelay(maxInterval: TimeInterval) -> TimeInterval {
        Self.nextPollDelay(
            now: Date(),
            resets: [
                claudeCurrent?.fiveHourResetAt,
                claudeCurrent?.sevenDayResetAt,
                cursorCurrent?.resetAt,
            ],
            maxInterval: maxInterval,
            resetGuard: Self.resetGuard,
            minSleep: Self.minSleep
        )
    }

    // pure 함수 — instance 상태와 분리해서 시나리오 검증 가능.
    nonisolated static func nextPollDelay(
        now: Date,
        resets: [Date?],
        maxInterval: TimeInterval,
        resetGuard: TimeInterval,
        minSleep: TimeInterval
    ) -> TimeInterval {
        var nextDeadline = now.addingTimeInterval(maxInterval)
        for r in resets.compactMap({ $0 }) {
            let preReset = r.addingTimeInterval(-resetGuard)
            if preReset > now && preReset < nextDeadline {
                nextDeadline = preReset
            }
        }
        return max(minSleep, nextDeadline.timeIntervalSince(now))
    }

    // MARK: - Claude

    func refreshClaude() async {
        claudeLoading = true
        defer { claudeLoading = false }
        do {
            let snap = try await UsageAPI.shared.refresh()
            SnapshotStore.claude.append(snap)
            claudeCurrent = snap
            claudeHistory.append(snap)
            if claudeHistory.count > 1000 { claudeHistory.removeFirst(claudeHistory.count - 1000) }
            claudeError = nil
            claudeLastSuccess = snap.takenAt
            claudeNeedsLogin = false
            evaluateClaudeAlerts(snap)
            CoinLedger.shared.evaluateClaude(snapshot: snap)
        } catch UsageError.notLoggedIn {
            claudeNeedsLogin = true
            claudeError = "로그인 필요"
        } catch UsageError.unauthorized {
            claudeNeedsLogin = true
            claudeError = "세션 만료"
            Keychain.clear()
        } catch {
            claudeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func handleClaudeLoggedIn() {
        claudeNeedsLogin = false
        Task { await refreshClaude() }
    }

    func claudeLogout() {
        Keychain.clear()
        Task { await UsageAPI.shared.invalidateSession() }
        claudeCurrent = nil
        claudeNeedsLogin = true
        claudeError = "로그아웃됨"
    }

    // MARK: - Cursor

    func refreshCursor() async {
        cursorLoading = true
        defer { cursorLoading = false }
        do {
            let snap = try await CursorAPI.shared.refresh()
            SnapshotStore.cursor.append(snap)
            cursorCurrent = snap
            cursorHistory.append(snap)
            if cursorHistory.count > 1000 { cursorHistory.removeFirst(cursorHistory.count - 1000) }
            cursorError = nil
            cursorLastSuccess = snap.takenAt
            cursorNeedsSetup = false
            evaluateCursorAlerts(snap)

            // Ultra의 경우 이벤트 히스토리 증분 fetch (백그라운드)
            if snap.plan == .ultra {
                await fetchCursorEventsIncrement(periodStart: snap.resetAt.map { resetAt in
                    // resetAt은 startOfMonth + 1개월이므로 - 1개월로 periodStart 복원
                    Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: resetAt) ?? resetAt.addingTimeInterval(-30 * 86400)
                })
            }
        } catch CursorError.cursorNotInstalled, CursorError.notLoggedIn {
            cursorNeedsSetup = true
            cursorError = "Cursor 앱 로그인 필요"
        } catch CursorError.unauthorized {
            cursorNeedsSetup = true
            cursorError = "Cursor 세션 만료 (앱에서 재로그인)"
        } catch {
            cursorError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Pace prediction

    // 현재 페이스로 주기 끝까지 갔을 때 예상 사용률(%).
    // current: 현재 % (0~100), resetAt: 주기 끝, periodLength: 주기 전체 길이(초).
    // 경과시간이 너무 짧으면 노이즈 → nil.
    static func projectedPct(current: Double?, resetAt: Date?, periodLength: TimeInterval, now: Date) -> Double? {
        guard let current, let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSince(now)
        let elapsed = periodLength - remaining
        // 5h 창은 15분 미만, 그 외는 주기의 5% 미만이면 예측 보류
        let minElapsed = max(15 * 60, periodLength * 0.05)
        guard elapsed >= minElapsed, elapsed > 0 else { return nil }
        return current * (periodLength / elapsed)
    }

    // 페이스가 100%를 초과할 때, 한도 도달 예상 시각.
    static func projectedExhaustionDate(current: Double?, resetAt: Date?, periodLength: TimeInterval, now: Date) -> Date? {
        guard let current, current > 0.1, let resetAt else { return nil }
        let elapsed = periodLength - resetAt.timeIntervalSince(now)
        let minElapsed = max(15 * 60, periodLength * 0.05)
        guard elapsed >= minElapsed else { return nil }
        let rate = current / elapsed                  // %/sec
        let remainingPct = 100.0 - current
        guard rate > 0, remainingPct > 0 else { return nil }
        let secondsToFull = remainingPct / rate
        let exhaust = now.addingTimeInterval(secondsToFull)
        // 리셋 이후라면 도달 안 함
        return exhaust < resetAt ? exhaust : nil
    }

    var claude5hProjectedPct: Double? {
        ViewModel.projectedPct(
            current: claudeCurrent?.fiveHourPct,
            resetAt: claudeCurrent?.fiveHourResetAt,
            periodLength: 5 * 3600, now: now
        )
    }
    var claude5hExhaustionAt: Date? {
        ViewModel.projectedExhaustionDate(
            current: claudeCurrent?.fiveHourPct,
            resetAt: claudeCurrent?.fiveHourResetAt,
            periodLength: 5 * 3600, now: now
        )
    }
    var claude7dProjectedPct: Double? {
        ViewModel.projectedPct(
            current: claudeCurrent?.sevenDayPct,
            resetAt: claudeCurrent?.sevenDayResetAt,
            periodLength: 7 * 86400, now: now
        )
    }
    var claude7dExhaustionAt: Date? {
        ViewModel.projectedExhaustionDate(
            current: claudeCurrent?.sevenDayPct,
            resetAt: claudeCurrent?.sevenDayResetAt,
            periodLength: 7 * 86400, now: now
        )
    }

    // Cursor: % = 현재 사용 / 한도. Ultra는 cents, Pro는 requests.
    var cursorCurrentPct: Double? {
        guard let c = cursorCurrent else { return nil }
        if c.plan == .ultra, let cents = c.totalCents, let maxC = c.maxCents, maxC > 0 {
            return cents / maxC * 100
        }
        if let req = c.totalRequests, let maxR = c.maxRequests, maxR > 0 {
            return Double(req) / Double(maxR) * 100
        }
        return nil
    }
    var cursorPeriodLength: TimeInterval {
        guard let r = cursorCurrent?.resetAt,
              let start = Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: r)
        else { return 30 * 86400 }
        return r.timeIntervalSince(start)
    }
    var cursorProjectedPct: Double? {
        ViewModel.projectedPct(
            current: cursorCurrentPct,
            resetAt: cursorCurrent?.resetAt,
            periodLength: cursorPeriodLength, now: now
        )
    }
    var cursorExhaustionAt: Date? {
        ViewModel.projectedExhaustionDate(
            current: cursorCurrentPct,
            resetAt: cursorCurrent?.resetAt,
            periodLength: cursorPeriodLength, now: now
        )
    }

    // MARK: - Alert evaluation

    private func evaluateClaudeAlerts(_ snap: UsageSnapshot) {
        NotificationManager.shared.evaluate(
            key: "claude.5h",
            value: snap.fiveHourPct,
            resetAt: snap.fiveHourResetAt,
            title: "Claude 5시간 창"
        ) { t in "사용량이 \(t)%를 넘었습니다." }
        NotificationManager.shared.evaluate(
            key: "claude.7d",
            value: snap.sevenDayPct,
            resetAt: snap.sevenDayResetAt,
            title: "Claude 주간"
        ) { t in "주간 사용량이 \(t)%를 넘었습니다." }
    }

    private func evaluateCursorAlerts(_ snap: CursorSnapshot) {
        let pct: Double?
        if snap.plan == .ultra, let c = snap.totalCents, let m = snap.maxCents, m > 0 {
            pct = c / m * 100
        } else if let r = snap.totalRequests, let m = snap.maxRequests, m > 0 {
            pct = Double(r) / Double(m) * 100
        } else {
            pct = nil
        }
        NotificationManager.shared.evaluate(
            key: "cursor.month",
            value: pct,
            resetAt: snap.resetAt,
            title: "Cursor 월간"
        ) { t in "이번 달 사용량이 \(t)%를 넘었습니다." }
    }

    private func fetchCursorEventsIncrement(periodStart: Date?) async {
        // 캐시된 이벤트가 periodStart 밖에 있으면 정리
        if let start = periodStart {
            cursorEvents.removeAll { $0.timestamp < start }
        }
        let lastKnown = cursorEvents.last?.timestamp
        do {
            let new = try await CursorAPI.shared.fetchEvents(sinceExclusive: lastKnown, periodStart: periodStart)
            if !new.isEmpty {
                for ev in new { SnapshotStore.cursorEvents.append(ev) }
                cursorEvents.append(contentsOf: new)
                cursorEvents.sort { $0.timestamp < $1.timestamp }
                CoinLedger.shared.evaluateCursor(newEvents: new)
            }
        } catch {
            DebugLog.log(" fetchEvents failed: \(error.localizedDescription)")
        }
    }
}
