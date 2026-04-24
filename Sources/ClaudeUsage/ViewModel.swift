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
            Task { @MainActor in self?.now = Date() }
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
