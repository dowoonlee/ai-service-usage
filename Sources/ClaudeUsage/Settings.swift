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

    /// 펫이 차트 위에서 휴식 권유 말풍선을 띄울지 여부.
    @Published var wellnessEnabled: Bool {
        didSet { UserDefaults.standard.set(wellnessEnabled, forKey: Keys.wellnessEnabled) }
    }
    /// 휴식 권유 말풍선 사이의 최소 간격(분). 이 시간 동안 사용자가 활동했어야 트리거.
    @Published var wellnessIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(wellnessIntervalMinutes, forKey: Keys.wellnessIntervalMinutes) }
    }
    /// 차트 한 구간의 |dy|가 전체 y-range 대비 이 비율 이상이면 펫이 AAAH/WHEE 말풍선을 띄움.
    /// 낮을수록 자주 발생, 높을수록 드물게 발생. 기본 0.40.
    @Published var bigDropThreshold: Double {
        didSet { UserDefaults.standard.set(bigDropThreshold, forKey: Keys.bigDropThreshold) }
    }

    // MARK: - Gacha (M2)

    /// 가챠 화폐 잔액. CoinLedger가 사용량 기반으로 적립.
    @Published var coins: Int {
        didSet { UserDefaults.standard.set(coins, forKey: Keys.coins) }
    }
    /// 무료 가챠권 잔여 매수. 첫 실행 시 1장 지급.
    @Published var gachaTickets: Int {
        didSet { UserDefaults.standard.set(gachaTickets, forKey: Keys.gachaTickets) }
    }
    /// 펫 종별 보유 상태 (count + unlockedVariants).
    @Published var ownedPets: [PetKind: PetOwnership] {
        didSet { persistOwnedPets() }
    }
    /// 차트에 활성화된 펫의 variant index (0 = 기본, 1/2/3 = shiny).
    /// kind는 기존 petClaudeKind/petCursorKind를 그대로 사용.
    @Published var petClaudeVariant: Int {
        didSet { UserDefaults.standard.set(petClaudeVariant, forKey: Keys.petClaudeVariant) }
    }
    @Published var petCursorVariant: Int {
        didSet { UserDefaults.standard.set(petCursorVariant, forKey: Keys.petCursorVariant) }
    }
    /// CoinLedger가 5h/7d 윈도우 리셋 적립 중복 방지용으로 마지막 적립 시각 기록.
    @Published var lastClaudeFiveHourReset: Date? {
        didSet { UserDefaults.standard.set(lastClaudeFiveHourReset, forKey: Keys.lastClaudeFiveHourReset) }
    }
    @Published var lastClaudeSevenDayReset: Date? {
        didSet { UserDefaults.standard.set(lastClaudeSevenDayReset, forKey: Keys.lastClaudeSevenDayReset) }
    }
    /// CoinLedger가 처리한 마지막 Cursor 이벤트 timestamp (그 이후만 적립 대상).
    @Published var lastCursorEventCredited: Date? {
        didSet { UserDefaults.standard.set(lastCursorEventCredited, forKey: Keys.lastCursorEventCredited) }
    }
    /// 누적 적립한 코인 총량 (소비 무시). 평균 일일 적립 계산용.
    @Published var coinsTotalEarned: Int {
        didSet { UserDefaults.standard.set(coinsTotalEarned, forKey: Keys.coinsTotalEarned) }
    }
    /// 첫 적립 시각. 평균 일일 적립의 분모(경과 일수) 계산.
    @Published var firstCreditedAt: Date? {
        didSet { UserDefaults.standard.set(firstCreditedAt, forKey: Keys.firstCreditedAt) }
    }

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
        self.wellnessEnabled = (d.object(forKey: Keys.wellnessEnabled) as? Bool) ?? true
        let storedWellness = (d.object(forKey: Keys.wellnessIntervalMinutes) as? Int) ?? 60
        self.wellnessIntervalMinutes = max(10, min(240, storedWellness))
        let storedBigDrop = (d.object(forKey: Keys.bigDropThreshold) as? Double) ?? 0.40
        self.bigDropThreshold = max(0.10, min(0.80, storedBigDrop))

        // Gacha 필드 로드
        // 마이그레이션 판정용으로 legacy 키 존재 여부를 init 안에서 미리 캡처.
        let hadLegacyClaudeKind = d.string(forKey: Keys.petClaudeKind) != nil
        let hadLegacyCursorKind = d.string(forKey: Keys.petCursorKind) != nil
        self.coins = (d.object(forKey: Keys.coins) as? Int) ?? 0
        self.gachaTickets = (d.object(forKey: Keys.gachaTickets) as? Int) ?? 0
        let ownedData = d.data(forKey: Keys.ownedPets)
        self.ownedPets = (ownedData.flatMap { try? JSONDecoder().decode([PetKind: PetOwnership].self, from: $0) }) ?? [:]
        self.petClaudeVariant = (d.object(forKey: Keys.petClaudeVariant) as? Int) ?? 0
        self.petCursorVariant = (d.object(forKey: Keys.petCursorVariant) as? Int) ?? 0
        self.lastClaudeFiveHourReset = d.object(forKey: Keys.lastClaudeFiveHourReset) as? Date
        self.lastClaudeSevenDayReset = d.object(forKey: Keys.lastClaudeSevenDayReset) as? Date
        self.lastCursorEventCredited = d.object(forKey: Keys.lastCursorEventCredited) as? Date
        self.coinsTotalEarned = (d.object(forKey: Keys.coinsTotalEarned) as? Int) ?? 0
        self.firstCreditedAt = d.object(forKey: Keys.firstCreditedAt) as? Date

        // 첫 실행 시 1회만: 가챠권 1장 지급 + 기존 사용 중이던 펫이 있으면 보유 목록에 등록.
        if !d.bool(forKey: Keys.hasCompletedGachaMigration) {
            var owned = self.ownedPets
            if hadLegacyClaudeKind, owned[self.petClaudeKind] == nil {
                owned[self.petClaudeKind] = .initial()
            }
            if hadLegacyCursorKind {
                if owned[self.petCursorKind] == nil {
                    owned[self.petCursorKind] = .initial()
                } else {
                    owned[self.petCursorKind]!.count += 1
                }
            }
            self.ownedPets = owned
            self.gachaTickets = 1
            // didSet은 init 중엔 트리거되지 않으므로 직접 persist.
            persistOwnedPets()
            d.set(1, forKey: Keys.gachaTickets)
            d.set(true, forKey: Keys.hasCompletedGachaMigration)
        }
    }

    private func persistOwnedPets() {
        if let data = try? JSONEncoder().encode(ownedPets) {
            UserDefaults.standard.set(data, forKey: Keys.ownedPets)
        }
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
        static let wellnessEnabled = "settings.wellnessEnabled"
        static let wellnessIntervalMinutes = "settings.wellnessIntervalMinutes"
        static let bigDropThreshold = "settings.bigDropThreshold"
        // Gacha (M2)
        static let coins                       = "settings.coins"
        static let gachaTickets                = "settings.gachaTickets"
        static let ownedPets                   = "settings.ownedPets"
        static let petClaudeVariant            = "settings.petClaudeVariant"
        static let petCursorVariant            = "settings.petCursorVariant"
        static let lastClaudeFiveHourReset     = "settings.lastClaudeFiveHourReset"
        static let lastClaudeSevenDayReset     = "settings.lastClaudeSevenDayReset"
        static let lastCursorEventCredited     = "settings.lastCursorEventCredited"
        static let hasCompletedGachaMigration  = "settings.hasCompletedGachaMigration"
        static let coinsTotalEarned            = "settings.coinsTotalEarned"
        static let firstCreditedAt             = "settings.firstCreditedAt"
    }
}
