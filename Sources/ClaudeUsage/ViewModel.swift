import Foundation
import Combine
import AppKit

/// `dismissWellnessNudge`의 결과. 호출 측 (WalkingCat)에서 코인 popping
/// 애니메이션을 띄울지 결정하는 데 사용.
enum WellnessDismissResult {
    case rewarded(Int)   // 보상 받은 코인 수
    case noReward
}

@MainActor
final class ViewModel: ObservableObject {
    /// `.boardSeen` 알림 핸들러가 boardUnreadCount를 0으로 만들기 위해 필요한 약한 참조.
    /// ViewModel 인스턴스는 App.swift에서 1개만 만들어지고 process 수명 동안 유지되므로
    /// 여기 둔 weak ref가 늘 살아있음. multi-instance를 만들면 마지막 init이 이긴다.
    fileprivate static weak var sharedRef: ViewModel?

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

    // 날씨 파티클 — 현재 선택 위치의 실제 날씨. 기본 .clear(파티클 없음).
    @Published var weather: WeatherCondition = .clear
    /// 강수/강설량 기반 강도(0...1). 파티클 밀도를 비례시킴. clear면 의미 없음.
    @Published var weatherIntensity: Double = 1.0
    /// 날씨 갱신 캐시 — 마지막 fetch 시각/위치. 위치가 바뀌면 캐시 무시하고 즉시 갱신.
    private var lastWeatherFetchAt: Date?
    private var lastWeatherLocation: WeatherLocation?
    /// 날씨 갱신 주기 — 사용량(600s)과 분리. 30분이면 비/눈 전환을 충분히 따라감.
    private static let weatherRefreshInterval: TimeInterval = 1800
    /// 설정(위치/토글) 변경 구독 — 변경 즉시 날씨를 다시 가져온다.
    private var weatherCancellables = Set<AnyCancellable>()

    // 펫이 외치는 휴식 권유 말풍선. nil이면 표시 안 함.
    // 최근 1시간 동안 거의 쉬지 않고 사용 중이고, 마지막 표시로부터 1시간 이상 지났을 때 설정됨.
    @Published var wellnessNudge: String?

    /// 메인 패널 진입점 옆의 미확인 글 카운트. polling cycle마다 board fetch → boardLastSeenAt
    /// 이후 + 본인 글 제외로 계산. BoardView가 윈도우 띄울 때 .boardSeen post로 즉시 0.
    @Published var boardUnreadCount: Int = 0
    /// Wellness 너지 표시 시각은 `Settings.lastWellnessShownAt`에 영구 저장 — 앱 재실행 시 1시간 쿨다운이 유지되어야 함 (#11).
    private var lastWellnessShownAt: Date? {
        get { Settings.shared.lastWellnessShownAt }
        set { Settings.shared.lastWellnessShownAt = newValue }
    }

    // Section collapse
    @Published var claudeCollapsed: Bool {
        didSet { UserDefaults.standard.set(claudeCollapsed, forKey: "section.claude.collapsed") }
    }
    @Published var cursorCollapsed: Bool {
        didSet { UserDefaults.standard.set(cursorCollapsed, forKey: "section.cursor.collapsed") }
    }

    private var pollTask: Task<Void, Never>?
    /// 영속 history/events 백그라운드 로드 Task (issue #19-1). startPolling이 첫 cycle 전에
    /// 이 Task 완료를 await해 초기 로드와 첫 refresh append의 경합을 막는다.
    private var initialLoadTask: Task<Void, Never>?
    private var clockTimer: Timer?

    /// 펫 사용 시간 누적용 마지막 tick 시각. 앱 첫 실행 직후 nil → 첫 tick은 무크레딧 (앱 종료 중 시간을 보정).
    /// 인메모리만 — 재실행 시 다시 nil로 시작.
    private var lastPetUsageTickAt: Date?

    /// 한 번의 polling tick에서 펫 사용 시간으로 인정할 최대 초 (sleep/suspend 보호).
    /// 폴링 주기 600s × 2 = 1200s. 노트북 sleep 후 깨면 첫 tick은 1200s 까지만 인정.
    private static let petUsageMaxCreditPerTick: TimeInterval = 1200

    // MARK: - Bot-detection mitigations
    //
    // 비공식 endpoint 의존도가 높아 자동화 흔적을 최대한 흐리는 것이 사용자 계정 안전과 직결.
    // (1) jitter: 정확한 300/600s 간격은 robotic 패턴 → ±15% 무작위.
    // (2) backoff: 429/5xx 등 transient 실패 시 지수적 sleep 늘림.
    // (3) sleep gate: macOS sleep/wake 동안 폴링 중단 (깨자마자 폭주 방지).
    // (4) visibility gate: panel/menu bar 모두 안 보이면 폴링 skip.
    /// 폴링 cycle 직전 visibility 검사용 — App.swift가 panel show/orderOut 시 갱신.
    /// 기본값 true (panel 가시 가정), 메뉴바 모드는 `Settings.showMenuBar`로 별도 판단.
    var panelIsVisible: Bool = true
    /// macOS sleep 진입 동안 true. didWake 시 false → polling 재개.
    private var isSystemSleeping: Bool = false
    /// 연속된 transient 실패 (429/5xx/network) 카운터. 성공 시 0으로 reset.
    /// sleep 시간을 2^min(n,4) 배 (최대 16x) 늘려서 endpoint에 부담 안 주게 backoff.
    private var consecutiveBackoffSteps: Int = 0
    /// refresh 메서드가 결과를 적어두는 per-source 플래그 — 한 cycle 완료 후 backoff 갱신에 사용.
    /// 인증 오류는 backoff 대상 아님 (재로그인이 필요한 사용자 액션).
    private var claudePollOutcome: PollOutcome = .success
    private var cursorPollOutcome: PollOutcome = .success
    /// 연속 schema-suspect 카운터. 임계 도달 시 NotificationManager로 1회 알림.
    /// success 시 0으로 reset, auth 에러는 카운터 유지(별개 사용자 액션).
    private var claudeSchemaSuspectCount: Int = 0
    private var cursorSchemaSuspectCount: Int = 0
    /// 알림 발사 임계 — N회 연속 schema-suspect 시 1회 발송.
    /// 폴링 600s × 3 = 30분 — 일시적 네트워크 jitter는 통과하고 진짜 변경만 잡힘.
    static let schemaSuspectThreshold: Int = 3

    /// jitter 적용 — robotic 일정한 간격을 깸. 짧은 sleep (< 60s, reset 직전) 은 그대로 둠.
    nonisolated static func applyJitter(_ baseSleep: TimeInterval) -> TimeInterval {
        guard baseSleep > 60 else { return baseSleep }
        let factor = Double.random(in: 0.85...1.15)
        return baseSleep * factor
    }

    /// 연속 실패 횟수 → sleep 배수. 0 → 1×, 1 → 2×, 2 → 4×, 3 → 8×, 4+ → 16×.
    nonisolated static func backoffMultiplier(steps: Int) -> Double {
        let capped = max(0, min(4, steps))
        return pow(2.0, Double(capped))
    }

    /// API endpoint가 깨졌을 가능성이 있다고 판단할 만한 에러인지 분류.
    /// - true: 응답 디코딩 실패 / 4xx (auth/429 제외) — 스키마·경로 변경 의심
    /// - false: 401/403(auth), 429/5xx/network(transient)
    /// 비공식 endpoint를 쓰는 만큼 변경 사실을 사용자에게 빨리 알리기 위한 신호 분류.
    nonisolated static func isSchemaSuspect(_ error: Error) -> Bool {
        if let e = error as? UsageError {
            switch e {
            case .decoding: return true
            case .http(let code):
                return (400..<500).contains(code) && code != 401 && code != 403 && code != 429
            default: return false
            }
        }
        if let e = error as? CursorError {
            switch e {
            case .decoding: return true
            case .http(let code):
                return (400..<500).contains(code) && code != 401 && code != 403 && code != 429
            default: return false
            }
        }
        return false
    }

    init() {
        // 사용량 이벤트 ledger 등록 — GUI/TUI 모두 ViewModel 경유하므로 여기에 두면 두 모드 모두
        // 안전. UsageEventBus.register는 dedup이 있어 중복 호출 무해.
        UsageEventBus.shared.register(CoinLedger.shared)
        UsageEventBus.shared.register(VPLedger.shared)

        let d = UserDefaults.standard
        self.claudeCollapsed = d.bool(forKey: "section.claude.collapsed")
        self.cursorCollapsed = d.bool(forKey: "section.cursor.collapsed")

        // 시작 시 Keychain을 직접 읽지 않는다(프롬프트 유발). 첫 refresh가 needsLogin을 갱신함.
        self.claudeNeedsLogin = false

        // 영속 history/events 로드는 백그라운드로 분리 (issue #19-1).
        // 동기 loadRecent(특히 cursorEvents 20000 + sort)가 @MainActor init을 store queue.sync로
        // 블로킹해 콜드 스타트를 파일 크기에 비례해 악화시키던 것을 제거. UI는 빈 상태로 즉시 뜨고
        // 로드 완료 시 @Published 갱신. polling은 startPolling에서 이 Task 완료를 await한 뒤
        // 시작하므로 첫 refresh append와 경합하지 않는다.
        self.initialLoadTask = Task { [weak self] in await self?.loadPersistedHistory() }

        startClock()

        // BoardView가 윈도우 띄우면 즉시 unread를 0으로 — polling cycle을 기다리지 않게.
        // ViewModel은 process 수명이라 옵저버 토큰 미보관, weak ref로 self 캡처.
        ViewModel.sharedRef = self
        NotificationCenter.default.addObserver(forName: .boardSeen, object: nil, queue: .main) { _ in
            Task { @MainActor in
                Settings.shared.boardLastSeenAt = Date()
                ViewModel.sharedRef?.boardUnreadCount = 0
            }
        }

        // 날씨 위치/토글 변경을 구독 — 변경 즉시 fetch(force)해 설정 반영을 다음 폴링까지 기다리지 않게.
        // @Published는 willSet 시점에 발행되므로 Task로 비동기 디스패치해 최신 값을 읽는다.
        Publishers.Merge(
            Settings.shared.$weatherLocation.dropFirst().map { _ in () },
            Settings.shared.$weatherEffectEnabled.dropFirst().map { _ in () }
        )
        .sink { [weak self] in
            Task { @MainActor in await self?.refreshWeather(force: true) }
        }
        .store(in: &weatherCancellables)
    }

    /// 영속된 history/events를 백그라운드 스레드에서 읽어 @Published에 1회 반영 (issue #19-1).
    /// 파일 IO + cursorEvents 정렬을 `Task.detached`로 빼 @MainActor를 블로킹하지 않는다.
    /// startPolling이 `initialLoadTask`를 await한 뒤 첫 refresh를 돌리므로, 여기서의 대입이
    /// 폴링 append를 덮어쓰는 race는 없다.
    private func loadPersistedHistory() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            let claude = SnapshotStore.claude.loadRecent()
            let cursor = SnapshotStore.cursor.loadRecent()
            let events = SnapshotStore.cursorEvents.loadRecent(limit: 20000)
                .sorted { $0.timestamp < $1.timestamp }
            return (claude, cursor, events)
        }.value
        claudeHistory = loaded.0
        claudeCurrent = loaded.0.last
        claudeLastSuccess = loaded.0.last?.takenAt
        cursorHistory = loaded.1
        cursorCurrent = loaded.1.last
        cursorLastSuccess = loaded.1.last?.takenAt
        cursorEvents = loaded.2
    }

    func startClock() {
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.now = Date()
                self.evaluateWellnessNudge()
                self.expireWellnessNudgeIfNeeded()
            }
        }
    }

    /// reward window(5분)가 지나면 nudge 자동 사라짐. 클릭 안 해도 시간 지나면 reset —
    /// 이슈 #9: "30초 지나면 메세지 사라지게" 후속으로 reward window와 동기화해 5분 후 자동 dismiss.
    private func expireWellnessNudgeIfNeeded() {
        guard wellnessNudge != nil,
              let shownAt = lastWellnessShownAt,
              Date().timeIntervalSince(shownAt) >= Self.wellnessRewardWindow else { return }
        wellnessNudge = nil
    }

    // MARK: - Wellness nudge

    // 1시간 동안 거의 쉬지 않고 사용 중이면 휴식 권유 말풍선을 띄운다.
    // 5분 폴링 간격이라 1시간 = 12 스냅샷, 그 중 flat(델타 < 0.1%)이 2개 이하일 때 "계속 일하는 중"으로 본다.
    // 한 번 띄우면 1시간 쿨다운.
    static let wellnessIntervalSec: TimeInterval = 60 * 60
    /// nudge 표시 후 이 시간 내에 클릭하면 보상 (5분 버퍼).
    static let wellnessRewardWindow: TimeInterval = 5 * 60
    /// 보상 코인 — 표시 직후 +500에서 시작해 1분간 지수감쇠로 +30까지 떨어지고, 이후 유지시간
    /// (5분) 끝까지 +30 고정. 빨리 반응할수록 보상이 크다.
    static let wellnessRewardMax: Int = 500
    static let wellnessRewardMin: Int = 30
    /// 감쇠 구간 — 이 시간 동안 max→min, 이후엔 min 고정.
    static let wellnessDecaySec: TimeInterval = 60
    /// 지수감쇠 시간상수(초). 작을수록 초반에 급히 깎인다. decaySec 안에서 충분히 수렴.
    static let wellnessDecayTau: TimeInterval = 15

    /// 표시 후 경과 시간(elapsed)에 따른 보상 코인.
    /// 0초 → max, decaySec(1분)에 정확히 min으로 수렴하는 정규화 지수감쇠. 이후는 min 고정.
    static func wellnessReward(elapsed: TimeInterval) -> Int {
        let lo = Double(wellnessRewardMin), hi = Double(wellnessRewardMax)
        if elapsed <= 0 { return wellnessRewardMax }
        if elapsed >= wellnessDecaySec { return wellnessRewardMin }
        let k = 1.0 / wellnessDecayTau
        let e = exp(-k * elapsed)
        let eEnd = exp(-k * wellnessDecaySec)
        let norm = (e - eEnd) / (1 - eEnd)   // t=0 → 1, t=decaySec → 0
        return Int((lo + (hi - lo) * norm).rounded())
    }

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

    /// nudge 클릭 처리. 표시 후 `wellnessRewardWindow`(5분) 이내면 코인 보상.
    /// - Returns: 보상 여부와 금액. 호출 측이 popping 애니메이션 트리거에 사용.
    @discardableResult
    func dismissWellnessNudge() -> WellnessDismissResult {
        defer { wellnessNudge = nil }
        let elapsed = lastWellnessShownAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed < Self.wellnessRewardWindow else { return .noReward }
        let amount = Self.wellnessReward(elapsed: elapsed)
        // credit 정책(totalEarned/firstCreditedAt 추적)을 한곳에서만 관리하기 위해 CoinLedger 경유.
        CoinLedger.shared.creditWellness(amount: amount)
        // Standup 도장 — `.rewarded`(60s 안 응답)만 카운트.
        Settings.shared.wellnessRespondedCount += 1
        BadgeRegistry.evaluate()
        return .rewarded(amount)
    }

    /// 임박한 resetAt 직전(=`resetGuard`초 전)에 마지막 관측 폴링이 잡히도록 sleep을 단축.
    /// 윈도우 끝 사용분이 코인 적립에서 누락되는 걸 막기 위함 — 그 폴링의 pct가 윈도우 종료 pct로
    /// 기록되고, 다음(=normal interval) 폴링은 새 윈도우라서 자연스럽게 rebase된다.
    /// 30s buffer는 refresh의 네트워크 라운드트립(특히 Ultra cursor event 페이지네이션)이
    /// resetAt을 넘겨버려 새 윈도우 baseline을 받아오는 걸 막기 위한 안전 마진.
    static let resetGuard: TimeInterval = 30
    static let minSleep: TimeInterval = 5

    /// 기본 폴링 간격 600s (10분). 5분에서 늘려 트래픽 절반으로 — 비공식 endpoint 부담 + bot 검출 신호 ↓.
    /// 차트 분해능은 살짝 떨어지지만 5h/7d 윈도우 추적엔 충분.
    func startPolling(interval: TimeInterval = 600) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // 영속 history 초기 로드 완료 후 첫 refresh를 돌린다 — append가 초기 로드 대입에
            // 덮어쓰이지 않도록 (issue #19-1). 파일 IO라 보통 첫 네트워크보다 먼저 끝난다.
            await self.initialLoadTask?.value
            while !Task.isCancelled {
                // (visibility gate) panel/menu bar 모두 안 보이면 refresh 스킵.
                // (sleep gate) macOS sleep 동안에도 스킵 — 깨자마자 폭주 방지.
                let active = self.shouldPollNow()
                if active {
                    self.updateGymCountersOnCycleStart(sleepSec: interval)
                    await self.refreshClaude()
                    await self.refreshCursor()
                    await self.refreshWeather()
                    self.accumulatePetUsage()
                    await ContributorBonus.shared.sync()
                    self.updateBackoffAfterCycle()
                    BadgeRegistry.evaluate()
                    await self.submitRankingIfNeeded()
                    await self.checkPodiumRewardIfNeeded()
                    await self.refreshBoardUnread()
                }

                // sleep 시간 = base × jitter × backoff multiplier.
                // 비활성 상태(sleep/invisible)일 땐 jitter/backoff 없이 짧게 폴링 — 깨면 즉시 재개되도록.
                let baseSleep = self.nextPollDelay(maxInterval: interval)
                let sleepSec: TimeInterval
                if active {
                    let jittered = Self.applyJitter(baseSleep)
                    let multiplier = Self.backoffMultiplier(steps: self.consecutiveBackoffSteps)
                    sleepSec = min(60 * 60, jittered * multiplier)  // 한 시간 cap
                } else {
                    // sleep/invisible 동안엔 30s 간격으로 가벼운 polling — visibility/wake 빠르게 감지.
                    sleepSec = min(baseSleep, 30)
                }
                DebugLog.log("Poll cycle done: active=\(active) base=\(Int(baseSleep))s → sleep=\(Int(sleepSec))s (backoff×\(Int(Self.backoffMultiplier(steps: self.consecutiveBackoffSteps))))")
                try? await Task.sleep(nanoseconds: UInt64(sleepSec * 1_000_000_000))
            }
        }
    }

    /// 현재 polling을 진행할지 결정. macOS sleep 또는 가시 surface(패널/메뉴바) 둘 다 없으면 false.
    private func shouldPollNow() -> Bool {
        if isSystemSleeping { return false }
        let visibleSurface = panelIsVisible || Settings.shared.showMenuBar
        return visibleSurface
    }

    /// 한 cycle의 결과로 backoff counter + schema-suspect counter 갱신.
    /// transient/schema-suspect 모두 backoff 대상 (endpoint 부담 줄이기).
    /// schema-suspect는 추가로 per-source 카운터를 누적 — 임계 도달 시 1회 사용자 알림.
    private func updateBackoffAfterCycle() {
        func isBackoffWorthy(_ o: PollOutcome) -> Bool {
            return o == .transientError || o == .apiSchemaSuspect
        }
        let transient = isBackoffWorthy(claudePollOutcome) || isBackoffWorthy(cursorPollOutcome)
        if transient {
            consecutiveBackoffSteps = min(4, consecutiveBackoffSteps + 1)
            DebugLog.log("Polling backoff step \(consecutiveBackoffSteps) → next sleep ×\(Self.backoffMultiplier(steps: consecutiveBackoffSteps))")
        } else {
            consecutiveBackoffSteps = 0
        }

        // Per-source schema-suspect: success가 들어오면 reset, auth 에러는 유지(중립).
        // 임계 도달 정확히 그 cycle에 알림 1회 — NotificationManager가 24h 쿨다운으로 dedup.
        if claudePollOutcome == .apiSchemaSuspect {
            claudeSchemaSuspectCount += 1
            if claudeSchemaSuspectCount == Self.schemaSuspectThreshold {
                NotificationManager.shared.endpointSuspect(source: "Claude")
            }
        } else if claudePollOutcome == .success {
            claudeSchemaSuspectCount = 0
        }
        if cursorPollOutcome == .apiSchemaSuspect {
            cursorSchemaSuspectCount += 1
            if cursorSchemaSuspectCount == Self.schemaSuspectThreshold {
                NotificationManager.shared.endpointSuspect(source: "Cursor")
            }
        } else if cursorPollOutcome == .success {
            cursorSchemaSuspectCount = 0
        }
    }

    /// macOS sleep/wake 알림 등록. App.swift 또는 init에서 1회 호출.
    /// sleep 동안 polling task가 내부적으로 멈춘다 (Task.sleep가 wall-clock 기반이라 자동 보정됨).
    func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemSleeping = true
                DebugLog.log("System will sleep — polling paused")
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSystemSleeping = false
                DebugLog.log("System did wake — polling resumed")
            }
        }
    }

    enum PollOutcome {
        case success            // 정상 응답 (snapshot 적재됨)
        case authError          // 401/403 등 — backoff 안 함, 사용자 재로그인 필요
        case transientError     // 429/5xx/network — backoff 대상
        case apiSchemaSuspect   // 디코딩 실패 / 4xx (auth/429 제외) — endpoint 변경 의심
    }

    /// 현재 선택 위치의 날씨를 가져와 `weather`를 갱신. 사용량 폴링과 같은 cycle에서 호출되지만
    /// 30분 캐시로 묶어 Open-Meteo를 매 폴링(600s)마다 치지 않는다. 위치 변경/토글 시엔
    /// Combine 구독이 `force: true`로 즉시 호출 → 캐시 무시.
    /// 실패는 조용히 무시(기존 값 유지) — 날씨는 부가 연출이라 에러를 사용자에게 노출하지 않는다.
    func refreshWeather(force: Bool = false) async {
        guard Settings.shared.weatherEffectEnabled else {
            if weather != .clear { weather = .clear }
            lastWeatherFetchAt = nil       // 다시 켜면 즉시 fetch 되도록 캐시 초기화
            return
        }
        let loc = Settings.shared.weatherLocation
        let locChanged = (loc != lastWeatherLocation)
        if !force, !locChanged, let last = lastWeatherFetchAt,
           Date().timeIntervalSince(last) < Self.weatherRefreshInterval {
            return
        }
        do {
            let reading = try await WeatherAPI.shared.fetch(loc)
            if weather != reading.condition { weather = reading.condition }
            if weatherIntensity != reading.intensity { weatherIntensity = reading.intensity }
            lastWeatherFetchAt = Date()
            lastWeatherLocation = loc
        } catch {
            DebugLog.log("Weather fetch 실패: \(error)")
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
        var usageChanged = false
        var ownedChanged = false

        func creditOne(_ kind: PetKind) {
            usage[kind, default: 0] += credited
            usageChanged = true
            guard var o = owned[kind] else { return }
            let total = usage[kind, default: 0]
            // registerUsage는 variant unlock 시에만 o를 mutate하고 그 외엔 불변(nil 반환).
            // nil이면 owned[kind]는 기존 값과 동일하므로 대입 자체를 생략한다.
            if let v = o.registerUsage(totalSeconds: total) {
                DebugLog.log("Pet usage unlock: \(kind.rawValue) variant \(v) @ \(Int(total / 86400))d")
                // 도감 강조 — 사용자가 직접 슬롯 클릭해 확인하기 전까지 NEW 뱃지 유지.
                s.pendingHighlights.insert(kind)
                owned[kind] = o
                ownedChanged = true
            }
        }

        if s.petClaudeEnabled { creditOne(s.petClaudeKind) }
        if s.petCursorEnabled { creditOne(s.petCursorKind) }

        // 무조건 대입은 didSet → JSONEncoder encode + UserDefaults write를 매 폴링 강제했다 (issue #19-5).
        // 실제 변경이 있을 때만 대입한다. usage는 펫 enable 시 매 tick 증가하지만, ownedPets는
        // variant unlock(4d/8d/12d 임계, 극히 드묾) 시에만 바뀌므로 대부분 폴링에서 write가 사라진다.
        if usageChanged { s.petUsageSeconds = usage }
        if ownedChanged { s.ownedPets = owned }
    }

    /// 랭킹 서버에 누적 VP delta 제출 + 프로필 동기화. fire-and-forget — 실패해도 본 폴링
    /// 루프에 영향 없음. 옵트인 + 등록 + HMAC 키 + Supabase 설정 모두 갖춰진 경우에만 실제 호출.
    /// delta = `rankingScoreEarnedVP` - `rankingLastSubmittedTotal`. 0 이하면 skip (profile은
    /// 다음 VP 적립 cycle에 piggy-back되어 동기화).
    /// 랭킹 기능 4개 전제(enabled / registered / deviceID / Supabase 설정) 동시 충족 여부.
    /// 3곳에서 같은 가드를 반복하던 것을 1곳으로 모음 — 새 조건 추가 시 누락 위험 제거.
    private var hasRankingPrerequisites: Bool {
        let s = Settings.shared
        return s.rankingEnabled && s.rankingRegistered &&
               !s.rankingDeviceID.isEmpty && RankingAPI.isConfigured
    }

    private func submitRankingIfNeeded() async {
        let s = Settings.shared
        guard hasRankingPrerequisites,
              let hmacKey = Keychain.loadRankingHmacKey() else { return }
        let total = s.rankingScoreEarnedVP
        let delta = total - s.rankingLastSubmittedTotal
        guard delta > 0 else { return }
        let profile = ProfileState.current(from: s)
        do {
            let resp = try await RankingAPI.shared.submitDelta(
                deviceId: s.rankingDeviceID,
                delta: delta,
                prevTotal: s.rankingLastSubmittedTotal,
                hmacKeyBase64: hmacKey,
                profileJson: profile
            )
            if resp.accepted {
                s.rankingLastSubmittedTotal = total
                s.rankingLastSubmittedAt = Date()
                DebugLog.log("Ranking: submitted +\(delta) coin (server total=\(resp.totalCoins))")
            } else if resp.rejectReason == "prev_total_mismatch" {
                // 클라이언트가 추적하는 prevTotal과 서버 total이 어긋남 (보통 옛 register 코드로
                // 등록된 경우 서버 0인 채로 시작). 서버 값을 truth로 sync — 다음 cycle에 정상
                // delta 계산. 캡으로 한 번에 다 못 보내는 경우 여러 cycle 걸쳐 따라잡음.
                DebugLog.log("Ranking: prev_total drift — syncing to server total=\(resp.totalCoins)")
                s.rankingLastSubmittedTotal = resp.totalCoins
            } else {
                DebugLog.log("Ranking: submit rejected — \(resp.rejectReason ?? "unknown")")
            }
        } catch {
            DebugLog.log("Ranking submit failed: \(error.localizedDescription)")
        }
    }

    /// 명예의 전당 보상 처리. 폴링 cycle 끝에 호출 — 서버가 직전 달 finalize 했고 본인이
    /// Top 3에 들었으면 `pendingReward`로 응답. 로컬 dedup + CoinLedger.creditBonus +
    /// NSUserNotification + 서버 claim까지 일괄 처리.
    ///
    /// 네트워크 race 대응:
    ///   - 로컬 dedup(`claimedPodiumPeriods`)이 1차 방어 — 같은 reward 중복 적립 차단
    ///   - 서버 idempotent claim이 2차 방어 — `alreadyClaimed=true` 응답 무시
    ///   - 서버 claim 실패해도 로컬 상태는 이미 갱신됨 → 다음 cycle에 재시도
    private func checkPodiumRewardIfNeeded() async {
        let s = Settings.shared
        guard hasRankingPrerequisites,
              let hmacKey = Keychain.loadRankingHmacKey() else { return }
        do {
            let resp = try await RankingAPI.shared.fetchLeaderboard(deviceId: s.rankingDeviceID)
            // 본인 누적 메달 캐시 갱신 — pendingReward 유무와 무관하게 매 cycle 반영.
            s.applyMyMedals(resp.myMedals)
            // coins 보상 (명예의 전당 Top3) — credit 먼저 + 로컬 dedup, 서버 claim은 마킹용.
            if let reward = resp.pendingReward {
                let dedupKey = reward.dedupKey
                if !s.claimedPodiumPeriods.contains(dedupKey) {
                    CoinLedger.shared.creditBonus(reward.coins, reason: "podium.\(dedupKey)")
                    s.claimedPodiumPeriods.insert(dedupKey)
                    NotificationManager.shared.podiumRewardEarned(
                        period: reward.period, rank: reward.rank, coins: reward.coins
                    )
                    DebugLog.log("Podium reward: \(dedupKey) +\(reward.coins) coin")
                }
                // 서버 측 claim — 실패해도 다음 cycle에 자동 재시도 (idempotent로 안전).
                do {
                    _ = try await RankingAPI.shared.claimReward(
                        deviceId: s.rankingDeviceID,
                        period: reward.period,
                        rank: reward.rank,
                        hmacKeyBase64: hmacKey
                    )
                } catch {
                    DebugLog.log("Podium claim server failed: \(error.localizedDescription) — retry next cycle")
                }
            }

            // RP 보상 (순위 정산, 월간/주간) — 서버 claim의 alreadyClaimed로 중복을 판정한 뒤 credit하므로
            // 백업 복원 후에도 이중 적립되지 않는다 (coins의 credit-먼저 패턴과 의도적으로 다름).
            if let rp = resp.pendingRpReward, !s.claimedRpRewards.contains(rp.dedupKey) {
                do {
                    let claimResp = try await RankingAPI.shared.claimReward(
                        deviceId: s.rankingDeviceID,
                        period: rp.period,
                        rank: rp.rank,
                        rewardType: "rp",
                        hmacKeyBase64: hmacKey
                    )
                    if !claimResp.alreadyClaimed {
                        RankPointLedger.shared.creditReward(rp.rp, reason: "rank.\(rp.dedupKey)")
                        DebugLog.log("RP reward: \(rp.dedupKey) +\(rp.rp) RP")
                    }
                    s.claimedRpRewards.insert(rp.dedupKey)
                } catch {
                    DebugLog.log("RP claim failed: \(error.localizedDescription) — retry next cycle")
                }
            }
        } catch {
            DebugLog.log("Podium check failed: \(error.localizedDescription)")
        }
    }

    /// 게시판 미확인 글 카운트 갱신. boardLastSeenAt 이후 + 본인 글 제외.
    /// boardLastSeenAt이 nil(첫 fetch)이면 현재 시각으로 시드 — 과거 글 전체를 미확인으로
    /// 표시하지 않게 함. 미등록자는 게시판 사용 불가 → 카운트 0 유지.
    private func refreshBoardUnread() async {
        let s = Settings.shared
        guard hasRankingPrerequisites else {
            if boardUnreadCount != 0 { boardUnreadCount = 0 }
            return
        }
        do {
            let resp = try await RankingAPI.shared.fetchBoard(deviceId: s.rankingDeviceID)
            // 첫 fetch — boardLastSeenAt 시드. 과거 글이 다 unread로 잡히지 않게.
            if s.boardLastSeenAt == nil {
                s.boardLastSeenAt = Date()
                boardUnreadCount = 0
                return
            }
            let lastSeen = s.boardLastSeenAt ?? .distantPast
            let count = resp.posts.filter { !$0.isMine && $0.createdAt > lastSeen }.count
            boardUnreadCount = count
        } catch {
            // 무시 — 다음 cycle 재시도. UI는 직전 카운트 유지.
        }
    }

    /// 도장 카운터 — Heartbeat (36h grace streak), Night Owl (0~6시 폴링 누적).
    /// Rate Limit은 7d resetAt 변경 시점에 평가하므로 `refreshClaude`에서 따로 처리.
    /// `sleepSec`은 직전 cycle의 sleep 길이 — Night Owl 누적 단위.
    private func updateGymCountersOnCycleStart(sleepSec: TimeInterval) {
        let s = Settings.shared
        let now = Date()

        // Heartbeat — 36h grace + 자정 기준 day 변경 시 streak++.
        if let last = s.heartbeatLastActiveAt {
            let elapsed = now.timeIntervalSince(last)
            if elapsed > 36 * 3600 {
                s.heartbeatStreak = 1
            } else if !Calendar.current.isDate(last, inSameDayAs: now) {
                s.heartbeatStreak += 1
            }
        } else {
            s.heartbeatStreak = 1
        }
        s.heartbeatLastActiveAt = now

        // Night Owl — 자정~6시면 직전 sleep 길이만큼 누적. 첫 cycle은 sleep 없으니 0.
        let hour = Calendar.current.component(.hour, from: now)
        if hour < 6 {
            s.nightOwlSecondsAccumulated += Int(sleepSec)
        }
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
            evaluateRateLimitGym(snap)
            UsageEventProducer.ingestClaude(snap)
            BadgeRegistry.evaluate()
            claudePollOutcome = .success
        } catch UsageError.notLoggedIn {
            claudeNeedsLogin = true
            claudeError = "로그인 필요"
            claudePollOutcome = .authError
        } catch UsageError.unauthorized {
            claudeNeedsLogin = true
            claudeError = "세션 만료"
            Keychain.clear()
            claudePollOutcome = .authError
        } catch {
            claudeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // 디코딩/4xx(non-auth) → endpoint 변경 의심, 그 외 → transient. 둘 다 backoff 대상.
            claudePollOutcome = Self.isSchemaSuspect(error) ? .apiSchemaSuspect : .transientError
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
            } else {
                // Pro/Free/Business — snapshot의 request delta 기반 (Ultra는 events 경로).
                UsageEventProducer.ingestCursorSnapshot(snap)
            }
            cursorPollOutcome = .success
        } catch CursorError.cursorNotInstalled, CursorError.notLoggedIn {
            cursorNeedsSetup = true
            cursorError = "Cursor 앱 로그인 필요"
            cursorPollOutcome = .authError
            // 조용한 실패였던 경로 — JWT 읽기 실패(미설치/미로그인/DB lock)는 사용량 누락으로 직결되므로 로깅.
            DebugLog.log("refreshCursor: JWT 읽기 실패 → setup needed (미설치/미로그인, 또는 Cursor 앱 실행 중 DB lock 가능성)")
        } catch CursorError.unauthorized {
            cursorNeedsSetup = true
            cursorError = "Cursor 세션 만료 (앱에서 재로그인)"
            cursorPollOutcome = .authError
            DebugLog.log("refreshCursor: unauthorized (세션 만료)")
        } catch {
            cursorError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            cursorPollOutcome = Self.isSchemaSuspect(error) ? .apiSchemaSuspect : .transientError
            DebugLog.log("refreshCursor failed: \(cursorError ?? error.localizedDescription) (schemaSuspect=\(Self.isSchemaSuspect(error)))")
        }
    }

    // MARK: - Pace prediction

    // 현재 페이스로 주기 끝까지 갔을 때 예상 사용률(%).
    // current: 현재 % (0~100), resetAt: 주기 끝, periodLength: 주기 전체 길이(초).
    // 경과시간이 너무 짧으면 노이즈 → nil.
    nonisolated static func projectedPct(current: Double?, resetAt: Date?, periodLength: TimeInterval, now: Date) -> Double? {
        guard let current, let resetAt else { return nil }
        let remaining = resetAt.timeIntervalSince(now)
        let elapsed = periodLength - remaining
        // 5h 창은 15분 미만, 그 외는 주기의 5% 미만이면 예측 보류
        let minElapsed = max(15 * 60, periodLength * 0.05)
        guard elapsed >= minElapsed, elapsed > 0 else { return nil }
        return current * (periodLength / elapsed)
    }

    // 페이스가 100%를 초과할 때, 한도 도달 예상 시각.
    nonisolated static func projectedExhaustionDate(current: Double?, resetAt: Date?, periodLength: TimeInterval, now: Date) -> Date? {
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

    // MARK: - Gym (Rate Limit)

    /// Rate Limit 도장 — 7d resetAt이 변경된 cycle에서 *직전* pct가 < 80%면 +1.
    /// `lastClaudeSevenDayReset`/`lastClaudeSevenDayPctSeen`은 CoinLedger.evaluateClaude가
    /// 같은 cycle 안 뒷쪽에서 갱신하므로 *그 전*에 비교해야 직전 값 유지된 상태로 detect.
    private func evaluateRateLimitGym(_ snap: UsageSnapshot) {
        let s = Settings.shared
        guard let newReset = snap.sevenDayResetAt,
              let lastReset = s.lastClaudeSevenDayReset,
              newReset != lastReset,                   // 윈도우 변경
              let lastPct = s.lastClaudeSevenDayPctSeen,
              lastPct < 80 else { return }
        s.rateLimitWeeksPassed += 1
        DebugLog.log("Gym RateLimit: weeks=\(s.rateLimitWeeksPassed) (last 7d=\(String(format: "%.1f", lastPct))%)")
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

    /// `await fetchEvents` 사이 다른 호출이 들어와 같은 events를 두 번 credit하는 race 방지.
    /// @MainActor라 단순 Bool 가드면 atomic. 두 번째 호출은 즉시 return.
    private var cursorEventsFetching: Bool = false

    private func fetchCursorEventsIncrement(periodStart: Date?) async {
        guard !cursorEventsFetching else { return }
        cursorEventsFetching = true
        defer { cursorEventsFetching = false }

        // 캐시된 이벤트가 periodStart 밖에 있으면 정리. cursorEvents는 시간순 불변이라
        // periodStart 미만은 prefix — 전체 스캔(removeAll) 대신 cut 지점까지만 제거 (issue #19-3).
        if let start = periodStart {
            let cut = cursorEvents.firstIndex { $0.timestamp >= start } ?? cursorEvents.count
            if cut > 0 { cursorEvents.removeFirst(cut) }
        }
        let lastKnown = cursorEvents.last?.timestamp
        do {
            let new = try await CursorAPI.shared.fetchEvents(sinceExclusive: lastKnown, periodStart: periodStart)
            if !new.isEmpty {
                for ev in new { SnapshotStore.cursorEvents.append(ev) }
                // fetchEvents는 서버 응답 순서(최신순)라 new 자체가 역순일 수 있음 → new만 정렬한 뒤
                // 이미 시간순인 cursorEvents와 O(n+m) merge. 폴링마다 full sort(O(n log n)) 대체 (issue #19-3).
                let sortedNew = new.sorted { $0.timestamp < $1.timestamp }
                cursorEvents = Self.mergeSortedByTimestamp(cursorEvents, sortedNew)
                UsageEventProducer.ingestCursorEvents(new)
                BadgeRegistry.evaluate()
            }
        } catch {
            DebugLog.log(" fetchEvents failed: \(error.localizedDescription)")
        }
    }

    /// 시간순 정렬된 두 배열을 O(n+m) 2-pointer로 병합 (issue #19-3).
    /// 입력은 둘 다 timestamp 오름차순이어야 하며 결과도 오름차순. 폴링마다 도는
    /// 전체 재정렬(O(n log n))을 대체한다.
    nonisolated static func mergeSortedByTimestamp(_ a: [CursorEvent], _ b: [CursorEvent]) -> [CursorEvent] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        var out: [CursorEvent] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i].timestamp <= b[j].timestamp { out.append(a[i]); i += 1 }
            else { out.append(b[j]); j += 1 }
        }
        if i < a.count { out.append(contentsOf: a[i...]) }
        if j < b.count { out.append(contentsOf: b[j...]) }
        return out
    }
}
