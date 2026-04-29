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
    /// 마지막으로 본 Claude 5h/7d 윈도우의 resetAt. 같은 resetAt 안에서 pct delta로 적립.
    @Published var lastClaudeFiveHourReset: Date? {
        didSet { UserDefaults.standard.set(lastClaudeFiveHourReset, forKey: Keys.lastClaudeFiveHourReset) }
    }
    @Published var lastClaudeSevenDayReset: Date? {
        didSet { UserDefaults.standard.set(lastClaudeSevenDayReset, forKey: Keys.lastClaudeSevenDayReset) }
    }
    /// 같은 윈도우 안에서 마지막으로 본 사용률 — 다음 폴링과의 delta 적립용.
    @Published var lastClaudeFiveHourPctSeen: Double? {
        didSet { UserDefaults.standard.set(lastClaudeFiveHourPctSeen, forKey: Keys.lastClaudeFiveHourPctSeen) }
    }
    @Published var lastClaudeSevenDayPctSeen: Double? {
        didSet { UserDefaults.standard.set(lastClaudeSevenDayPctSeen, forKey: Keys.lastClaudeSevenDayPctSeen) }
    }
    /// 정수 절단으로 코인이 새지 않도록 폴링마다의 소수부를 누적해서 carry.
    /// (예: 0.835 coin/poll × 60 polls 가 50 coin로 누적되도록)
    @Published var claudeFiveHourCoinFraction: Double {
        didSet { UserDefaults.standard.set(claudeFiveHourCoinFraction, forKey: Keys.claudeFiveHourCoinFraction) }
    }
    @Published var claudeSevenDayCoinFraction: Double {
        didSet { UserDefaults.standard.set(claudeSevenDayCoinFraction, forKey: Keys.claudeSevenDayCoinFraction) }
    }
    @Published var cursorCoinFraction: Double {
        didSet { UserDefaults.standard.set(cursorCoinFraction, forKey: Keys.cursorCoinFraction) }
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
        self.lastClaudeFiveHourPctSeen = d.object(forKey: Keys.lastClaudeFiveHourPctSeen) as? Double
        self.lastClaudeSevenDayPctSeen = d.object(forKey: Keys.lastClaudeSevenDayPctSeen) as? Double
        self.claudeFiveHourCoinFraction = (d.object(forKey: Keys.claudeFiveHourCoinFraction) as? Double) ?? 0
        self.claudeSevenDayCoinFraction = (d.object(forKey: Keys.claudeSevenDayCoinFraction) as? Double) ?? 0
        self.cursorCoinFraction = (d.object(forKey: Keys.cursorCoinFraction) as? Double) ?? 0
        self.lastCursorEventCredited = d.object(forKey: Keys.lastCursorEventCredited) as? Date
        self.coinsTotalEarned = (d.object(forKey: Keys.coinsTotalEarned) as? Int) ?? 0
        self.firstCreditedAt = d.object(forKey: Keys.firstCreditedAt) as? Date

        // 첫 실행 시 1회만: 가챠권 1장 지급 + 기존 사용 중이던 펫이 있으면 보유 목록에 등록.
        //
        // ⚠ 주의: 향후 새 legendary 펫을 추가할 때 그 종이 이전 빌드의 default petClaudeKind/
        // petCursorKind에 들어가지 않도록 주의해야 한다. 만약 사용자가 그 값으로 골라뒀다면
        // 이 마이그레이션이 등급 검사 없이 `.initial()`로 등록 → legendary 무료 지급.
        // 현재 NinjaFrog는 이번 PR에서 처음 도입돼 사용자가 보유할 수 없으므로 안전하지만,
        // 미래 추가 시 등급 화이트리스트(common/rare만 마이그레이션) 또는 legendary 제외가 필요.
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
        static let lastClaudeFiveHourPctSeen   = "settings.lastClaudeFiveHourPctSeen"
        static let lastClaudeSevenDayPctSeen   = "settings.lastClaudeSevenDayPctSeen"
        static let claudeFiveHourCoinFraction  = "settings.claudeFiveHourCoinFraction"
        static let claudeSevenDayCoinFraction  = "settings.claudeSevenDayCoinFraction"
        static let cursorCoinFraction          = "settings.cursorCoinFraction"
        static let hasCompletedGachaMigration  = "settings.hasCompletedGachaMigration"
        static let coinsTotalEarned            = "settings.coinsTotalEarned"
        static let firstCreditedAt             = "settings.firstCreditedAt"
    }
}
