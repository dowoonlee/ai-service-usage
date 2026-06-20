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
    private var menuBarFrameIdx: Int = 0
    private var menuBarFrameAccum: TimeInterval = 0
    private var menuBarLastTick: Date = Date()
    /// 펫의 차트 위 정규화 위치 (0..1). 좌→우 진행 후 반전, 다시 우→좌. 핑퐁.
    private var menuBarPetX: Double = 0
    private var menuBarPetDir: Double = 1
    /// 뒹굴 회전 누적 — big drop 통과 중에만 가속, 빠져나오면 즉시 0.
    private var menuBarRollAngle: Double = 0
    /// 직전 tick에 그린 composite의 시각적 키. 모두 동일하면 NSImage 생성/할당 skip.
    /// 사용률 0% 같은 idle 구간에서 frameIdx·petX bucket·pct·rollAngle bucket이 동시에 동결되면
    /// 시각 결과가 완전히 같음 — 30Hz redraw 비용(NSImage + Core Graphics 합성) 무피해 절감.
    /// petX bucket=100단위(1% ≈ 0.6pt at chartW=60), rollAngle bucket=5°.
    private var lastMenuBarRenderKey: MenuBarRenderKey?
    private struct MenuBarRenderKey: Equatable {
        let frameIdx: Int
        let petXBucket: Int       // 0..100
        let petDir: Int           // +1 / -1
        let pctBucket: Int        // -1 if nil, else 0..100
        let rollBucket: Int       // angle / 5
        let kind: PetKind
        let theme: PetTheme
        let action: PetController.Action
        let historyCount: Int     // history 끝부분이 push되면 변화 감지
    }

    /// [% 영역 (좌하단 정렬)][차트+펫] 한 장 image — button.title 안 씀.
    /// baseline 정밀 제어 위해 button.attributedTitle 대신 NSImage 에 텍스트 직접 그림.
    private let menuBarPctW:    CGFloat = 26
    private let menuBarChartW:  CGFloat = 60
    private let menuBarCanvasH: CGFloat = 20
    private let menuBarPetH:    CGFloat = 14
    /// 펫이 chart 좌→우 한 번 지나가는 데 걸리는 초.
    private let menuBarTraversalSec: Double = 18.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 디버그 로그 회전 — 5MB 초과 시 .bak으로 rename. 다른 컴포넌트의 첫 log 호출
        // 이전에 회전해야 새 사이클의 로그가 깨끗한 파일에서 시작.
        DebugLog.rotateIfNeeded()
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
        let defaults = UserDefaults.standard
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
        let d = UserDefaults.standard
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
        menuBarLastTick = Date()
        menuBarFrameAccum = 0
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

    /// 30Hz tick. Settings.menuBarPetSource (claude / cursor) 에 따라 데이터 소스가 바뀜.
    private func menuBarPetTick() {
        guard let button = statusItem?.button else { return }

        let now = Date()
        let dt = now.timeIntervalSince(menuBarLastTick)
        menuBarLastTick = now

        let feed = currentMenuBarFeed()
        let pct = max(0, min(100, feed.pct ?? 0))

        // FPS: 6~24, 사용률 비례
        let fps = 6.0 + (pct / 100.0) * 18.0
        let frameInterval = 1.0 / fps
        menuBarFrameAccum += dt
        if menuBarFrameAccum >= frameInterval {
            menuBarFrameAccum = 0
            menuBarFrameIdx &+= 1
        }

        // 펫 위치 핑퐁. 사용률 높을수록 traversal 빨라짐.
        let speedMul = 1.0 + (pct / 100.0) * 0.8
        menuBarPetX += menuBarPetDir * (dt * speedMul / menuBarTraversalSec)
        if menuBarPetX >= 1 { menuBarPetX = 1; menuBarPetDir = -1 }
        if menuBarPetX <= 0 { menuBarPetX = 0; menuBarPetDir = 1 }

        // bigDrop 검사 — render 와 동일한 inset 기준의 chart-relative xFrac.
        let (cw, ch) = feed.kind.cellSize
        let aspect = CGFloat(cw) / CGFloat(ch)
        let petWApprox = menuBarPetH * aspect
        let petXPx = petWApprox / 2 + (menuBarChartW - petWApprox) * CGFloat(menuBarPetX)
        let chartXFrac = Double(petXPx / menuBarChartW)
        let bigDrop = bigDropAt(xFrac: chartXFrac, dir: menuBarPetDir, points: feed.history)
        menuBarRollAngle = bigDrop ? menuBarRollAngle + dt * 720 : 0

        let action: PetController.Action = pct >= 60 ? .run : .walk

        // 시각 결과를 결정하는 모든 입력을 양자화한 키. 직전 tick과 동일하면 NSImage 합성 skip.
        let key = MenuBarRenderKey(
            frameIdx: menuBarFrameIdx,
            petXBucket: Int(menuBarPetX * 100),
            petDir: menuBarPetDir > 0 ? 1 : -1,
            pctBucket: feed.pct.map { Int($0) } ?? -1,
            rollBucket: Int(menuBarRollAngle / 5),
            kind: feed.kind,
            theme: feed.theme,
            action: action,
            historyCount: feed.history.count
        )
        if key == lastMenuBarRenderKey { return }
        lastMenuBarRenderKey = key

        button.image = renderMenuBarComposite(
            kind: feed.kind,
            action: action,
            frameIdx: menuBarFrameIdx,
            history: feed.history,
            theme: feed.theme,
            petXNorm: menuBarPetX,
            facingRight: menuBarPetDir > 0,
            rollAngle: menuBarRollAngle,
            pct: feed.pct
        )
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString()
    }

    /// 메뉴바 위젯이 사용할 (pct, history, kind, theme) 패키지. source 에 따라 분기.
    private struct MenuBarFeed {
        let pct: Double?
        let history: [(Date, Double)]
        let kind: PetKind
        let theme: PetTheme
    }
    private func currentMenuBarFeed() -> MenuBarFeed {
        switch Settings.shared.menuBarPetSource {
        case .claude:
            let kind = Settings.shared.petClaudeKind
            let theme = Settings.shared.themeClaudeOverride ?? PetTheme.defaultFor(kind)
            // 현재 5h 창만 — 만료 창이 섞이면 펫이 빈 구간을 가로질러 걷는다.
            let history = ViewModel.claudeFiveHourSeries(Array(vm.claudeHistory.suffix(48)))
            return MenuBarFeed(pct: vm.claudeCurrent?.fiveHourPct, history: history, kind: kind, theme: theme)
        case .cursor:
            let kind = Settings.shared.petCursorKind
            let theme = Settings.shared.themeCursorOverride ?? PetTheme.defaultFor(kind)
            // 같은 초 중복 폴 제거 — Claude 피드와 동일 (id: \.0 충돌 방지).
            let history = ViewModel.dedupAdjacentByTime(vm.cursorHistory.suffix(48).compactMap { s in
                Self.cursorPct(s).flatMap { v in v > 0 ? (s.takenAt, v) : nil }
            })
            return MenuBarFeed(pct: vm.cursorCurrentPct, history: history, kind: kind, theme: theme)
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

    /// 펫이 현재 위치한 segment 가 "big drop" 인지 + 진행 방향이 내려가는 쪽인지.
    /// in-app `bigDropDescent` 의 메뉴바 단순화 버전.
    /// `xFrac` 은 inset 적용된 chart-relative 위치 (0..1).
    private func bigDropAt(xFrac: Double, dir: Double, points: [(Date, Double)]) -> Bool {
        guard points.count >= 2 else { return false }
        let ys = points.map(\.1)
        let yrange = max((ys.max() ?? 0) - (ys.min() ?? 0), 1)
        let n = points.count
        let f = Double(n - 1) * xFrac
        let i0 = max(0, min(n - 2, Int(f.rounded(.down))))
        let dy = points[i0 + 1].1 - points[i0].1
        guard abs(dy) >= 0.40 * yrange else { return false }
        // dy < 0: 우측이 더 낮음 → +방향(우향) 진행 시 내려감 → roll
        // dy > 0: 우측이 더 높음 → -방향(좌향) 진행 시 내려감 → roll
        return (dy < 0 && dir > 0) || (dy > 0 && dir < 0)
    }

    /// 컴포지트: [좌하단 baseline 정렬 % | gradient backdrop + 라인 + 라인 위 펫].
    /// y 축은 visible window 의 min/max 정규화 — 윈도우 안 최댓값이 항상 천장.
    private func renderMenuBarComposite(
        kind: PetKind,
        action: PetController.Action,
        frameIdx: Int,
        history: [(Date, Double)],
        theme: PetTheme,
        petXNorm: Double,
        facingRight: Bool,
        rollAngle: Double,
        pct: Double?
    ) -> NSImage {
        let totalW = menuBarPctW + menuBarChartW
        let H = menuBarCanvasH
        let canvas = NSImage(size: NSSize(width: totalW, height: H))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .none

        // 좌측 % 영역 — baseline = 1pt (하단 정렬), 우측 정렬 (차트 라인과 붙도록).
        drawMenuBarPctText(in: NSRect(x: 0, y: 0, width: menuBarPctW, height: H), pct: pct)

        // 차트 영역은 우측. 펫 좌표계 등 모두 chart-local origin 기준이므로 ctx translate.
        let pad: CGFloat = 2
        let plotMinY = pad
        let plotMaxY = H - pad
        let W = menuBarChartW
        if let outerCtx = NSGraphicsContext.current?.cgContext {
            outerCtx.saveGState()
            outerCtx.translateBy(x: menuBarPctW, y: 0)
            defer { outerCtx.restoreGState() }
            drawChartAndPet(W: W, H: H, plotMinY: plotMinY, plotMaxY: plotMaxY,
                            history: history, theme: theme, kind: kind, action: action,
                            frameIdx: frameIdx, petXNorm: petXNorm, facingRight: facingRight,
                            rollAngle: rollAngle)
        }

        canvas.isTemplate = false
        return canvas
    }

    /// % 텍스트를 영역 우하단(baseline=1)에 그림. 숫자/% 동일 baseline.
    private func drawMenuBarPctText(in rect: NSRect, pct: Double?) {
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let pctFont = NSFont.systemFont(ofSize: 8, weight: .regular)

        let baseColor: NSColor
        let numStr: String
        var alpha: CGFloat = 1.0

        if let p = pct {
            let i = max(0, min(100, Int(p.rounded())))
            numStr = "\(i)"
            switch i {
            case 90...:   baseColor = .systemRed
            case 60..<90: baseColor = .systemOrange
            case 30..<60: baseColor = .systemGreen
            default:      baseColor = .secondaryLabelColor
            }
            if i >= 90 {
                let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                alpha = 0.6 + 0.4 * (0.5 + 0.5 * sin(phase * 2 * .pi))
            }
        } else {
            numStr = "—"
            baseColor = .secondaryLabelColor
        }

        let numAttr = NSAttributedString(string: numStr, attributes: [
            .font: numFont,
            .foregroundColor: baseColor.withAlphaComponent(alpha),
        ])
        let pctAttr = NSAttributedString(string: "%", attributes: [
            .font: pctFont,
            .foregroundColor: baseColor.withAlphaComponent(alpha * 0.65),
        ])

        let numSize = numAttr.size()
        let pctSize = pctAttr.size()
        let totalW = numSize.width + 1 + pctSize.width
        // 우측 정렬 (차트 라인과 붙음): 영역 우측 끝에서 1pt 안쪽.
        let baselineX = rect.maxX - 1 - totalW
        // 하단 정렬: descender 여유 1pt.
        let baselineY: CGFloat = 1
        numAttr.draw(at: NSPoint(x: baselineX, y: baselineY))
        pctAttr.draw(at: NSPoint(x: baselineX + numSize.width + 1, y: baselineY))
    }

    /// 차트 + 펫 부분만 그리는 헬퍼 (origin 은 호출 측이 translate 로 맞춰줌).
    private func drawChartAndPet(
        W: CGFloat, H: CGFloat, plotMinY: CGFloat, plotMaxY: CGFloat,
        history: [(Date, Double)], theme: PetTheme, kind: PetKind,
        action: PetController.Action, frameIdx: Int,
        petXNorm: Double, facingRight: Bool, rollAngle: Double
    ) {

        // 1) gradient backdrop (라인 아래 영역) — 데이터가 있을 때만 색감 입힘.
        // y 축은 visible window 의 min/max 로 정규화 (가장 큰 값이 천장).
        let pts = history
        let toY: (Double) -> CGFloat
        if pts.count >= 2 {
            let ys = pts.map(\.1)
            let ymin = ys.min() ?? 0
            let ymax = max(ys.max() ?? 1, ymin + 1)
            toY = { v in
                let t = (v - ymin) / (ymax - ymin)
                return plotMinY + CGFloat(t) * (plotMaxY - plotMinY)
            }
        } else {
            toY = { _ in H / 2 }
        }
        if pts.count >= 2, let ctx = NSGraphicsContext.current?.cgContext {
            let n = pts.count
            // gradient fill polygon: 라인 점들 + 우하단 + 좌하단
            let fillPath = CGMutablePath()
            fillPath.move(to: CGPoint(x: 0, y: 0))
            for i in 0..<n {
                let x = W * CGFloat(i) / CGFloat(n - 1)
                fillPath.addLine(to: CGPoint(x: x, y: toY(pts[i].1)))
            }
            fillPath.addLine(to: CGPoint(x: W, y: 0))
            fillPath.closeSubpath()

            let top = nsColor(for: theme, slot: .top).withAlphaComponent(0.18)
            let bot = nsColor(for: theme, slot: .bottom).withAlphaComponent(0.40)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let grad = CGGradient(colorsSpace: cs,
                                     colors: [top.cgColor, bot.cgColor] as CFArray,
                                     locations: [0.0, 1.0]) {
                ctx.saveGState()
                ctx.addPath(fillPath)
                ctx.clip()
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: H),
                                       end:   CGPoint(x: 0, y: 0),
                                       options: [])
                ctx.restoreGState()
            }

            // 2) 부드러운 라인 (Catmull-Rom → Bezier 변환)
            let linePts = (0..<n).map { i -> CGPoint in
                let x = W * CGFloat(i) / CGFloat(n - 1)
                return CGPoint(x: x, y: toY(pts[i].1))
            }
            let smooth = catmullRomPath(points: linePts)
            ctx.saveGState()
            ctx.setStrokeColor(nsColor(for: theme, slot: .line).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(smooth)
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: H / 2))
            path.line(to: NSPoint(x: W, y: H / 2))
            path.lineWidth = 1
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            path.stroke()
        }

        // 3) 펫 — 라인 위 (xNorm → 실제 x 매핑 시 양 끝에서 잘리지 않도록 안쪽으로 inset)
        if let frame = PetSprite.image(for: kind, action: action, frameIndex: frameIdx) {
            let (cw, ch) = kind.cellSize
            let aspect = CGFloat(cw) / CGFloat(ch)
            let petH = menuBarPetH
            let petW = petH * aspect
            // 펫 중심이 [petW/2, W - petW/2] 안에 머물도록 매핑 — 좌/우 끝에서 sprite 잘림 방지.
            let xPx = petW / 2 + (W - petW) * CGFloat(petXNorm)
            // 라인 y 도 같은 실제 x 기준 + 동일한 절대 0~100 toY 함수로 보간.
            let yPx: CGFloat
            if pts.count >= 2 {
                let n = pts.count
                let xFrac = Double(xPx / W)
                let f = Double(n - 1) * xFrac
                let i0 = max(0, min(n - 2, Int(f.rounded(.down))))
                let frac = f - Double(i0)
                let v = pts[i0].1 + (pts[i0 + 1].1 - pts[i0].1) * frac
                yPx = toY(v)
            } else {
                yPx = H / 2
            }
            // 발이 라인 위에 닿도록 펫 중심을 라인 + petH/2 - 살짝 올림
            let cy = yPx + petH / 2 - 1

            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: xPx, y: cy)
                // sprite default direction 과 진행 방향이 다르면 가로 flip
                let needFlip = (kind.defaultFacingLeft && facingRight) || (!kind.defaultFacingLeft && !facingRight)
                if needFlip { ctx.scaleBy(x: -1, y: 1) }
                if rollAngle != 0 { ctx.rotate(by: -rollAngle * .pi / 180) }
                let drawRect = NSRect(x: -petW / 2, y: -petH / 2, width: petW, height: petH)
                frame.draw(in: drawRect,
                           from: NSRect(origin: .zero, size: frame.size),
                           operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
            }
        }
    }

    /// PetTheme HSB 값을 NSColor 로 직접 (SwiftUI Color → NSColor 변환 우회).
    private enum ThemeSlot { case line, top, bottom }
    private func nsColor(for theme: PetTheme, slot: ThemeSlot) -> NSColor {
        switch (theme, slot) {
        case (.grassland, .line):   return NSColor(hue: 0.30, saturation: 0.70, brightness: 0.45, alpha: 1)
        case (.grassland, .top):    return NSColor(hue: 0.30, saturation: 0.40, brightness: 0.55, alpha: 1)
        case (.grassland, .bottom): return NSColor(hue: 0.30, saturation: 0.50, brightness: 0.40, alpha: 1)
        case (.field, .line):       return NSColor(hue: 0.13, saturation: 0.65, brightness: 0.50, alpha: 1)
        case (.field, .top):        return NSColor(hue: 0.20, saturation: 0.35, brightness: 0.55, alpha: 1)
        case (.field, .bottom):     return NSColor(hue: 0.13, saturation: 0.45, brightness: 0.45, alpha: 1)
        case (.wilderness, .line):  return NSColor(hue: 0.07, saturation: 0.65, brightness: 0.45, alpha: 1)
        case (.wilderness, .top):   return NSColor(hue: 0.10, saturation: 0.30, brightness: 0.50, alpha: 1)
        case (.wilderness, .bottom):return NSColor(hue: 0.07, saturation: 0.45, brightness: 0.40, alpha: 1)
        case (.sea, .line):         return NSColor(hue: 0.58, saturation: 0.75, brightness: 0.55, alpha: 1)
        case (.sea, .top):          return NSColor(hue: 0.58, saturation: 0.40, brightness: 0.60, alpha: 1)
        case (.sea, .bottom):       return NSColor(hue: 0.60, saturation: 0.55, brightness: 0.40, alpha: 1)
        }
    }

    /// 점들을 Catmull-Rom 으로 잇는 부드러운 CGPath. tension 0.5 (Centripetal-ish).
    private func catmullRomPath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        if points.count == 2 { path.addLine(to: points[1]); return path }
        for i in 0..<(points.count - 1) {
            let p0 = i == 0 ? points[i] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
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
        loginWC = wc
        wc.showWindow(nil)
    }
}
