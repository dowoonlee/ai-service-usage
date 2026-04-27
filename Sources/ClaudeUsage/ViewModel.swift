import Foundation
import Combine

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

    // Section collapse
    @Published var claudeCollapsed: Bool {
        didSet { UserDefaults.standard.set(claudeCollapsed, forKey: "section.claude.collapsed") }
    }
    @Published var cursorCollapsed: Bool {
        didSet { UserDefaults.standard.set(cursorCollapsed, forKey: "section.cursor.collapsed") }
    }

    private var pollTask: Task<Void, Never>?
    private var clockTimer: Timer?

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
            Task { @MainActor in self.now = Date() }
        }
    }

    func startPolling(interval: TimeInterval = 300) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshClaude()
                await self.refreshCursor()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
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
            }
        } catch {
            DebugLog.log(" fetchEvents failed: \(error.localizedDescription)")
        }
    }
}
