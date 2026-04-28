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

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPanel()
        bindSettings()
        NotificationManager.shared.requestAuthorizationIfNeeded()
        _ = Updater.shared        // Sparkle 시작 (백그라운드 자동 체크)
        vm.startPolling(interval: 300)
    }

    private func bindSettings() {
        Settings.shared.$panelOpacity
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                self?.panel?.alphaValue = CGFloat(value)
            }
            .store(in: &cancellables)

        // showMenuBar 토글에 따라 status item 생성/철거.
        Settings.shared.$showMenuBar
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.setupMenuBarItem()
                } else {
                    self?.tearDownMenuBarItem()
                }
            }
            .store(in: &cancellables)

        // ViewModel의 % 변경 시 메뉴바 텍스트 갱신.
        Publishers.CombineLatest(vm.$claudeCurrent, vm.$cursorCurrent)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.refreshMenuBarTitle()
            }
            .store(in: &cancellables)
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
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView, .utilityWindow, .hudWindow],
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
            onQuit: { NSApp.terminate(nil) }
        )
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container

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

        // 메뉴바 모드에서 close 버튼이 종료가 아닌 hide 로 동작하도록 delegate 설정.
        panel.delegate = self
        panel.orderFrontRegardless()
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
            button.title = "AIUsage"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 좌클릭 = 패널 토글, 우클릭 = 메뉴.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        refreshMenuBarTitle()
    }

    private func tearDownMenuBarItem() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
        // 메뉴바 모드를 끄는 순간 패널이 숨겨진 상태였으면 진입점을 잃으므로 다시 보여줌.
        if let panel = panel, !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// "Claude 73 · Cursor 42" 형식. 값 없으면 "—". 둘 다 없으면 앱 이름.
    private func refreshMenuBarTitle() {
        guard let button = statusItem?.button else { return }
        func fmt(_ pct: Double?) -> String {
            guard let p = pct else { return "—" }
            return "\(Int(p.rounded()))"
        }
        let c = vm.claudeCurrent?.fiveHourPct
        let u = vm.cursorCurrentPct
        if c == nil, u == nil {
            button.title = "AIUsage"
        } else {
            button.title = "Claude \(fmt(c)) · Cursor \(fmt(u))"
        }
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
        } else {
            panel.orderFrontRegardless()
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
    @objc private func quitMenuAction() { NSApp.terminate(nil) }

    // MARK: - NSWindowDelegate

    /// 메뉴바 모드에선 close = hide. 메뉴바가 없으면 기존대로 종료까지 (panelWillClose).
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            if Settings.shared.showMenuBar {
                sender.orderOut(nil)
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
