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
    @Published var notifyThresholds: [Int] {
        didSet { UserDefaults.standard.set(notifyThresholds, forKey: Keys.notifyThresholds) }
    }
    @Published var showPace: Bool {
        didSet { UserDefaults.standard.set(showPace, forKey: Keys.showPace) }
    }
    /// 메뉴바 status item 표시 여부. true면 메뉴바에 "Claude 73 · Cursor 42" 형태로 노출,
    /// 패널 close 시 종료 대신 숨김으로 동작 (메뉴바 클릭으로 다시 표시).
    @Published var showMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: Keys.showMenuBar) }
    }
    @Published var petClaudeEnabled: Bool {
        didSet { UserDefaults.standard.set(petClaudeEnabled, forKey: Keys.petClaudeEnabled) }
    }
    @Published var petCursorEnabled: Bool {
        didSet { UserDefaults.standard.set(petCursorEnabled, forKey: Keys.petCursorEnabled) }
    }
    @Published var petClaudeKind: PetKind {
        didSet { UserDefaults.standard.set(petClaudeKind.rawValue, forKey: Keys.petClaudeKind) }
    }
    @Published var petCursorKind: PetKind {
        didSet { UserDefaults.standard.set(petCursorKind.rawValue, forKey: Keys.petCursorKind) }
    }
    /// nil = 펫 기본 테마 사용
    @Published var themeClaudeOverride: PetTheme? {
        didSet { UserDefaults.standard.set(themeClaudeOverride?.rawValue, forKey: Keys.themeClaudeOverride) }
    }
    @Published var themeCursorOverride: PetTheme? {
        didSet { UserDefaults.standard.set(themeCursorOverride?.rawValue, forKey: Keys.themeCursorOverride) }
    }
    @Published private(set) var launchAtLogin: Bool

    private init() {
        let d = UserDefaults.standard
        self.panelOpacity  = (d.object(forKey: Keys.panelOpacity) as? Double) ?? 1.0
        self.notifyEnabled = (d.object(forKey: Keys.notifyEnabled) as? Bool) ?? true
        let storedThresholds = (d.array(forKey: Keys.notifyThresholds) as? [Int]) ?? []
        self.notifyThresholds = storedThresholds.isEmpty ? [80, 95] : storedThresholds.sorted()
        self.showPace      = (d.object(forKey: Keys.showPace) as? Bool) ?? true
        self.showMenuBar   = (d.object(forKey: Keys.showMenuBar) as? Bool) ?? false
        self.petClaudeEnabled = (d.object(forKey: Keys.petClaudeEnabled) as? Bool) ?? true
        self.petCursorEnabled = (d.object(forKey: Keys.petCursorEnabled) as? Bool) ?? true
        self.petClaudeKind = (d.string(forKey: Keys.petClaudeKind).flatMap { PetKind(rawValue: $0) }) ?? .fox
        self.petCursorKind = (d.string(forKey: Keys.petCursorKind).flatMap { PetKind(rawValue: $0) }) ?? .wolf
        self.themeClaudeOverride = d.string(forKey: Keys.themeClaudeOverride).flatMap { PetTheme(rawValue: $0) }
        self.themeCursorOverride = d.string(forKey: Keys.themeCursorOverride).flatMap { PetTheme(rawValue: $0) }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func addThreshold(_ value: Int) {
        let v = max(1, min(200, value))
        if !notifyThresholds.contains(v) {
            notifyThresholds = (notifyThresholds + [v]).sorted()
        }
    }

    func removeThreshold(_ value: Int) {
        notifyThresholds.removeAll { $0 == value }
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
        static let panelOpacity     = "settings.panelOpacity"
        static let notifyEnabled    = "settings.notifyEnabled"
        static let notifyThresholds = "settings.notifyThresholds"
        static let showPace         = "settings.showPace"
        static let showMenuBar      = "settings.showMenuBar"
        static let petClaudeEnabled = "settings.petClaudeEnabled"
        static let petCursorEnabled = "settings.petCursorEnabled"
        static let petClaudeKind    = "settings.petClaudeKind"
        static let petCursorKind    = "settings.petCursorKind"
        static let themeClaudeOverride = "settings.themeClaudeOverride"
        static let themeCursorOverride = "settings.themeCursorOverride"
    }
}
