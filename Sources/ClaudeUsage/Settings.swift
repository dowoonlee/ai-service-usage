import Foundation
import Combine
import ServiceManagement

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    @Published var panelOpacity: Double {
        didSet { UserDefaults.standard.set(panelOpacity, forKey: Keys.panelOpacity) }
    }
    @Published var notifyEnabled: Bool {
        didSet { UserDefaults.standard.set(notifyEnabled, forKey: Keys.notifyEnabled) }
    }
    @Published var notifyAt80: Bool {
        didSet { UserDefaults.standard.set(notifyAt80, forKey: Keys.notifyAt80) }
    }
    @Published var notifyAt95: Bool {
        didSet { UserDefaults.standard.set(notifyAt95, forKey: Keys.notifyAt95) }
    }
    @Published var showPace: Bool {
        didSet { UserDefaults.standard.set(showPace, forKey: Keys.showPace) }
    }
    @Published private(set) var launchAtLogin: Bool

    private init() {
        let d = UserDefaults.standard
        self.panelOpacity  = (d.object(forKey: Keys.panelOpacity) as? Double) ?? 1.0
        self.notifyEnabled = (d.object(forKey: Keys.notifyEnabled) as? Bool) ?? true
        self.notifyAt80    = (d.object(forKey: Keys.notifyAt80) as? Bool) ?? true
        self.notifyAt95    = (d.object(forKey: Keys.notifyAt95) as? Bool) ?? true
        self.showPace      = (d.object(forKey: Keys.showPace) as? Bool) ?? true
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let status = SMAppService.mainApp.status
            if enabled, status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            DebugLog.log("LaunchAtLogin failed: \(error.localizedDescription)")
        }
        // 실제 시스템 상태로 동기화 (실패 시 토글 원복)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    enum Keys {
        static let panelOpacity  = "settings.panelOpacity"
        static let notifyEnabled = "settings.notifyEnabled"
        static let notifyAt80    = "settings.notifyAt80"
        static let notifyAt95    = "settings.notifyAt95"
        static let showPace      = "settings.showPace"
    }
}
