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
    /// 메뉴바 모드 — true 면 패널 close 시 종료 대신 숨김 + 메뉴바에 미니 sparkline + 펫 표시.
    /// 기본 ON. 패널 가시성과 무관하게 메뉴바 item 은 항상 표시 (정주 인디케이터 모델).
    @Published var showMenuBar: Bool {
        didSet { UserDefaults.standard.set(showMenuBar, forKey: Keys.showMenuBar) }
    }
    /// 메뉴바에 표시할 펫의 데이터 출처 (claude or cursor). 기본 .claude.
    @Published var menuBarPetSource: MenuBarPetSource {
        didSet { UserDefaults.standard.set(menuBarPetSource.rawValue, forKey: Keys.menuBarPetSource) }
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
    /// 펫 종별 누적 사용 시간 (초). `petClaudeKind`/`petCursorKind`로 선택된 종에 polling tick마다
    /// 실시간 누적 — 더블카운트 (양쪽 차트가 같은 종이면 1tick에 2배).
    /// 가챠 중복 카운트와 합산되어 `PetOwnership.progressUnits`로 환산, variant 해금 평가에 쓰인다.
    @Published var petUsageSeconds: [PetKind: TimeInterval] {
        didSet { persistPetUsageSeconds() }
    }
    /// 도감에서 강조 표시(NEW! 뱃지 + 노란 테두리)가 필요한 펫 종 집합.
    /// 추가 트리거: 신규 펫 commit / 가챠 중복으로 variant 해금 / 사용 시간으로 variant 해금.
    /// 제거 트리거: 사용자가 그 펫 슬롯을 클릭해 미리보기 진입(아래 `acknowledgeHighlight(_:)` 사용).
    /// 영속화 — 앱 종료 후에도 강조 표시는 사용자가 확인할 때까지 유지.
    @Published var pendingHighlights: Set<PetKind> {
        didSet { persistPendingHighlights() }
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

    // MARK: - 도장 (Gym Badges)
    //
    // 8 카테고리 × 4 tier = 32 뱃지 + 챔피언 1 = 33. 각 카테고리는 별도 카운터/metric을 갖고,
    // `BadgeRegistry.evaluate()`가 polling cycle 끝/사용자 액션 직후 호출되어 새로 임계 통과한
    // 뱃지를 `clearedBadges`에 삽입하고 보너스 코인을 적립한다.

    /// Standup — `dismissWellnessNudge`의 `.rewarded` 결과 시 +1.
    @Published var wellnessRespondedCount: Int {
        didSet { UserDefaults.standard.set(wellnessRespondedCount, forKey: Keys.wellnessRespondedCount) }
    }
    /// Rate Limit — 7d resetAt 변경 직전 pct가 <80%면 +1.
    @Published var rateLimitWeeksPassed: Int {
        didSet { UserDefaults.standard.set(rateLimitWeeksPassed, forKey: Keys.rateLimitWeeksPassed) }
    }
    /// Vibe·Claude — `CoinLedger.evaluateClaude`가 credit한 코인 누적 (5h+7d 합산, plan multiplier 포함).
    @Published var claudeCoinsEarned: Int {
        didSet { UserDefaults.standard.set(claudeCoinsEarned, forKey: Keys.claudeCoinsEarned) }
    }
    /// Vibe·Cursor — `CoinLedger.evaluateCursor`가 credit한 코인 누적.
    @Published var cursorCoinsEarned: Int {
        didSet { UserDefaults.standard.set(cursorCoinsEarned, forKey: Keys.cursorCoinsEarned) }
    }
    /// Heartbeat — 36h grace streak. polling 진입 시 갱신.
    @Published var heartbeatStreak: Int {
        didSet { UserDefaults.standard.set(heartbeatStreak, forKey: Keys.heartbeatStreak) }
    }
    @Published var heartbeatLastActiveAt: Date? {
        didSet { UserDefaults.standard.set(heartbeatLastActiveAt, forKey: Keys.heartbeatLastActiveAt) }
    }
    /// Night Owl — 자정~6시 polling cycle의 sleep length 누적 (초).
    @Published var nightOwlSecondsAccumulated: Int {
        didSet { UserDefaults.standard.set(nightOwlSecondsAccumulated, forKey: Keys.nightOwlSecondsAccumulated) }
    }
    /// 클리어된 뱃지 ID 집합. 형식: `"<category>.<tier>"` (예: `"standup.production"`).
    @Published var clearedBadges: Set<String> {
        didSet { persistClearedBadges() }
    }
    /// 코인 보상이 이미 지급된 뱃지 키 집합. `clearedBadges`와 별개의 second-line dedup —
    /// UserDefaults 손상/멀티 인스턴스 race로 `clearedBadges`가 리셋돼도 코인 재지급은 막는다.
    /// 한 번 들어가면 영구. 도입 시 마이그레이션으로 기존 `clearedBadges` 전체를 포함시켜 소급 보호.
    @Published var creditedBadgeRewards: Set<String> {
        didSet { persistCreditedBadgeRewards() }
    }
    /// 챔피언 뱃지(33번째) 획득 시각. nil = 미획득.
    @Published var championBadgeEarnedAt: Date? {
        didSet { UserDefaults.standard.set(championBadgeEarnedAt, forKey: Keys.championBadgeEarnedAt) }
    }
    /// 도장 페이지에서 reveal 강조용 — 앱 launch 후 아직 사용자가 도장 페이지를 안 열어
    /// migration으로 자동 클리어된 뱃지를 처음 보는 상태인지.
    @Published var hasViewedGymPage: Bool {
        didSet { UserDefaults.standard.set(hasViewedGymPage, forKey: Keys.hasViewedGymPage) }
    }

    // MARK: - GitHub 기여자 보너스

    /// 연결된 GitHub login (예: "youznn"). nil이면 미연결. 토큰은 Keychain에 별도 저장.
    @Published var githubLogin: String? {
        didSet { UserDefaults.standard.set(githubLogin, forKey: Keys.githubLogin) }
    }
    /// 연결된 GitHub user id — login 변경에 안전한 식별자.
    @Published var githubUserID: Int? {
        didSet { UserDefaults.standard.set(githubUserID, forKey: Keys.githubUserID) }
    }
    /// 이미 보너스가 적립된 PR 번호 집합 (dedupe). 한번 들어가면 영구 보존 — 계정 갈아끼워도 재지급 안 됨.
    @Published var creditedPRNumbers: Set<Int> {
        didSet { persistCreditedPRNumbers() }
    }

    private init() {
        let d = UserDefaults.standard
        self.panelOpacity  = (d.object(forKey: Keys.panelOpacity) as? Double) ?? 1.0
        self.notifyEnabled = (d.object(forKey: Keys.notifyEnabled) as? Bool) ?? true
        let storedThresholds = (d.array(forKey: Keys.notifyThresholds) as? [Int]) ?? []
        self.notifyThresholds = storedThresholds.isEmpty ? [80, 95] : storedThresholds.sorted()
        self.showPace      = (d.object(forKey: Keys.showPace) as? Bool) ?? true
        self.showMenuBar   = (d.object(forKey: Keys.showMenuBar) as? Bool) ?? true
        self.menuBarPetSource = (d.string(forKey: Keys.menuBarPetSource).flatMap { MenuBarPetSource(rawValue: $0) }) ?? .claude
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
        let usageData = d.data(forKey: Keys.petUsageSeconds)
        self.petUsageSeconds = (usageData.flatMap { try? JSONDecoder().decode([PetKind: TimeInterval].self, from: $0) }) ?? [:]
        let highlightData = d.data(forKey: Keys.pendingHighlights)
        self.pendingHighlights = (highlightData.flatMap { try? JSONDecoder().decode(Set<PetKind>.self, from: $0) }) ?? []
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

        self.githubLogin = d.string(forKey: Keys.githubLogin)
        self.githubUserID = (d.object(forKey: Keys.githubUserID) as? Int)
        let creditedData = d.data(forKey: Keys.creditedPRNumbers)
        self.creditedPRNumbers = (creditedData.flatMap { try? JSONDecoder().decode(Set<Int>.self, from: $0) }) ?? []

        // 도장 카운터 로드
        self.wellnessRespondedCount = (d.object(forKey: Keys.wellnessRespondedCount) as? Int) ?? 0
        self.rateLimitWeeksPassed   = (d.object(forKey: Keys.rateLimitWeeksPassed) as? Int) ?? 0
        self.claudeCoinsEarned      = (d.object(forKey: Keys.claudeCoinsEarned) as? Int) ?? 0
        self.cursorCoinsEarned      = (d.object(forKey: Keys.cursorCoinsEarned) as? Int) ?? 0
        self.heartbeatStreak        = (d.object(forKey: Keys.heartbeatStreak) as? Int) ?? 0
        self.heartbeatLastActiveAt  = d.object(forKey: Keys.heartbeatLastActiveAt) as? Date
        self.nightOwlSecondsAccumulated = (d.object(forKey: Keys.nightOwlSecondsAccumulated) as? Int) ?? 0
        let clearedData = d.data(forKey: Keys.clearedBadges)
        let loadedClearedBadges: Set<String> = (clearedData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        self.clearedBadges = loadedClearedBadges
        // creditedBadgeRewards 로드 — 키가 없으면 기존 clearedBadges로 백필 (이미 보상 받았다고 간주).
        let creditedRewardsData = d.data(forKey: Keys.creditedBadgeRewards)
        if let decoded = creditedRewardsData.flatMap({ try? JSONDecoder().decode(Set<String>.self, from: $0) }) {
            self.creditedBadgeRewards = decoded
        } else {
            self.creditedBadgeRewards = loadedClearedBadges
            if let data = try? JSONEncoder().encode(loadedClearedBadges) {
                d.set(data, forKey: Keys.creditedBadgeRewards)
            }
        }
        self.championBadgeEarnedAt = d.object(forKey: Keys.championBadgeEarnedAt) as? Date
        self.hasViewedGymPage      = (d.object(forKey: Keys.hasViewedGymPage) as? Bool) ?? false

        // 신규 사용자 / 기존 사용자 모두 최종 가챠권 3장이 되도록 두 단계로 처리:
        //   1) 신규 사용자 (hasCompletedGachaMigration 아직 false): 첫 실행 시 3장 지급
        //   2) 기존 사용자 (이미 1장 받고 마이그레이션 완료): v0.3.2 보너스 블록에서 +2장
        // wasExistingUser는 1번 블록이 hasCompletedGachaMigration을 true로 토글하기 전의 값으로,
        // 신규 유저가 1번에서 3장 받은 다음 2번 블록에서 또 +2장 받는 이중 지급을 방지.
        let wasExistingUser = d.bool(forKey: Keys.hasCompletedGachaMigration)

        // (1) 첫 실행 시 1회만: 가챠권 3장 지급 + 기존 사용 중이던 펫이 있으면 보유 목록에 등록.
        //
        // 등급 가드: legacy default petKind가 Legendary/Epic이면 마이그레이션으로 무료 등록하지
        // 않는다 — 사용자는 가챠로 뽑아야 함. (`Gacha.isLegendaryOrEpic`가 권위 있는 검사.)
        // 이론상 legacy default(.fox, .wolf)는 모두 Common이라 현재 가드는 no-op이지만,
        // 향후 default 값이 바뀌거나 사용자가 settings UI에서 상위 등급을 선택해뒀다면 보호된다.
        if !d.bool(forKey: Keys.hasCompletedGachaMigration) {
            var owned = self.ownedPets
            if hadLegacyClaudeKind, owned[self.petClaudeKind] == nil,
               !Gacha.isLegendaryOrEpic(self.petClaudeKind) {
                owned[self.petClaudeKind] = .initial()
            }
            if hadLegacyCursorKind, !Gacha.isLegendaryOrEpic(self.petCursorKind) {
                if owned[self.petCursorKind] == nil {
                    owned[self.petCursorKind] = .initial()
                } else {
                    owned[self.petCursorKind]!.count += 1
                }
            }
            self.ownedPets = owned
            self.gachaTickets = 3
            // didSet은 init 중엔 트리거되지 않으므로 직접 persist.
            persistOwnedPets()
            d.set(3, forKey: Keys.gachaTickets)
            d.set(true, forKey: Keys.hasCompletedGachaMigration)
        }

        // (2) 1회성 보너스 마이그레이션 — 신규 보너스를 추가하려면 아래 패턴으로 한 줄씩 늘리면 됨.
        //
        //   applyOnceMigration(key: <UserDefaults flag>, onlyExisting: <Bool>,
        //                      wasExistingUser: wasExistingUser) {
        //       <gachaTickets/coins 등 갱신>
        //       <UserDefaults persist>
        //   }
        //
        // - `key`        — UserDefaults Bool flag. 첫 발동 후 true 로 마킹되어 재실행 안 됨.
        // - `onlyExisting=true` → 신규 사용자(첫 실행)는 스킵. (1)에서 이미 새 기본값을 받았으므로
        //   이중 지급 방지. v0.3.2처럼 "기존 사용자 평준화" 의도일 때 사용.
        // - `onlyExisting=false` → 모든 사용자에게 일괄 적용 (예: 일회성 무료 코인 지급 캠페인 등).
        applyOnceMigration(key: Keys.hasReceivedV032TicketBonus,
                           onlyExisting: true,
                           wasExistingUser: wasExistingUser) {
            self.gachaTickets += 2
            d.set(self.gachaTickets, forKey: Keys.gachaTickets)
        }

        // 도장 마이그레이션은 init 안에서 호출 금지 — `BadgeRegistry.evaluate`가 `Settings.shared`를
        // 재진입해서 lazy init이 깨짐. App 시작 후 `applyGymMigrationIfNeeded()`에서 처리.
    }

    /// 도장 (Gym Badges) 마이그레이션 — Stash·Dependency만 소급, 나머지 6 카테고리는 0부터.
    /// `Settings.shared` 초기화가 끝난 뒤 App 시작 훅(`applicationDidFinishLaunching`)에서 1회 호출.
    func applyGymMigrationIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Keys.hasMigratedGymBadges) else { return }
        BadgeRegistry.evaluate(silent: true)
        d.set(true, forKey: Keys.hasMigratedGymBadges)
    }

    /// UserDefaults `key` 가 false 인 동안만 1회 `apply` 실행 후 true 로 마킹.
    /// `onlyExisting=true` 면 `wasExistingUser` 가 false 인 신규 사용자에 대해서는 스킵하지만
    /// flag 는 true 로 마킹해 재실행 안 함 (= "이 사용자는 이 보너스 처리됨" 으로 본다).
    /// 한 번만 발동해야 하는 보너스/조정/마이그레이션 추가 시 재사용.
    private func applyOnceMigration(
        key: String,
        onlyExisting: Bool,
        wasExistingUser: Bool,
        _ apply: () -> Void
    ) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: key) else { return }
        if !onlyExisting || wasExistingUser {
            apply()
        }
        d.set(true, forKey: key)
    }

    private func persistOwnedPets() {
        if let data = try? JSONEncoder().encode(ownedPets) {
            UserDefaults.standard.set(data, forKey: Keys.ownedPets)
        }
    }

    private func persistPetUsageSeconds() {
        if let data = try? JSONEncoder().encode(petUsageSeconds) {
            UserDefaults.standard.set(data, forKey: Keys.petUsageSeconds)
        }
    }

    private func persistPendingHighlights() {
        if let data = try? JSONEncoder().encode(pendingHighlights) {
            UserDefaults.standard.set(data, forKey: Keys.pendingHighlights)
        }
    }

    private func persistCreditedPRNumbers() {
        if let data = try? JSONEncoder().encode(creditedPRNumbers) {
            UserDefaults.standard.set(data, forKey: Keys.creditedPRNumbers)
        }
    }

    private func persistClearedBadges() {
        if let data = try? JSONEncoder().encode(clearedBadges) {
            UserDefaults.standard.set(data, forKey: Keys.clearedBadges)
        }
    }

    private func persistCreditedBadgeRewards() {
        if let data = try? JSONEncoder().encode(creditedBadgeRewards) {
            UserDefaults.standard.set(data, forKey: Keys.creditedBadgeRewards)
        }
    }

    /// GitHub 연결 해제 — 토큰 폐기 + identity 클리어. creditedPRNumbers는 의도적으로 유지
    /// (재연결 시 같은 PR로 중복 지급 방지).
    func disconnectGitHub() {
        Keychain.clearGitHubToken()
        ContributorBonus.shared.updateToken(nil)
        githubLogin = nil
        githubUserID = nil
    }

    /// 도감 슬롯 클릭 시 호출 — 그 펫의 강조 표시 해제. 비어있으면 no-op.
    func acknowledgeHighlight(_ kind: PetKind) {
        if pendingHighlights.contains(kind) {
            pendingHighlights.remove(kind)
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
        static let menuBarPetSource = "settings.menuBarPetSource"
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
        static let petUsageSeconds             = "settings.petUsageSeconds"
        static let pendingHighlights           = "settings.pendingHighlights"
        static let hasReceivedV032TicketBonus  = "settings.hasReceivedV032TicketBonus"
        // GitHub 기여자 보너스
        static let githubLogin                 = "settings.githubLogin"
        static let githubUserID                = "settings.githubUserID"
        static let creditedPRNumbers           = "settings.creditedPRNumbers"
        // 도장 (Gym Badges)
        static let wellnessRespondedCount      = "settings.wellnessRespondedCount"
        static let rateLimitWeeksPassed        = "settings.rateLimitWeeksPassed"
        static let claudeCoinsEarned           = "settings.claudeCoinsEarned"
        static let cursorCoinsEarned           = "settings.cursorCoinsEarned"
        static let heartbeatStreak             = "settings.heartbeatStreak"
        static let heartbeatLastActiveAt       = "settings.heartbeatLastActiveAt"
        static let nightOwlSecondsAccumulated  = "settings.nightOwlSecondsAccumulated"
        static let clearedBadges               = "settings.clearedBadges"
        static let creditedBadgeRewards        = "settings.creditedBadgeRewards"
        static let championBadgeEarnedAt       = "settings.championBadgeEarnedAt"
        static let hasViewedGymPage            = "settings.hasViewedGymPage"
        static let hasMigratedGymBadges        = "settings.hasMigratedGymBadges"
    }
}

/// 메뉴바 위젯이 어느 데이터 출처(Claude / Cursor)의 펫과 사용률을 표시할지.
enum MenuBarPetSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude
    case cursor

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        }
    }
}
