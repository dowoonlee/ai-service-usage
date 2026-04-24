import AppKit
import SwiftUI

@main
@MainActor
struct ClaudeUsageApp {
    static func main() {
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
final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    var loginWC: LoginWindowController?
    let vm = ViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupPanel()
        vm.startPolling(interval: 300)
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

        let root = MainView(
            vm: vm,
            onLogin: { [weak self] in self?.presentLogin() },
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
        // close 버튼 눌러도 앱 종료 — 메뉴바/독 아이콘이 없으므로 이게 자연스러움
        NSApp.terminate(nil)
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
