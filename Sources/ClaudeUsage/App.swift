import AppKit
import Combine
import SwiftUI

@main
@MainActor
struct ClaudeUsageApp {
    static func main() {
        // CLI 모드: AppKit 안 띄우고 ANSI 기반 dashboard 실행. --help/--tui 만 지원.
        if CommandLine.arguments.contains("--tui") {
            TUIApp.run()  // 자체 RunLoop blocks; 여기서 안 돌아옴.
            return
        }
        // 로컬 진단: 사용량 수집/파싱 정상 여부를 점검하고 stdout 출력 후 종료.
        // --raw 면 원본 응답 JSON도 덤프. DiagnosticsCLI.run 내부에서 exit() 호출.
        if CommandLine.arguments.contains("--check") {
            let raw = CommandLine.arguments.contains("--raw")
            Task.detached { await DiagnosticsCLI.run(raw: raw) }
            RunLoop.main.run()  // exit() 호출될 때까지 main thread 유지
            return
        }
        // 아레나 엔진 데모: UI/서버 없이 컴파일된 배틀/강화/상성 엔진을 실행해 stdout 출력.
        if CommandLine.arguments.contains("--arena-demo") {
            ArenaDemo.run()
            return
        }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            app.run()
        }
    }
}

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: FloatingPanel?
    var loginWC: LoginWindowController?
    var settingsWC: SettingsWindowController?
    let vm = ViewModel()
    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var menuBarPetTimer: Timer?
    /// 메뉴바 위젯 그리기 — 상태(프레임·펫 좌표·회전)와 캐시는 전부 렌더러가 들고 있다.
    /// AppDelegate는 status item 생명주기와 데이터 소스 선택만 담당한다.
    private let menuBarRenderer = MenuBarRenderer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 디버그 로그 회전 — 5MB 초과 시 .bak으로 rename. 다른 컴포넌트의 첫 log 호출
        // 이전에 회전해야 새 사이클의 로그가 깨끗한 파일에서 시작.
        DebugLog.rotateIfNeeded()
        // 샌드박스로 뜨면 설정·keychain·JSONL이 전부 임시본이라 사용자에겐 "데이터가 사라진" 것으로
        // 보인다. 버그 리포트에서 그 상황을 한 줄로 판별할 수 있게 시작 시 기록한다.
        if AppEnv.isSandboxed {
            DebugLog.log("⚠️ AppEnv: SANDBOX 모드로 시작 — 설정/keychain/JSONL이 임시 저장소입니다")
        }
        // 직전 실행 비정상 종료 여부 — setupPanel 보다 *먼저* 호출해서 키 갱신을 끝낸다.
        // 다이얼로그 자체는 패널이 뜬 뒤에 보여야 자연스럽기 때문에 record 만 잡아두고 나중에 띄움.
        let crashRecord = CrashReporter.handleLaunch()
        setupPanel()
        bindSettings()
        NotificationManager.shared.requestAuthorizationIfNeeded()
        _ = Updater.shared        // Sparkle 시작 (백그라운드 자동 체크)
        // 비공식 endpoint 보호 — sleep/wake 동안 폴링 중단해서 깨자마자 폭주 방지.
        vm.registerSleepWakeObservers()
        // 기본 폴링 600s (10분). 자동화 트래픽 신호를 줄이기 위해 5분에서 늘림.
        vm.startPolling()
        // GitHub 기여자 보너스 동기화 — 시작 시 1회 즉시 (다음 폴링 cycle 안 기다리게).
        Task { await ContributorBonus.shared.sync() }
        // PR 기여자 목록 — 24h 캐시라 호출은 사실상 사용자당 1회/일.
        Task { await Contributors.shared.refreshIfNeeded() }
        // 도장 마이그레이션 — Stash/Dependency 소급. Settings.init 안에서 호출하면
        // `BadgeRegistry.evaluate`가 `Settings.shared`를 재진입해 crash.
        Settings.shared.applyGymMigrationIfNeeded()
        // 펫 컬렉션 셋 보너스 마이그레이션 — 기존 사용자가 이미 모은 컬렉션에 회고적 보너스.
        // 같은 재진입 위험으로 init 밖에서 호출.
        Settings.shared.applyCollectionMigrationIfNeeded()
        // PR 보너스 50 → 1,000 상향(v0.6.10) 소급 — 기존 적립 PR에 차액 950 × N 추가.
        Settings.shared.applyContributorBonusUpgradeIfNeeded()
        // 기여 보상 인상 소급 — coin 지급 재개(2,000 × N) + RP 차액(500 × N). 위 마이그레이션과
        // 플래그가 별개라 순서는 무관하지만, 둘 다 coin을 건드리므로 나란히 둔다.
        Settings.shared.applyContributorRewardV2IfNeeded()
        // (실험) 펫 메타데이터 서버 override — flag on일 때만 디스크 캐시 즉시 로드 + 서버 갱신.
        // flag off면 전부 코드 하드코딩 fallback이라 호출조차 안 함.
        if Settings.shared.experimentalRemotePetMeta {
            PetMetaStore.shared.load()
            Task { await PetMetaStore.shared.refresh() }
        }
        // 직전 실행이 비정상 종료였고 회수할 .ips 가 있으면 크래시 신고 다이얼로그.
        // 패널/마이그레이션 다 끝난 뒤 마지막에 — 사용자에겐 "앱이 켜진 직후" 라고 인식되도록.
        if let record = crashRecord {
            presentCrashAlert(record)
        }
        // 패치 공지 — 업데이트 후 첫 실행 시 (직전 본 버전, 현재 버전] 구간 공지를 별도 창으로 표시.
        // fetch는 async라 여기서 블록되지 않음. 크래시 알림(modal) 이후에 둬서 창이 겹치지 않게 한다.
        AnnouncementManager.shared.checkOnLaunch()
        // 사내 인증 유도 — 미인증 사용자에게 하루 1회 인증 팝업(+3,000 coin·RP 보상). 공지와
        // 마찬가지로 async fetch라 여기서 블록되지 않는다. 둘 다 뜨면 인증 창을 중앙에서 살짝
        // 어긋나게 배치해 공지 창과 겹치지 않게 한다(TenantVerifyWindowController.present).
        TenantVerifyPromptManager.shared.checkOnLaunch()
#if DEBUG
        // 로컬 미리보기 — `AIUSAGE_ANNOUNCE_DEMO=1 swift run` 이면 샘플 공지 창을 즉시 띄운다.
        // 번들/Supabase 없는 dev 실행에서도 UI 확인용. 정상 경로엔 영향 없음.
        if ProcessInfo.processInfo.environment["AIUSAGE_ANNOUNCE_DEMO"] != nil {
            AnnouncementManager.shared.presentDemo()
        }
        // 가이드 창 미리보기 — `AIUSAGE_GUIDE_DEMO=1 swift run`. 콘텐츠는 정적이라 dev에서도 동일.
        if ProcessInfo.processInfo.environment["AIUSAGE_GUIDE_DEMO"] != nil {
            GuideWindowController.shared.present()
        }
        // 길드 사무실 씬 미리보기 — `AIUSAGE_OFFICE_DEMO=1 swift run`. 서버 없이 mock 멤버로
        // 배치/애니메이션/충돌 범위를 확인한다.
        if ProcessInfo.processInfo.environment["AIUSAGE_OFFICE_DEMO"] != nil {
            GuildOfficeDemo.present()
        }
#endif
    }

    /// 앱 종료 직전 호출 — kill -9/크래시 시엔 안 불림. 그게 우리가 다음 실행에서 잡고 싶은 경우.
    func applicationWillTerminate(_ notification: Notification) {
        CrashReporter.markCleanShutdown()
    }

    private func presentCrashAlert(_ record: CrashRecord) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let when = df.string(from: record.crashedAt)
        let alert = NSAlert()
        alert.messageText = "지난번 비정상 종료가 감지되었어요"
        alert.informativeText = """
        \(when)에 앱이 크래시 났습니다.
        \(record.signalSummary)

        신고해주시면 같은 문제를 겪는 다른 분들에게도 도움이 됩니다.
        """
        alert.addButton(withTitle: "지금 신고하기")
        alert.addButton(withTitle: "무시하기")
        let response = alert.runModal()
        // 응답과 무관하게 한 번 보여줬으면 같은 .ips 는 다시 묻지 않음.
        CrashReporter.markReported(record.ipsPath)
        if response == .alertFirstButtonReturn {
            let summary = BugReport.CrashSummary(
                crashedAtString: when,
                signalSummary: record.signalSummary,
                ipsFileName: record.ipsPath.lastPathComponent,
                bodyExcerpt: record.bodyExcerpt
            )
            BugReportWindowController.shared.present(crashPrefill: summary)
        }
    }

    private func bindSettings() {
        Settings.shared.$panelOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.panel?.alphaValue = CGFloat(value)
            }
            .store(in: &cancellables)

        // 메뉴바 모드 ON 이면 패널 가시성과 무관하게 항상 status item 표시.
        // (RunCat / iStatMenus 류와 동일한 정주 인디케이터 모델)
        Settings.shared.$showMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.applyMenuBarVisibility(enabled: enabled)
            }
            .store(in: &cancellables)

        // 메뉴바 펫은 자체 30Hz 타이머가 매 tick 마다 vm 값을 직접 읽으므로
        // ViewModel publish 구독은 필요 없음.
    }

    /// showMenuBar 토글 처리. ON: status item + 30Hz 타이머. OFF: 완전 제거.
    private func applyMenuBarVisibility(enabled: Bool) {
        guard enabled else {
            tearDownMenuBarItem()
            return
        }
        if statusItem == nil { setupMenuBarItem() }
        statusItem?.isVisible = true
        if menuBarPetTimer == nil { startMenuBarPetTimer() }
    }

    func presentSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController() }
        settingsWC?.present()
    }

    private func setupPanel() {
        let defaults = AppEnv.defaults
        let savedOriginX = defaults.object(forKey: "panel.x") as? Double
        let savedOriginY = defaults.object(forKey: "panel.y") as? Double
        let savedW = defaults.object(forKey: "panel.w") as? Double ?? 260
        let savedH = defaults.object(forKey: "panel.h") as? Double ?? 180

        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let defaultX = screenFrame.maxX - savedW - 20
        let defaultY = screenFrame.maxY - savedH - 20
        let rect = NSRect(
            x: savedOriginX ?? defaultX,
            y: savedOriginY ?? defaultY,
            width: savedW, height: savedH
        )

        let panel = FloatingPanel(
            contentRect: rect,
            // macOS 15.x에서 `.utilityWindow + .hudWindow` 동시 사용은 NSThemeFrame chrome 결정 모호로
            // 첫 layout pass에서 NSException raise (issue #15). chrome 결정은 `.hudWindow` 하나에 위임.
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.alphaValue = CGFloat(Settings.shared.panelOpacity)

        let root = MainView(
            vm: vm,
            onLogin: { [weak self] in self?.presentLogin() },
            onSettings: { [weak self] in self?.presentSettings() },
            onContributors: { ContributorsWindowController.shared.present() },
            onBugReport: { BugReportWindowController.shared.present() },
            onDailyFortune: { DailyFortuneWindowController.shared.present() },
            onQuit: { NSApp.terminate(nil) }
        )
        // macOS 15.x 에서 NSHostingView 가 zero frame 으로 시작하면 첫 layout pass 의 safe-area
        // invalidation 이 NSWindow theme frame 과 충돌해 NSException raise (issue #15 재발 — 일부
        // macOS 15.3.x 환경). panel content size 와 동일한 frame 으로 시작 + autoresizingMask 로
        // 후속 resize 추종. container/autolayout 불필요.
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: rect.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        NotificationCenter.default.addObserver(
            self, selector: #selector(savePanelFrame),
            name: NSWindow.didMoveNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePanelFrame),
            name: NSWindow.didResizeNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelWillClose),
            name: NSWindow.willCloseNotification, object: panel
        )
        // BoardView의 미참여/일시중지 안내에서 "랭킹 등록…/설정 열기…" 클릭 시 설정 윈도우 띄움.
        NotificationCenter.default.addObserver(
            self, selector: #selector(openRankingSettingsAction),
            name: .openRankingSettings, object: nil
        )

        // 메뉴바 모드에서 close 버튼이 종료가 아닌 hide 로 동작하도록 delegate 설정.
        panel.delegate = self
        panel.orderFrontRegardless()
        vm.panelIsVisible = true
        self.panel = panel
    }

    @objc private func savePanelFrame() {
        guard let p = panel else { return }
        let f = p.frame
        let d = AppEnv.defaults
        d.set(Double(f.origin.x), forKey: "panel.x")
        d.set(Double(f.origin.y), forKey: "panel.y")
        d.set(Double(f.size.width), forKey: "panel.w")
        d.set(Double(f.size.height), forKey: "panel.h")
    }

    @objc private func panelWillClose() {
        // 메뉴바 모드가 아니면 close = 종료 (독/메뉴바 아이콘 없으니 자연스러움).
        // 메뉴바 모드에서는 windowShouldClose 가 false 를 반환해 이 알림이 오지 않는다.
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar status item

    private func setupMenuBarItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageRight   // [text][image] — % 텍스트 좌측, 차트+펫 우측.
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 좌클릭 = 패널 토글, 우클릭 = 메뉴.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        // 타이머 start/stop 은 applyMenuBarVisibility 가 panelIsVisible 에 따라 결정.
    }

    private func tearDownMenuBarItem() {
        stopMenuBarPetTimer()
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        // 메뉴바 모드를 끄는 순간 패널이 숨겨진 상태였으면 진입점을 잃으므로 다시 보여줌.
        if let panel = panel, !panel.isVisible {
            panel.orderFrontRegardless()
            vm.panelIsVisible = true
        }
    }

    // MARK: 메뉴바 펫 애니메이션

    /// 30Hz 타이머. 매 tick 마다 사용량 비례 frame interval 을 계산해서 frame 을 진행.
    private func startMenuBarPetTimer() {
        stopMenuBarPetTimer()
        menuBarRenderer.reset()
        // Swift 6 / macOS 26 런타임에서 Timer block 안의 MainActor.assumeIsolated 는
        // main executor 보장이 없어 SIGSEGV (issue #16). DispatchQueue.main 으로 명시적 hop.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { @MainActor in self?.menuBarPetTick() }
        }
        RunLoop.main.add(t, forMode: .common)
        menuBarPetTimer = t
        menuBarPetTick()   // 즉시 첫 frame 을 그려둠.
    }

    private func stopMenuBarPetTimer() {
        menuBarPetTimer?.invalidate()
        menuBarPetTimer = nil
    }

    /// 30Hz tick. Settings.menuBarPetSource (claude / cursor / codex) 에 따라 데이터 소스가 바뀜.
    /// 30Hz tick. Settings.menuBarPetSource (claude / cursor / codex) 에 따라 데이터 소스가 바뀜.
    /// 그리기·애니메이션 상태는 `MenuBarRenderer`가 들고 있고, 여기선 피드 구성과 이미지 반영만 한다.
    private func menuBarPetTick() {
        guard let button = statusItem?.button else { return }
        // 시각 결과가 직전 tick과 같으면 렌더러가 nil을 돌려준다 — 그땐 재할당도 건너뛴다.
        guard let image = menuBarRenderer.render(feed: currentMenuBarFeed()) else { return }
        button.image = image
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString()
    }

    /// 메뉴바 위젯이 그릴 데이터를 source에 따라 골라 담는다. 렌더러는 출처를 모른다.
    private func currentMenuBarFeed() -> MenuBarRenderer.Feed {
        // 펫은 항상 해당 source 파티의 리더(party[0] = 가장 좌측)로 — kind/variant 모두 리더 기준.
        switch Settings.shared.menuBarPetSource {
        case .claude:
            let leader = Settings.shared.petClaudeParty.first
            let kind = leader?.kind ?? .fox
            let theme = Settings.shared.themeClaudeOverride ?? PetTheme.defaultFor(kind)
            // 현재 5h 창만 — 만료 창이 섞이면 펫이 빈 구간을 가로질러 걷는다.
            let history = ViewModel.claudeFiveHourSeries(Array(vm.claudeHistory.suffix(48)))
            return MenuBarRenderer.Feed(pct: vm.claudeCurrent?.fiveHourPct, history: history,
                               kind: kind, variant: leader?.variant ?? 0, theme: theme)
        case .cursor:
            let leader = Settings.shared.petCursorParty.first
            let kind = leader?.kind ?? .wolf
            let theme = Settings.shared.themeCursorOverride ?? PetTheme.defaultFor(kind)
            // 같은 초 중복 폴 제거 — Claude 피드와 동일 (id: \.0 충돌 방지).
            let history = ViewModel.dedupAdjacentByTime(vm.cursorHistory.suffix(48).compactMap { s in
                Self.cursorPct(s).flatMap { v in v > 0 ? (s.takenAt, v) : nil }
            })
            return MenuBarRenderer.Feed(pct: vm.cursorCurrentPct, history: history,
                               kind: kind, variant: leader?.variant ?? 0, theme: theme)
        case .codex:
            let leader = Settings.shared.petCodexParty.first
            let kind = leader?.kind ?? .fox
            let theme = Settings.shared.themeCodexOverride ?? PetTheme.defaultFor(kind)
            // 현재 주력 창(Plus/Pro=5h, free=monthly)만 — 만료 창이 섞이면 펫이 빈 구간을 걷는다.
            let history = ViewModel.codexPrimarySeries(Array(vm.codexHistory.suffix(48)))
            return MenuBarRenderer.Feed(pct: vm.codexPrimaryPct, history: history,
                               kind: kind, variant: leader?.variant ?? 0, theme: theme)
        }
    }

    /// CursorSnapshot → 사용률 % (Ultra: cents/maxCents, Pro: requests/maxRequests).
    /// `vm.cursorCurrentPct` 와 같은 공식의 per-snapshot 버전.
    private static func cursorPct(_ c: CursorSnapshot) -> Double? {
        if c.plan == .ultra, let cents = c.totalCents, let maxC = c.maxCents, maxC > 0 {
            return cents / maxC * 100
        }
        if let req = c.totalRequests, let maxR = c.maxRequests, maxR > 0 {
            return Double(req) / Double(maxR) * 100
        }
        return nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusMenu(sender)
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            vm.panelIsVisible = false
        } else {
            panel.orderFrontRegardless()
            vm.panelIsVisible = true
        }
    }

    private func showStatusMenu(_ sender: NSStatusBarButton) {
        let menu = NSMenu()
        let toggleTitle = (panel?.isVisible == true) ? "패널 숨기기" : "패널 보기"
        menu.addItem(withTitle: toggleTitle, action: #selector(togglePanelMenuAction), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "설정…", action: #selector(presentSettingsMenuAction), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(quitMenuAction), keyEquivalent: "q")
        for menuItem in menu.items where menuItem.action != nil {
            menuItem.target = self
        }
        // status item button 아래로 메뉴를 띄움.
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: sender.bounds.height + 4),
            in: sender
        )
    }

    @objc private func togglePanelMenuAction() { togglePanel() }
    @objc private func presentSettingsMenuAction() { presentSettings() }
    @objc private func openRankingSettingsAction() { presentSettings() }
    @objc private func quitMenuAction() { NSApp.terminate(nil) }

    // MARK: - NSWindowDelegate

    /// 메뉴바 모드에선 close = hide. 메뉴바가 없으면 기존대로 종료까지 (panelWillClose).
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            if Settings.shared.showMenuBar {
                sender.orderOut(nil)
                vm.panelIsVisible = false
                return false
            }
            return true
        }
    }

    private func presentLogin() {
        if let wc = loginWC {
            wc.showWindow(nil)
            return
        }
        let wc = LoginWindowController()
        wc.onCaptured = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loginWC = nil
                self?.vm.handleClaudeLoggedIn()
            }
        }
        // 로그인 완료 전 닫기(취소) 경로 — 참조를 놓지 않으면 다음 재로그인이 닫힌 창의
        // showWindow로 빠져 무반응이 된다.
        wc.onClosed = { [weak self] in
            MainActor.assumeIsolated { self?.loginWC = nil }
        }
        loginWC = wc
        wc.showWindow(nil)
    }
}
