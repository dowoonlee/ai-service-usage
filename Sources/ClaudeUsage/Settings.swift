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
    @Published var petCodexEnabled: Bool {
        didSet { UserDefaults.standard.set(petCodexEnabled, forKey: Keys.petCodexEnabled) }
    }
    /// (실험) 펫 메타데이터(이름/대사/설명)를 서버에서 받아 코드값 위에 override. 기본 off.
    /// off / 네트워크 실패 / 누락 kind 면 코드 하드코딩 fallback. 켜는 순간 즉시 서버 갱신.
    @Published var experimentalRemotePetMeta: Bool {
        didSet {
            UserDefaults.standard.set(experimentalRemotePetMeta, forKey: Keys.experimentalRemotePetMeta)
            if experimentalRemotePetMeta && !oldValue {
                Task { await PetMetaStore.shared.refresh() }
            }
        }
    }
    /// 패치 공지 표시 여부 — 업데이트 후 첫 실행 시 별도 창. 기본 on. 시작 시 팝업이라 끌 수 있게 노출.
    @Published var patchNotesEnabled: Bool {
        didSet { UserDefaults.standard.set(patchNotesEnabled, forKey: Keys.patchNotesEnabled) }
    }
    /// 마지막으로 패치 공지를 확인한 버전(CFBundleShortVersionString). nil이면 신규 설치 →
    /// 첫 실행에서 현재 버전으로 seed만 하고 공지는 안 띄운다. `AnnouncementManager` 참조.
    @Published var lastSeenAnnouncementVersion: String? {
        didSet { UserDefaults.standard.set(lastSeenAnnouncementVersion, forKey: Keys.lastSeenAnnouncementVersion) }
    }
    /// 한 차트 파티 최대 마리 수.
    static let maxPartySize = 3

    /// 재사용 파티 프리셋 라이브러리 + 소스별 할당. cf. docs/DESIGN_PET_PARTY.md
    /// 멀티 산책 + 코스메틱의 source of truth. 아래 `petClaudeParty` 등은 "할당된 프리셋의 members"를
    /// 미러하는 computed라 기존 소비자(MainView/ViewModel/App)와 레거시 단수 참조(`petClaudeKind`)는
    /// 무변경으로 동작한다.
    @Published var partyPresets: [PartyPreset] {
        didSet { persist(partyPresets, forKey: Keys.partyPresets) }
    }
    /// 각 데이터소스에 할당된 프리셋 id.
    @Published var claudePresetID: UUID {
        didSet { UserDefaults.standard.set(claudePresetID.uuidString, forKey: Keys.claudePresetID) }
    }
    @Published var cursorPresetID: UUID {
        didSet { UserDefaults.standard.set(cursorPresetID.uuidString, forKey: Keys.cursorPresetID) }
    }
    @Published var codexPresetID: UUID {
        didSet { UserDefaults.standard.set(codexPresetID.uuidString, forKey: Keys.codexPresetID) }
    }

    /// 무료로 만들 수 있는 파티 프리셋 기본 개수. 이 이상은 코인으로 슬롯을 사서 늘린다.
    static let basePartyPresetLimit = 3
    /// 코인으로 구매한 추가 프리셋 슬롯 수 (영속). 삭제해도 슬롯은 유지된다.
    @Published var purchasedPartyPresetSlots: Int {
        didSet { UserDefaults.standard.set(purchasedPartyPresetSlots, forKey: Keys.purchasedPartyPresetSlots) }
    }
    /// 현재 만들 수 있는 프리셋 최대 개수 (기본 + 구매 슬롯).
    var maxPartyPresets: Int { Self.basePartyPresetLimit + purchasedPartyPresetSlots }
    /// 다음 슬롯 구매 비용 — 2000부터 구매할 때마다 +1000.
    var nextPartyPresetSlotCost: Int { 2000 + 1000 * purchasedPartyPresetSlots }

    /// 소스에 할당된 프리셋의 members 미러 (get/set). set은 할당 프리셋을 편집 → 공유 시 함께 반영.
    var petClaudeParty: [PetSelection] {
        get { preset(for: claudePresetID)?.members ?? [] }
        set { setPresetMembers(claudePresetID, newValue) }
    }
    var petCursorParty: [PetSelection] {
        get { preset(for: cursorPresetID)?.members ?? [] }
        set { setPresetMembers(cursorPresetID, newValue) }
    }
    var petCodexParty: [PetSelection] {
        get { preset(for: codexPresetID)?.members ?? [] }
        set { setPresetMembers(codexPresetID, newValue) }
    }

    /// 리더(party[0]) 미러 — 레거시 단수 참조 호환. set은 리더 kind 교체로 라우팅.
    var petClaudeKind: PetKind {
        get { petClaudeParty.first?.kind ?? .fox }
        set { setPartyLeader(source: .claude, kind: newValue) }
    }
    var petCursorKind: PetKind {
        get { petCursorParty.first?.kind ?? .wolf }
        set { setPartyLeader(source: .cursor, kind: newValue) }
    }
    /// Codex 차트 리더(party[0]) 미러 — get-only. 펫 차트 테마(`PetTheme.defaultFor`)용.
    /// party 편집은 PartyView/SettingsView가 petCodexParty를 직접 갱신한다.
    var petCodexKind: PetKind {
        petCodexParty.first?.kind ?? .fox
    }
    /// nil = 펫 기본 테마 사용
    @Published var themeClaudeOverride: PetTheme? {
        didSet { UserDefaults.standard.set(themeClaudeOverride?.rawValue, forKey: Keys.themeClaudeOverride) }
    }
    @Published var themeCursorOverride: PetTheme? {
        didSet { UserDefaults.standard.set(themeCursorOverride?.rawValue, forKey: Keys.themeCursorOverride) }
    }
    @Published var themeCodexOverride: PetTheme? {
        didSet { UserDefaults.standard.set(themeCodexOverride?.rawValue, forKey: Keys.themeCodexOverride) }
    }
    /// 코인 구매로 unlock한 동적 맵(테마) 인벤토리. PetTheme.rawValue 보관 (정적 4종은 무료라 미포함).
    @Published var ownedThemes: Set<String> {
        didSet { persist(ownedThemes, forKey: Keys.ownedThemes) }
    }
    /// 테마가 잠금 해제됐는지 — 무료(정적)거나 구매 보유한 동적 테마.
    func isThemeUnlocked(_ t: PetTheme) -> Bool {
        t.isFree || ownedThemes.contains(t.rawValue)
    }
    /// 도감(GachaView 상점 탭)에서 접힌 섹션. Rarity.rawValue("mythic"…) + "collections".
    /// 빈 Set = 전부 펼침(기본, 현행 동작 보존).
    @Published var gachaInventoryCollapsed: Set<String> {
        didSet { persist(gachaInventoryCollapsed, forKey: Keys.gachaInventoryCollapsed) }
    }
    @Published private(set) var launchAtLogin: Bool

    /// 차트 한 구간의 |dy|가 전체 y-range 대비 이 비율 이상이면 펫이 AAAH/WHEE 말풍선을 띄움.
    /// 낮을수록 자주 발생, 높을수록 드물게 발생. 기본 0.40.
    @Published var bigDropThreshold: Double {
        didSet { UserDefaults.standard.set(bigDropThreshold, forKey: Keys.bigDropThreshold) }
    }

    // MARK: - 날씨 이펙트

    /// 메인 패널에 실제 날씨(비/눈/뇌우) 파티클을 표시할지. 기본 ON.
    @Published var weatherEffectEnabled: Bool {
        didSet { UserDefaults.standard.set(weatherEffectEnabled, forKey: Keys.weatherEffectEnabled) }
    }
    /// 날씨를 가져올 기준 위치 (고정 2곳). 기본 U타워(정자). IP/위치권한 없이 고정 좌표 사용.
    @Published var weatherLocation: WeatherLocation {
        didSet { UserDefaults.standard.set(weatherLocation.rawValue, forKey: Keys.weatherLocation) }
    }

    // MARK: - Gacha (M2)

    /// 가챠 화폐 잔액. CoinLedger가 사용량 기반으로 적립.
    @Published var coins: Int {
        didSet { UserDefaults.standard.set(coins, forKey: Keys.coins); recordIntegrityChecksum() }
    }
    /// 무료 가챠권 잔여 매수. 첫 실행 시 1장 지급.
    @Published var gachaTickets: Int {
        didSet { UserDefaults.standard.set(gachaTickets, forKey: Keys.gachaTickets); recordIntegrityChecksum() }
    }
    /// RP 프리미엄 가챠권 보유 수 — `[mythic+legendary]` 제한 풀 1뽑용. RP로만 구매(코인/일반티켓과 별개).
    @Published var premiumTickets: Int {
        didSet { UserDefaults.standard.set(premiumTickets, forKey: Keys.premiumTickets); recordIntegrityChecksum() }
    }
    /// 길드 생성권 보유 수 — 코인 구매 소모품 (`CoinLedger.purchaseGuildPermit`). 서버
    /// guild-create 성공 응답 후 GuildView가 1 차감. 해체 후 재창설에도 새 생성권 필요.
    @Published var guildPermits: Int {
        didSet { UserDefaults.standard.set(guildPermits, forKey: Keys.guildPermits); recordIntegrityChecksum() }
    }
    /// 펫 종별 보유 상태 (count + unlockedVariants).
    @Published var ownedPets: [PetKind: PetOwnership] {
        didSet { persist(ownedPets, forKey: Keys.ownedPets); recordIntegrityChecksum() }
    }
    /// [무결성 가드 — 탐지 전용] 로컬 plist가 앱 외부에서(`defaults write` 등) 조작된 흔적이
    /// 감지되면 true. 데이터는 절대 수정하지 않으며, 랭킹 제출 시 서버 abuse_flags로 보고하는
    /// 데만 쓴다. 한 번 켜지면 영속 — 정상 사용자는 didSet이 항상 체크섬을 갱신하므로 켜지지
    /// 않는다. 계산은 `IntegrityGuard` 참조.
    @Published var integrityViolation: Bool {
        didSet { UserDefaults.standard.set(integrityViolation, forKey: Keys.integrityViolation) }
    }
    /// 펫 종별 누적 사용 시간 (초). `petClaudeKind`/`petCursorKind`로 선택된 종에 polling tick마다
    /// 실시간 누적 — 더블카운트 (양쪽 차트가 같은 종이면 1tick에 2배).
    /// 가챠 중복 카운트와 합산되어 `PetOwnership.progressUnits`로 환산, variant 해금 평가에 쓰인다.
    @Published var petUsageSeconds: [PetKind: TimeInterval] {
        didSet { persist(petUsageSeconds, forKey: Keys.petUsageSeconds) }
    }

    // MARK: - RP / 코스메틱 경제 (랭킹 순위 보상 → WalkingCat 이펙트). cf. docs/DESIGN_RP_ECONOMY.md

    /// RP(Rank Point) 잔액. 랭킹 순위 보상으로만 적립(coins와 수급처 분리), 이펙트 구매로 소비.
    /// `RankPointLedger` 경유로만 변경 — 직접 mutate 금지 (CoinLedger와 동일 규약).
    @Published var rp: Int {
        didSet { UserDefaults.standard.set(rp, forKey: Keys.rp) }
    }
    /// 이로치 조각 잔액. 만렙(variant 3) 펫의 오버플로우로만 적립, Prestige(홀로 이로치) 해금에만 소비.
    /// `ShardLedger` 경유로만 변경 (CoinLedger/RankPointLedger와 동일 규약).
    @Published var shinyShards: Int {
        didSet { UserDefaults.standard.set(shinyShards, forKey: Keys.shinyShards) }
    }
    /// 누적 적립 RP (소비 무시). 통계용.
    @Published var rpTotalEarned: Int {
        didSet { UserDefaults.standard.set(rpTotalEarned, forKey: Keys.rpTotalEarned) }
    }
    /// PetKind별 **보유** 이펙트 (구매한 것). variant/이로치와 무관 — 종 단위 귀속.
    @Published var petEffects: [PetKind: Set<EffectKind>] {
        didSet { persist(petEffects, forKey: Keys.petEffects) }
    }
    /// PetKind별 **장착(활성)** 이펙트. `petEffects`(보유)의 부분집합 — 실제로 펫에 렌더되는 건 이것.
    /// 칩 토글로 켜고 끈다. 구매 시 자동 장착.
    @Published var equippedEffects: [PetKind: Set<EffectKind>] {
        didSet { persist(equippedEffects, forKey: Keys.equippedEffects) }
    }

    /// 도감에서 강조 표시(NEW! 뱃지 + 노란 테두리)가 필요한 펫 종 집합.
    /// 추가 트리거: 신규 펫 commit / 가챠 중복으로 variant 해금 / 사용 시간으로 variant 해금.
    /// 제거 트리거: 사용자가 그 펫 슬롯을 클릭해 미리보기 진입(아래 `acknowledgeHighlight(_:)` 사용).
    /// 영속화 — 앱 종료 후에도 강조 표시는 사용자가 확인할 때까지 유지.
    @Published var pendingHighlights: Set<PetKind> {
        didSet { persist(pendingHighlights, forKey: Keys.pendingHighlights) }
    }
    /// 리더(party[0]) variant 미러 — 레거시 단수 참조 호환. kind와 함께 party가 source of truth.
    var petClaudeVariant: Int {
        get { petClaudeParty.first?.variant ?? 0 }
        set { setPartyLeader(source: .claude, variant: newValue) }
    }
    var petCursorVariant: Int {
        get { petCursorParty.first?.variant ?? 0 }
        set { setPartyLeader(source: .cursor, variant: newValue) }
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
    // Codex 5h/7d/monthly 윈도우 적립용 — Claude와 동일한 (resetAt, pctSeen) state machine.
    // monthly는 free 전용 단일 창(Plus/Pro는 5h/7d만 옴). Claude/Cursor Free와 형평을 맞추려고
    // monthly도 적립 대상에 포함 → monthly state machine을 별도로 둔다.
    @Published var lastCodexFiveHourReset: Date? {
        didSet { UserDefaults.standard.set(lastCodexFiveHourReset, forKey: Keys.lastCodexFiveHourReset) }
    }
    @Published var lastCodexSevenDayReset: Date? {
        didSet { UserDefaults.standard.set(lastCodexSevenDayReset, forKey: Keys.lastCodexSevenDayReset) }
    }
    @Published var lastCodexMonthlyReset: Date? {
        didSet { UserDefaults.standard.set(lastCodexMonthlyReset, forKey: Keys.lastCodexMonthlyReset) }
    }
    @Published var lastCodexFiveHourPctSeen: Double? {
        didSet { UserDefaults.standard.set(lastCodexFiveHourPctSeen, forKey: Keys.lastCodexFiveHourPctSeen) }
    }
    @Published var lastCodexSevenDayPctSeen: Double? {
        didSet { UserDefaults.standard.set(lastCodexSevenDayPctSeen, forKey: Keys.lastCodexSevenDayPctSeen) }
    }
    @Published var lastCodexMonthlyPctSeen: Double? {
        didSet { UserDefaults.standard.set(lastCodexMonthlyPctSeen, forKey: Keys.lastCodexMonthlyPctSeen) }
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
    @Published var codexFiveHourCoinFraction: Double {
        didSet { UserDefaults.standard.set(codexFiveHourCoinFraction, forKey: Keys.codexFiveHourCoinFraction) }
    }
    @Published var codexSevenDayCoinFraction: Double {
        didSet { UserDefaults.standard.set(codexSevenDayCoinFraction, forKey: Keys.codexSevenDayCoinFraction) }
    }
    @Published var codexMonthlyCoinFraction: Double {
        didSet { UserDefaults.standard.set(codexMonthlyCoinFraction, forKey: Keys.codexMonthlyCoinFraction) }
    }
    /// CoinLedger가 처리한 마지막 Cursor 이벤트 timestamp (그 이후만 적립 대상).
    @Published var lastCursorEventCredited: Date? {
        didSet { UserDefaults.standard.set(lastCursorEventCredited, forKey: Keys.lastCursorEventCredited) }
    }
    /// 누적 적립한 코인 총량 (소비 무시). 평균 일일 적립 계산용.
    @Published var coinsTotalEarned: Int {
        didSet { UserDefaults.standard.set(coinsTotalEarned, forKey: Keys.coinsTotalEarned); recordIntegrityChecksum() }
    }
    /// 첫 적립 시각. 평균 일일 적립의 분모(경과 일수) 계산.
    @Published var firstCreditedAt: Date? {
        didSet { UserDefaults.standard.set(firstCreditedAt, forKey: Keys.firstCreditedAt) }
    }
    /// Wellness nudge 마지막 표시 시각. 1시간 쿨다운이 앱 재실행 가로질러 유지되도록 영구화 (#11).
    @Published var lastWellnessShownAt: Date? {
        didSet { UserDefaults.standard.set(lastWellnessShownAt, forKey: Keys.lastWellnessShownAt) }
    }

    /// 오늘의 개발 운세 윈도우를 마지막으로 연 날짜. topBar 의 빨간 dot 배지 표시 여부 결정.
    /// 실제 운세 캐시는 Supabase `daily_fortunes` 에 — 여기엔 dot 배지 dedup 용 마지막 표시일자만.
    @Published var dailyFortuneLastShownDate: Date? {
        didSet { UserDefaults.standard.set(dailyFortuneLastShownDate, forKey: Keys.dailyFortuneLastShownDate) }
    }
    /// 오늘의 AI 뉴스 퀴즈를 마지막으로 푼 날짜 — topBar dot(오늘 미완료 표시)용 로컬 캐시.
    /// 실제 제출 상태의 source-of-truth는 서버(daily_quiz_submissions); 이 값은 dot 즉시 반영용.
    @Published var dailyQuizLastSolvedDate: Date? {
        didSet { UserDefaults.standard.set(dailyQuizLastSolvedDate, forKey: Keys.dailyQuizLastSolvedDate) }
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
    @Published var codexCoinsEarned: Int {
        didSet { UserDefaults.standard.set(codexCoinsEarned, forKey: Keys.codexCoinsEarned) }
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
    /// 사용량 스트릭 — 실제 usage 이벤트가 발생한 연속 일수. StreakLedger가 그날 첫 이벤트에 갱신.
    /// Heartbeat(폴링 생존)와 달리 실제 사용량이 있어야만 오르므로 조작 불가.
    @Published var usageStreak: Int {
        didSet { UserDefaults.standard.set(usageStreak, forKey: Keys.usageStreak) }
    }
    /// 사용량 스트릭 판정 기준일 — 마지막으로 usage가 인정된 날. 같은 날 재발동 방지 + 연속성 판정.
    @Published var usageStreakLastDay: Date? {
        didSet { UserDefaults.standard.set(usageStreakLastDay, forKey: Keys.usageStreakLastDay) }
    }
    /// 클리어된 뱃지 ID 집합. 형식: `"<category>.<tier>"` (예: `"standup.production"`).
    @Published var clearedBadges: Set<String> {
        didSet { persist(clearedBadges, forKey: Keys.clearedBadges) }
    }
    /// 코인 보상이 이미 지급된 뱃지 키 집합. `clearedBadges`와 별개의 second-line dedup —
    /// UserDefaults 손상/멀티 인스턴스 race로 `clearedBadges`가 리셋돼도 코인 재지급은 막는다.
    /// 한 번 들어가면 영구. 도입 시 마이그레이션으로 기존 `clearedBadges` 전체를 포함시켜 소급 보호.
    @Published var creditedBadgeRewards: Set<String> {
        didSet { persist(creditedBadgeRewards, forKey: Keys.creditedBadgeRewards) }
    }
    /// 마스터한 지역(BadgeRegion.rawValue)의 집합. 한 지역의 모든 도장 클리어 시 1회 프리미엄
    /// 가챠권 지급 — dedup용. 한 번 들어가면 영구. (clearedBadges/completedCollections와 동일 패턴.)
    @Published var masteredRegions: Set<String> {
        didSet { persist(masteredRegions, forKey: Keys.masteredRegions) }
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
    /// 인앱 사용 가이드를 아직 안 본 상태인지 — 안 봤으면 가이드 아이콘에 알림 점 표시.
    /// 기본 false라 신규/기존 사용자 모두 처음 한 번은 배지가 뜨고, 가이드를 열면 해제된다.
    @Published var hasViewedGuide: Bool {
        didSet { UserDefaults.standard.set(hasViewedGuide, forKey: Keys.hasViewedGuide) }
    }
    /// "Buy me a coffee" 답례 보상(5,000 coin · 2,000 RP)을 1회 수령했는지.
    @Published var hasReceivedCoffeeReward: Bool {
        didSet { UserDefaults.standard.set(hasReceivedCoffeeReward, forKey: Keys.hasReceivedCoffeeReward) }
    }
    /// 마지막 leaderboard 폴링에서 받은 현재 소속 테넌트 slug("public"=미인증). 사내 인증 유도
    /// 자동 팝업(`TenantVerifyPromptManager`)이 시작 시점에 미인증 여부를 판단하는 캐시.
    @Published var currentTenant: String? {
        didSet { UserDefaults.standard.set(currentTenant, forKey: Keys.currentTenant) }
    }
    /// 사내 인증 유도 팝업을 마지막으로 띄운 시각. 하루 1회로 억제(24h 경과 시 재표시).
    @Published var lastTenantPromptAt: Date? {
        didSet { UserDefaults.standard.set(lastTenantPromptAt, forKey: Keys.lastTenantPromptAt) }
    }
    /// 사내 인증 유도 캠페인(v0.16.2) coin 3,000 보너스를 1회 수령했는지. RP는 서버 rp_rewards가 담당.
    @Published var hasReceivedTenantVerifyBonus: Bool {
        didSet { UserDefaults.standard.set(hasReceivedTenantVerifyBonus, forKey: Keys.hasReceivedTenantVerifyBonus) }
    }
    /// 사내 인증 유도 자동 팝업을 '다시 보지 않기'로 껐는지. true면 팝업은 영구 중단되고, 이후엔
    /// 랭킹 헤더의 '사내 인증 🎁' 버튼으로만 인증 진입할 수 있다.
    @Published var tenantPromptOptedOut: Bool {
        didSet { UserDefaults.standard.set(tenantPromptOptedOut, forKey: Keys.tenantPromptOptedOut) }
    }

    // MARK: - 펫 컬렉션 (셋 보너스)
    //
    // 한 컬렉션의 base 펫(variant 0)을 모두 모으면 1회성 코인 보너스 + 도감 업적 섹션에
    // 영구 등재. 평가는 `Gacha.commit(_:)` 직후 `PetCollectionRegistry.evaluate()`가 수행.
    //
    // dedup은 `completedCollections`(rawValue Set) — `BadgeRegistry`의 `clearedBadges`와
    // 동일 패턴. 한 번 들어가면 ownedPets가 어떤 이유로 비워져도 재지급 안 됨.

    /// 컴플리트된 컬렉션의 `PetCollection.rawValue` Set. 보너스 재지급 방지 dedup.
    @Published var completedCollections: Set<String> {
        didSet { persist(completedCollections, forKey: Keys.completedCollections) }
    }
    /// 각 컬렉션의 컴플리트 시각 — 도감 업적 섹션의 "획득 일자" 표시용.
    @Published var collectionCompletedAt: [String: Date] {
        didSet { persist(collectionCompletedAt, forKey: Keys.collectionCompletedAt) }
    }
    /// 가장 최근에 컴플리트된 컬렉션의 rawValue — 가챠 hatched 화면이 컴플리트 배너를
    /// 띄우고 nil로 소비. UI가 한 번만 읽고 비우는 단발성 플래그.
    @Published var pendingCollectionCelebration: String? {
        didSet { UserDefaults.standard.set(pendingCollectionCelebration, forKey: Keys.pendingCollectionCelebration) }
    }
    /// 새로 컴플리트된 컬렉션 강조 — `pendingHighlights`(펫 슬롯)와 동일 패턴.
    /// 사용자가 뱃지를 직접 클릭해 확인하기 전까지 노란 ! 마크 + 외곽 강조 유지. 영속.
    /// 마이그레이션 시 다중 컴플리트가 한꺼번에 발생해도 사용자가 모두 인지할 수 있게
    /// (단발성 `pendingCollectionCelebration` 배너만으론 마지막 1개만 노출되는 한계 보완).
    @Published var pendingCollectionHighlights: Set<String> {
        didSet { persist(pendingCollectionHighlights, forKey: Keys.pendingCollectionHighlights) }
    }

    // MARK: - 트레이너 카드 (Report 탭)
    //
    // 사용자 progress + customization을 한 카드에 응축, 스크린샷으로 공유하는 기능.
    // 4 layer: avatar(펫) / background / frame / title. + accessory 인벤토리.
    // unlock 평가는 `CardFrame.unlocked(in:)` / `CardTitle.unlocked(in:)` 등 enum-static.

    /// 트레이너 5자리 ID — 첫 launch 시 랜덤 생성, 영속. 사용자 변경 불가 (포켓몬 트레이너 ID 톤).
    @Published var trainerID: String {
        didSet { UserDefaults.standard.set(trainerID, forKey: Keys.trainerID) }
    }
    /// 트레이너 카드 customization 상태 (avatar/background/frame/title/accessory/layout).
    @Published var trainerCard: TrainerCard {
        didSet { persist(trainerCard, forKey: Keys.trainerCard) }
    }
    /// 코인 구매로 unlock한 액세서리 인벤토리. CardAccessory.rawValue 보관.
    @Published var ownedAccessories: Set<String> {
        didSet { persist(ownedAccessories, forKey: Keys.ownedAccessories) }
    }
    /// 코인 구매로 unlock한 칭호 인벤토리. CardTitle.rawValue 보관 (자동 unlock 칭호는 미포함).
    @Published var ownedTitles: Set<String> {
        didSet { persist(ownedTitles, forKey: Keys.ownedTitles) }
    }

    // 아레나 칭호 언락용 통계 캐시(서버 SSOT 미러, 표시/칭호 판정 전용). @Published 불요 — 칭호는
    // ReportView 열 때 lazy 평가. ArenaView.loadRankedState 가 leaderboard 응답으로 갱신.
    var pvpBestRating: Int {
        get { UserDefaults.standard.integer(forKey: "pvp.bestRating") }
        set { UserDefaults.standard.set(newValue, forKey: "pvp.bestRating") }
    }
    var pvpBestRank: Int {
        get { (UserDefaults.standard.object(forKey: "pvp.bestRank") as? Int) ?? Int.max }
        set { UserDefaults.standard.set(newValue, forKey: "pvp.bestRank") }
    }
    var pvpWinsCache: Int {
        get { UserDefaults.standard.integer(forKey: "pvp.wins") }
        set { UserDefaults.standard.set(newValue, forKey: "pvp.wins") }
    }
    /// 카드를 공유 이미지로 export할 때 GitHub login을 노출할지. 기본 false (privacy first) —
    /// GitHub 연결한 사용자가 명시적 opt-in해야 카드에 username 박힘.
    @Published var showGitHubLoginInCard: Bool {
        didSet { UserDefaults.standard.set(showGitHubLoginInCard, forKey: Keys.showGitHubLoginInCard) }
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
    /// GitHub 계정 생성 시각(ISO 8601 UTC). "오늘의 개발 운세" 의 사주 "생년월일" 로 사용.
    /// 한번 받아 두면 변하지 않음 — 토큰 갱신 때마다 다시 fetch 하지 않음.
    @Published var githubCreatedAt: String? {
        didSet { UserDefaults.standard.set(githubCreatedAt, forKey: Keys.githubCreatedAt) }
    }
    /// 이미 보너스가 적립된 PR 번호 집합 (dedupe). 한번 들어가면 영구 보존 — 계정 갈아끼워도 재지급 안 됨.
    @Published var creditedPRNumbers: Set<Int> {
        didSet { persist(creditedPRNumbers, forKey: Keys.creditedPRNumbers) }
    }

    // MARK: - 랭킹 (글로벌 보드)
    //
    // opt-in 후 활성. opt-in 시점에 baseline = 현재 `coinsTotalEarned` 캡처 → 서버에는 그
    // 시점부터의 delta(현재 total - lastSubmittedTotal)만 보고. 옵트인 이전 누적분이 한
    // 번에 큰 delta로 넘어가지 않게 막아 서버 sanity check(시간 비례 캡)를 회피하지 않음.
    //
    // 디바이스 UUID + per-install HMAC 키 + recovery code는 서버 register 시 발급. 재설치
    // 시 device UUID는 잃으므로 recovery code 또는 GitHub OAuth로 같은 user 레코드에 새
    // device UUID를 매핑.
    //
    // `rankingEnabled` (사용자 의사) 와 `rankingRegistered` (서버 등록 완료) 는 별개 —
    // 등록 후 사용자가 잠시 OFF 해도 서버 데이터는 유지 (계정 삭제는 별도 액션).

    /// 사용자가 랭킹 참여를 켰는지. 기본 false (현재 앱 철학: 로컬 우선, opt-in).
    @Published var rankingEnabled: Bool {
        didSet { UserDefaults.standard.set(rankingEnabled, forKey: Keys.rankingEnabled) }
    }
    /// 디바이스 식별자. 첫 옵트인 시 클라이언트에서 UUID 생성, 서버 register 시 등록.
    /// 재설치하면 잃음 → recovery code/GitHub OAuth로 새 UUID를 같은 user에 매핑.
    @Published var rankingDeviceID: String {
        didSet { UserDefaults.standard.set(rankingDeviceID, forKey: Keys.rankingDeviceID) }
    }
    /// 보드에 표시될 닉네임. 기본값은 `NicknameGenerator.generate()` 또는 `githubLogin`.
    /// 사용자가 자유 변경 가능. 서버측 unique 제약(case-insensitive) — 충돌 시 register 실패.
    @Published var rankingNickname: String {
        didSet { UserDefaults.standard.set(rankingNickname, forKey: Keys.rankingNickname) }
    }
    /// 서버가 register 응답으로 발급한 복구 코드 (XXXX-XXXX-XXXX). 사용자가 1회 보고 별도
    /// 보관. 분실 시 GitHub 연동이 두 번째 복구 수단.
    /// v0.8.10부터 Keychain 저장 — UserDefaults plist는 백업/iCloud sync로 평문 유출 위험.
    @Published var rankingRecoveryCode: String? {
        didSet {
            if let v = rankingRecoveryCode {
                if !Keychain.saveRecoveryCode(v) {
                    DebugLog.log("Ranking recovery code Keychain save failed")
                }
            } else {
                Keychain.clearRecoveryCode()
            }
        }
    }
    /// 옵트인 시점의 `coinsTotalEarned` 스냅샷. 서버에 baseline 이전 데이터는 보내지 않음.
    @Published var rankingBaselineCoins: Int {
        didSet { UserDefaults.standard.set(rankingBaselineCoins, forKey: Keys.rankingBaselineCoins) }
    }
    /// 마지막 성공 제출 시점의 `coinsTotalEarned`. 다음 제출 delta = 현재 total - 이 값.
    /// 첫 제출 전엔 baseline과 동일.
    @Published var rankingLastSubmittedTotal: Int {
        didSet { UserDefaults.standard.set(rankingLastSubmittedTotal, forKey: Keys.rankingLastSubmittedTotal) }
    }
    /// [어뷰징 방어] 신규 등록자는 baseline(옵트인 시점 VP) 이후 증가분만 서버에 제출한다.
    /// 과거 register가 클라이언트 누적값(initialCoins)을 한방에 인정하던 farming 통로를 막은 뒤
    /// 도입 — 서버는 항상 total_coins=0부터 시작하므로 클라도 0 기준으로 delta를 계산해야 한다.
    /// 기존(레거시) 등록자는 false로 남아 `rankingScoreEarnedVP` 절대 누적 기준 제출을 유지 →
    /// 서버 total_coins와의 동기가 깨지지 않아 완전 무영향. true면 ViewModel.submit이 baseline 차감.
    @Published var rankingUsesZeroBaseline: Bool {
        didSet { UserDefaults.standard.set(rankingUsesZeroBaseline, forKey: Keys.rankingUsesZeroBaseline) }
    }
    /// 현재 "서버 제출 단위"의 누적 total — `rankingLastSubmittedTotal`과 반드시 같은 단위다.
    /// zeroBaseline 계정은 baseline 이후 증가분(서버 total_coins와 동일 단위), 레거시는 절대 VP.
    /// submit delta 계산·일시정지 재개·recover 동기화가 모두 이 값을 단일 소스로 써야 단위가
    /// 어긋나지 않는다(어긋나면 제출이 장기 정지하거나 점수가 누락됨).
    var rankingSubmittableTotal: Int {
        rankingUsesZeroBaseline
            ? max(0, rankingScoreEarnedVP - rankingBaselineCoins)
            : rankingScoreEarnedVP
    }
    /// 마지막 성공 제출 시각. 시간 비례 캡 계산(서버측) + UI 표시용.
    @Published var rankingLastSubmittedAt: Date? {
        didSet { UserDefaults.standard.set(rankingLastSubmittedAt, forKey: Keys.rankingLastSubmittedAt) }
    }
    /// 서버 등록 완료 여부. 등록 전엔 enabled=true 여도 제출 안 함.
    /// enabled OFF/ON 토글로는 변하지 않음 — 계정 삭제 시에만 false.
    @Published var rankingRegistered: Bool {
        didSet { UserDefaults.standard.set(rankingRegistered, forKey: Keys.rankingRegistered) }
    }
    /// 처리방침 동의 여부. 옵트인 UI에서 체크박스로 받음. 미동의면 register 시도 차단.
    @Published var rankingPrivacyAccepted: Bool {
        didSet { UserDefaults.standard.set(rankingPrivacyAccepted, forKey: Keys.rankingPrivacyAccepted) }
    }
    /// 내 길드 표시 캐시 — 서버(guild-info)가 SSOT, 여기는 탭 첫 로드 전 표시·트레이너 카드
    /// 태그(P2a)용. 빈 문자열 = 무길드. guild-info 응답마다 동기화.
    @Published var guildID: String {
        didSet { UserDefaults.standard.set(guildID, forKey: Keys.guildID) }
    }
    @Published var guildName: String {
        didSet { UserDefaults.standard.set(guildName, forKey: Keys.guildName) }
    }
    @Published var isGuildLeader: Bool {
        didSet { UserDefaults.standard.set(isGuildLeader, forKey: Keys.isGuildLeader) }
    }
    /// 랭킹 점수 (Vibe Points) — Claude/Cursor 사용량을 "USD 가치"로 환산한 누적값.
    /// 1 VP = 1 cent (= $0.01) 등가. VPLedger가 UsageEvent 받을 때마다 plan price 기반 환산해
    /// 누적. coinsTotalEarned (가챠 코인 누적)과 별도. 보드 제출의 source-of-truth.
    @Published var rankingScoreEarnedVP: Int {
        didSet { UserDefaults.standard.set(rankingScoreEarnedVP, forKey: Keys.rankingScoreEarnedVP); recordIntegrityChecksum() }
    }
    /// VP 절단 손실 carry — `pureValue × vpFactor`가 소수일 때 누적 보존용.
    @Published var rankingScoreFractionVP: Double {
        didSet { UserDefaults.standard.set(rankingScoreFractionVP, forKey: Keys.rankingScoreFractionVP) }
    }
    /// 이미 수령한 명예의 전당 보상 dedup. 형식: "YYYY-MM.rank" (예: "2026-05.1").
    /// 한 번 들어가면 영구 — 서버측 idempotency와 함께 이중 지급 방지.
    @Published var claimedPodiumPeriods: Set<String> {
        didSet { persist(claimedPodiumPeriods, forKey: Keys.claimedPodiumPeriods) }
    }
    /// 이미 수령한 RP 순위 보상 dedup. 형식: "type.period.rank" (예: "monthly.2026-05.7").
    /// 로컬 1차 방어 — 진짜 이중지급 방어는 서버 claim의 alreadyClaimed (백업 복원에도 안전).
    @Published var claimedRpRewards: Set<String> {
        didSet { persist(claimedRpRewards, forKey: Keys.claimedRpRewards) }
    }
    /// 이미 수령한 통합 보상(ops grant) dedup. 형식: grant_key(캠페인/사유 슬러그).
    /// claimedRpRewards와 동일 — 로컬 1차 방어, 진짜 이중지급 방어는 서버 claim의 alreadyClaimed.
    @Published var claimedGrants: Set<String> {
        didSet { persist(claimedGrants, forKey: Keys.claimedGrants) }
    }
    /// Cursor Pro/Free 사용자의 request delta 추적용. Ultra는 events 기반이라 불필요.
    /// startOfMonth가 바뀌면 reset.
    @Published var cursorLastRequestsSeen: Int? {
        didSet { UserDefaults.standard.set(cursorLastRequestsSeen, forKey: Keys.cursorLastRequestsSeen) }
    }
    @Published var cursorLastStartOfMonth: Date? {
        didSet { UserDefaults.standard.set(cursorLastStartOfMonth, forKey: Keys.cursorLastStartOfMonth) }
    }
    /// 마지막으로 게시판 윈도우를 본 시점. 메인 패널의 진입점에 표시되는 미확인 글 카운트의 기준.
    /// nil이면 처음 — ViewModel.refreshBoard 첫 cycle에서 현재 시각으로 시드해 과거 글 전체를
    /// 미확인으로 표시하지 않게 함.
    @Published var boardLastSeenAt: Date? {
        didSet { UserDefaults.standard.set(boardLastSeenAt, forKey: Keys.boardLastSeenAt) }
    }
    /// 본인 누적 메달 캐시 — 진실은 서버 `monthly_winners`. leaderboard 응답의 `myMedals`로
    /// 갱신해 리포트 카드가 서버 round-trip 없이 즉시 그릴 수 있게 한다. 백업 대상 아님(재집계 가능).
    @Published var myMedalGold: Int {
        didSet { UserDefaults.standard.set(myMedalGold, forKey: Keys.myMedalGold) }
    }
    @Published var myMedalSilver: Int {
        didSet { UserDefaults.standard.set(myMedalSilver, forKey: Keys.myMedalSilver) }
    }
    @Published var myMedalBronze: Int {
        didSet { UserDefaults.standard.set(myMedalBronze, forKey: Keys.myMedalBronze) }
    }
    /// 카드 렌더 주입용 — 캐시된 3개 카운트를 `MedalTally`로 묶음.
    var medalTally: MedalTally {
        MedalTally(gold: myMedalGold, silver: myMedalSilver, bronze: myMedalBronze)
    }
    /// leaderboard 응답의 `myMedals`를 캐시에 반영. nil(구버전 서버/미등록)이면 no-op.
    func applyMyMedals(_ m: MedalTally?) {
        guard let m else { return }
        if myMedalGold != m.gold { myMedalGold = m.gold }
        if myMedalSilver != m.silver { myMedalSilver = m.silver }
        if myMedalBronze != m.bronze { myMedalBronze = m.bronze }
    }

    private init() {
        let d = UserDefaults.standard
        self.panelOpacity  = (d.object(forKey: Keys.panelOpacity) as? Double) ?? 1.0
        self.notifyEnabled = (d.object(forKey: Keys.notifyEnabled) as? Bool) ?? true
        self.experimentalRemotePetMeta = (d.object(forKey: Keys.experimentalRemotePetMeta) as? Bool) ?? false
        self.patchNotesEnabled = (d.object(forKey: Keys.patchNotesEnabled) as? Bool) ?? true
        self.lastSeenAnnouncementVersion = d.string(forKey: Keys.lastSeenAnnouncementVersion)
        let storedThresholds = (d.array(forKey: Keys.notifyThresholds) as? [Int]) ?? []
        self.notifyThresholds = storedThresholds.isEmpty ? [80, 95] : storedThresholds.sorted()
        self.showPace      = (d.object(forKey: Keys.showPace) as? Bool) ?? true
        self.showMenuBar   = (d.object(forKey: Keys.showMenuBar) as? Bool) ?? true
        self.menuBarPetSource = (d.string(forKey: Keys.menuBarPetSource).flatMap { MenuBarPetSource(rawValue: $0) }) ?? .claude
        self.petClaudeEnabled = (d.object(forKey: Keys.petClaudeEnabled) as? Bool) ?? true
        self.petCursorEnabled = (d.object(forKey: Keys.petCursorEnabled) as? Bool) ?? true
        self.petCodexEnabled = (d.object(forKey: Keys.petCodexEnabled) as? Bool) ?? true
        // 파티 프리셋 로드 — 저장된 프리셋 라이브러리 + 소스별 할당 id.
        // 없으면(프리셋 도입 전 빌드에서 업데이트) 레거시 per-source 파티(또는 단수 kind)에서 마이그레이션.
        let presetsData = d.data(forKey: Keys.partyPresets)
        var loadedPresets = presetsData.flatMap { try? JSONDecoder().decode([PartyPreset].self, from: $0) } ?? []
        var claudePID = d.string(forKey: Keys.claudePresetID).flatMap { UUID(uuidString: $0) }
        var cursorPID = d.string(forKey: Keys.cursorPresetID).flatMap { UUID(uuidString: $0) }
        var codexPID  = d.string(forKey: Keys.codexPresetID).flatMap { UUID(uuidString: $0) }
        let assignmentsValid = [claudePID, cursorPID, codexPID].allSatisfy { id in
            id != nil && loadedPresets.contains { $0.id == id }
        }
        if loadedPresets.isEmpty || !assignmentsValid {
            // 레거시 per-source 파티(또는 단수 petClaudeKind/Variant)에서 파티 구성 복원.
            func legacyParty(_ key: String, fallback: [PetSelection]) -> [PetSelection] {
                (d.data(forKey: key).flatMap { try? JSONDecoder().decode([PetSelection].self, from: $0) }) ?? fallback
            }
            let claudeMembers = legacyParty(Keys.petClaudeParty, fallback:
                [PetSelection(kind: d.string(forKey: Keys.petClaudeKind).flatMap { PetKind(rawValue: $0) } ?? .fox,
                              variant: (d.object(forKey: Keys.petClaudeVariant) as? Int) ?? 0)])
            let cursorMembers = legacyParty(Keys.petCursorParty, fallback:
                [PetSelection(kind: d.string(forKey: Keys.petCursorKind).flatMap { PetKind(rawValue: $0) } ?? .wolf,
                              variant: (d.object(forKey: Keys.petCursorVariant) as? Int) ?? 0)])
            let codexMembers = legacyParty(Keys.petCodexParty, fallback: [PetSelection(kind: .fox, variant: 0)])
            // 동일 구성은 하나의 프리셋으로 dedup (기본 상태의 3중복 방지).
            var built: [PartyPreset] = []
            func idFor(_ members: [PetSelection]) -> UUID {
                if let e = built.first(where: { $0.members == members }) { return e.id }
                let p = PartyPreset(id: UUID(), name: "파티 \(built.count + 1)", members: members)
                built.append(p)
                return p.id
            }
            claudePID = idFor(claudeMembers)
            cursorPID = idFor(cursorMembers)
            codexPID  = idFor(codexMembers)
            loadedPresets = built
        }
        self.partyPresets = loadedPresets
        self.claudePresetID = claudePID!
        self.cursorPresetID = cursorPID!
        self.codexPresetID = codexPID!
        self.purchasedPartyPresetSlots = d.integer(forKey: Keys.purchasedPartyPresetSlots)
        // 마이그레이션으로 새로 만들었으면 영속이 필요(didSet은 init 중 미동작). 모든 저장 프로퍼티가
        // 초기화된 뒤 init 끝에서 persist한다(여기선 self 메서드 호출 불가).
        let needsPresetPersist = (presetsData == nil)
        self.themeClaudeOverride = d.string(forKey: Keys.themeClaudeOverride).flatMap { PetTheme(rawValue: $0) }
        self.themeCursorOverride = d.string(forKey: Keys.themeCursorOverride).flatMap { PetTheme(rawValue: $0) }
        self.themeCodexOverride = d.string(forKey: Keys.themeCodexOverride).flatMap { PetTheme(rawValue: $0) }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        let storedBigDrop = (d.object(forKey: Keys.bigDropThreshold) as? Double) ?? 0.40
        self.bigDropThreshold = max(0.10, min(0.80, storedBigDrop))
        self.weatherEffectEnabled = (d.object(forKey: Keys.weatherEffectEnabled) as? Bool) ?? true
        self.weatherLocation = (d.string(forKey: Keys.weatherLocation).flatMap { WeatherLocation(rawValue: $0) }) ?? .utower

        // Gacha 필드 로드
        // 마이그레이션 판정용으로 legacy 키 존재 여부를 init 안에서 미리 캡처.
        let hadLegacyClaudeKind = d.string(forKey: Keys.petClaudeKind) != nil
        let hadLegacyCursorKind = d.string(forKey: Keys.petCursorKind) != nil
        self.coins = (d.object(forKey: Keys.coins) as? Int) ?? 0
        self.gachaTickets = (d.object(forKey: Keys.gachaTickets) as? Int) ?? 0
        self.premiumTickets = (d.object(forKey: Keys.premiumTickets) as? Int) ?? 0
        self.guildPermits = (d.object(forKey: Keys.guildPermits) as? Int) ?? 0
        self.integrityViolation = d.bool(forKey: Keys.integrityViolation)
        let ownedData = d.data(forKey: Keys.ownedPets)
        self.ownedPets = (ownedData.flatMap { try? JSONDecoder().decode([PetKind: PetOwnership].self, from: $0) }) ?? [:]
        let usageData = d.data(forKey: Keys.petUsageSeconds)
        self.petUsageSeconds = (usageData.flatMap { try? JSONDecoder().decode([PetKind: TimeInterval].self, from: $0) }) ?? [:]
        self.rp = (d.object(forKey: Keys.rp) as? Int) ?? 0
        self.rpTotalEarned = (d.object(forKey: Keys.rpTotalEarned) as? Int) ?? 0
        self.shinyShards = (d.object(forKey: Keys.shinyShards) as? Int) ?? 0
        let effectsData = d.data(forKey: Keys.petEffects)
        self.petEffects = (effectsData.flatMap { try? JSONDecoder().decode([PetKind: Set<EffectKind>].self, from: $0) }) ?? [:]
        let equippedData = d.data(forKey: Keys.equippedEffects)
        self.equippedEffects = (equippedData.flatMap { try? JSONDecoder().decode([PetKind: Set<EffectKind>].self, from: $0) }) ?? [:]
        let highlightData = d.data(forKey: Keys.pendingHighlights)
        self.pendingHighlights = (highlightData.flatMap { try? JSONDecoder().decode(Set<PetKind>.self, from: $0) }) ?? []
        // petClaudeVariant/petCursorVariant는 party 리더 미러 computed — 위 party 로드에 흡수됨.
        self.lastClaudeFiveHourReset = d.object(forKey: Keys.lastClaudeFiveHourReset) as? Date
        self.lastClaudeSevenDayReset = d.object(forKey: Keys.lastClaudeSevenDayReset) as? Date
        self.lastClaudeFiveHourPctSeen = d.object(forKey: Keys.lastClaudeFiveHourPctSeen) as? Double
        self.lastClaudeSevenDayPctSeen = d.object(forKey: Keys.lastClaudeSevenDayPctSeen) as? Double
        self.claudeFiveHourCoinFraction = (d.object(forKey: Keys.claudeFiveHourCoinFraction) as? Double) ?? 0
        self.claudeSevenDayCoinFraction = (d.object(forKey: Keys.claudeSevenDayCoinFraction) as? Double) ?? 0
        self.cursorCoinFraction = (d.object(forKey: Keys.cursorCoinFraction) as? Double) ?? 0
        self.lastCodexFiveHourReset = d.object(forKey: Keys.lastCodexFiveHourReset) as? Date
        self.lastCodexSevenDayReset = d.object(forKey: Keys.lastCodexSevenDayReset) as? Date
        self.lastCodexMonthlyReset = d.object(forKey: Keys.lastCodexMonthlyReset) as? Date
        self.lastCodexFiveHourPctSeen = d.object(forKey: Keys.lastCodexFiveHourPctSeen) as? Double
        self.lastCodexSevenDayPctSeen = d.object(forKey: Keys.lastCodexSevenDayPctSeen) as? Double
        self.lastCodexMonthlyPctSeen = d.object(forKey: Keys.lastCodexMonthlyPctSeen) as? Double
        self.codexFiveHourCoinFraction = (d.object(forKey: Keys.codexFiveHourCoinFraction) as? Double) ?? 0
        self.codexSevenDayCoinFraction = (d.object(forKey: Keys.codexSevenDayCoinFraction) as? Double) ?? 0
        self.codexMonthlyCoinFraction = (d.object(forKey: Keys.codexMonthlyCoinFraction) as? Double) ?? 0
        self.lastCursorEventCredited = d.object(forKey: Keys.lastCursorEventCredited) as? Date
        self.coinsTotalEarned = (d.object(forKey: Keys.coinsTotalEarned) as? Int) ?? 0
        self.firstCreditedAt = d.object(forKey: Keys.firstCreditedAt) as? Date
        self.lastWellnessShownAt = d.object(forKey: Keys.lastWellnessShownAt) as? Date
        self.dailyFortuneLastShownDate = d.object(forKey: Keys.dailyFortuneLastShownDate) as? Date
        self.dailyQuizLastSolvedDate = d.object(forKey: Keys.dailyQuizLastSolvedDate) as? Date

        self.githubLogin = d.string(forKey: Keys.githubLogin)
        self.githubUserID = (d.object(forKey: Keys.githubUserID) as? Int)
        self.githubCreatedAt = d.string(forKey: Keys.githubCreatedAt)
        let creditedData = d.data(forKey: Keys.creditedPRNumbers)
        self.creditedPRNumbers = (creditedData.flatMap { try? JSONDecoder().decode(Set<Int>.self, from: $0) }) ?? []

        // 랭킹 (글로벌 보드)
        self.rankingEnabled            = (d.object(forKey: Keys.rankingEnabled) as? Bool) ?? false
        self.rankingDeviceID           = d.string(forKey: Keys.rankingDeviceID) ?? ""
        self.rankingNickname           = d.string(forKey: Keys.rankingNickname) ?? ""
        // recoveryCode: Keychain 우선 → 없으면 UserDefaults legacy migration → 둘 다 없으면 nil.
        // 마이그레이션 이후 UserDefaults 잔재는 항상 제거(평문 plist에 남지 않게).
        if let kc = Keychain.loadRecoveryCode() {
            self.rankingRecoveryCode = kc
            d.removeObject(forKey: Keys.rankingRecoveryCode)
        } else if let legacy = d.string(forKey: Keys.rankingRecoveryCode), !legacy.isEmpty {
            self.rankingRecoveryCode = legacy
            if Keychain.saveRecoveryCode(legacy) {
                d.removeObject(forKey: Keys.rankingRecoveryCode)
            } else {
                DebugLog.log("Ranking recovery code migration kept legacy UserDefaults value after Keychain save failure")
            }
        } else {
            self.rankingRecoveryCode = nil
        }
        self.rankingBaselineCoins      = (d.object(forKey: Keys.rankingBaselineCoins) as? Int) ?? 0
        self.rankingLastSubmittedTotal = (d.object(forKey: Keys.rankingLastSubmittedTotal) as? Int) ?? 0
        // 기존 등록 사용자는 키 부재 → false(레거시 절대 누적 모드) → 무영향. 신규 등록 시 true.
        self.rankingUsesZeroBaseline   = (d.object(forKey: Keys.rankingUsesZeroBaseline) as? Bool) ?? false
        self.rankingLastSubmittedAt    = d.object(forKey: Keys.rankingLastSubmittedAt) as? Date
        self.rankingRegistered         = (d.object(forKey: Keys.rankingRegistered) as? Bool) ?? false
        self.rankingPrivacyAccepted    = (d.object(forKey: Keys.rankingPrivacyAccepted) as? Bool) ?? false
        self.guildID                   = d.string(forKey: Keys.guildID) ?? ""
        self.guildName                 = d.string(forKey: Keys.guildName) ?? ""
        self.isGuildLeader             = (d.object(forKey: Keys.isGuildLeader) as? Bool) ?? false
        self.rankingScoreEarnedVP      = (d.object(forKey: Keys.rankingScoreEarnedVP) as? Int) ?? 0
        self.rankingScoreFractionVP    = (d.object(forKey: Keys.rankingScoreFractionVP) as? Double) ?? 0
        let claimedData = d.data(forKey: Keys.claimedPodiumPeriods)
        self.claimedPodiumPeriods = (claimedData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let claimedRpData = d.data(forKey: Keys.claimedRpRewards)
        self.claimedRpRewards = (claimedRpData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let claimedGrantData = d.data(forKey: Keys.claimedGrants)
        self.claimedGrants = (claimedGrantData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        self.cursorLastRequestsSeen    = d.object(forKey: Keys.cursorLastRequestsSeen) as? Int
        self.cursorLastStartOfMonth    = d.object(forKey: Keys.cursorLastStartOfMonth) as? Date
        self.boardLastSeenAt           = d.object(forKey: Keys.boardLastSeenAt) as? Date
        self.myMedalGold               = (d.object(forKey: Keys.myMedalGold) as? Int) ?? 0
        self.myMedalSilver             = (d.object(forKey: Keys.myMedalSilver) as? Int) ?? 0
        self.myMedalBronze             = (d.object(forKey: Keys.myMedalBronze) as? Int) ?? 0

        // 도장 카운터 로드
        self.wellnessRespondedCount = (d.object(forKey: Keys.wellnessRespondedCount) as? Int) ?? 0
        self.rateLimitWeeksPassed   = (d.object(forKey: Keys.rateLimitWeeksPassed) as? Int) ?? 0
        self.claudeCoinsEarned      = (d.object(forKey: Keys.claudeCoinsEarned) as? Int) ?? 0
        self.cursorCoinsEarned      = (d.object(forKey: Keys.cursorCoinsEarned) as? Int) ?? 0
        self.codexCoinsEarned       = (d.object(forKey: Keys.codexCoinsEarned) as? Int) ?? 0
        self.heartbeatStreak        = (d.object(forKey: Keys.heartbeatStreak) as? Int) ?? 0
        self.heartbeatLastActiveAt  = d.object(forKey: Keys.heartbeatLastActiveAt) as? Date
        self.nightOwlSecondsAccumulated = (d.object(forKey: Keys.nightOwlSecondsAccumulated) as? Int) ?? 0
        self.usageStreak            = (d.object(forKey: Keys.usageStreak) as? Int) ?? 0
        self.usageStreakLastDay     = d.object(forKey: Keys.usageStreakLastDay) as? Date
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
        self.masteredRegions = (d.data(forKey: Keys.masteredRegions).flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        self.hasViewedGymPage      = (d.object(forKey: Keys.hasViewedGymPage) as? Bool) ?? false
        self.hasViewedGuide        = (d.object(forKey: Keys.hasViewedGuide) as? Bool) ?? false
        self.hasReceivedCoffeeReward = (d.object(forKey: Keys.hasReceivedCoffeeReward) as? Bool) ?? false
        self.currentTenant = d.string(forKey: Keys.currentTenant)
        self.lastTenantPromptAt = d.object(forKey: Keys.lastTenantPromptAt) as? Date
        self.hasReceivedTenantVerifyBonus = (d.object(forKey: Keys.hasReceivedTenantVerifyBonus) as? Bool) ?? false
        self.tenantPromptOptedOut = (d.object(forKey: Keys.tenantPromptOptedOut) as? Bool) ?? false

        // 펫 컬렉션 (셋 보너스) 로드
        let completedColData = d.data(forKey: Keys.completedCollections)
        self.completedCollections = (completedColData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let completedAtData = d.data(forKey: Keys.collectionCompletedAt)
        self.collectionCompletedAt = (completedAtData.flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) }) ?? [:]
        // pendingCollectionCelebration은 단발성이지만 앱 종료 시점에 미소비 상태일 수 있으므로
        // 영속 — 다음 실행 시 가챠 화면 진입 첫 hatched에서 처리하거나, 사용자가 도감을 직접
        // 열면 거기서 한 번 띄우고 nil. 영영 묵히지 않음.
        self.pendingCollectionCelebration = d.string(forKey: Keys.pendingCollectionCelebration)
        let collectionHighlightsData = d.data(forKey: Keys.pendingCollectionHighlights)
        self.pendingCollectionHighlights = (collectionHighlightsData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []

        // 트레이너 카드 로드. 첫 launch면 랜덤 5자리 ID 생성 + 기본 카드 사용.
        if let id = d.string(forKey: Keys.trainerID), !id.isEmpty {
            self.trainerID = id
        } else {
            let newID = TrainerCard.generateTrainerID()
            self.trainerID = newID
            d.set(newID, forKey: Keys.trainerID)
        }
        let cardData = d.data(forKey: Keys.trainerCard)
        self.trainerCard = (cardData.flatMap { try? JSONDecoder().decode(TrainerCard.self, from: $0) }) ?? .default
        let accessoriesData = d.data(forKey: Keys.ownedAccessories)
        self.ownedAccessories = (accessoriesData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let titlesData = d.data(forKey: Keys.ownedTitles)
        self.ownedTitles = (titlesData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let themesData = d.data(forKey: Keys.ownedThemes)
        self.ownedThemes = (themesData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        let invCollapsedData = d.data(forKey: Keys.gachaInventoryCollapsed)
        self.gachaInventoryCollapsed = (invCollapsedData.flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) }) ?? []
        self.showGitHubLoginInCard = (d.object(forKey: Keys.showGitHubLoginInCard) as? Bool) ?? false

        // 신규 사용자 / 기존 사용자 모두 최종 가챠권 3장이 되도록 두 단계로 처리:
        //   1) 신규 사용자 (hasCompletedGachaMigration 아직 false): 첫 실행 시 3장 지급
        //   2) 기존 사용자 (이미 1장 받고 마이그레이션 완료): v0.3.2 보너스 블록에서 +2장
        // wasExistingUser는 1번 블록이 hasCompletedGachaMigration을 true로 토글하기 전의 값으로,
        // 신규 유저가 1번에서 3장 받은 다음 2번 블록에서 또 +2장 받는 이중 지급을 방지.
        let wasExistingUser = d.bool(forKey: Keys.hasCompletedGachaMigration)

        // 아래 1회성 마이그레이션 중 하나라도 무결성 감시 대상 값(coins·티켓·펫 목록 등)을 바꾸면
        // init 말미 verifyIntegrity의 "저장된 체크섬 vs 현재 값" 비교가 오탐이 된다 — init 중엔
        // didSet이 안 돌아 recordIntegrityChecksum()이 호출되지 않기 때문. 그런 실행에서는 비교를
        // 건너뛰고 현재 상태를 신뢰해 체크섬만 재기록(리베이스)하도록 표시한다.
        var integrityRebaseNeeded = false

        // (1) 첫 실행 시 1회만: 가챠권 3장 지급 + 기존 사용 중이던 펫이 있으면 보유 목록에 등록.
        //
        // 등급 가드: legacy default petKind가 Mythic/Legendary/Epic이면 마이그레이션으로 무료 등록하지
        // 않는다 — 사용자는 가챠로 뽑아야 함. (`Gacha.isHighRarity`가 권위 있는 검사.)
        // 이론상 legacy default(.fox, .wolf)는 모두 Common이라 현재 가드는 no-op이지만,
        // 향후 default 값이 바뀌거나 사용자가 settings UI에서 상위 등급을 선택해뒀다면 보호된다.
        if !d.bool(forKey: Keys.hasCompletedGachaMigration) {
            var owned = self.ownedPets
            if hadLegacyClaudeKind, owned[self.petClaudeKind] == nil,
               !Gacha.isHighRarity(self.petClaudeKind) {
                owned[self.petClaudeKind] = .initial()
            }
            if hadLegacyCursorKind, !Gacha.isHighRarity(self.petCursorKind) {
                if var existing = owned[self.petCursorKind] {
                    existing.count += 1
                    owned[self.petCursorKind] = existing
                } else {
                    owned[self.petCursorKind] = .initial()
                }
            }
            // 완전 신규(legacy 펫 설정도 없던) 사용자 — 빈 인벤토리 방지 위해 기본 여우 1마리를 지급하고
            // 단일 "기본" 프리셋(여우)을 세 소스에 모두 할당. (legacy 마이그레이션으로 펫이 이미 들어왔으면
            // 건드리지 않음.) init 중이라 didSet 미동작 → 직접 persist.
            if owned.isEmpty {
                owned[.fox] = .initial()
                let base = PartyPreset(id: UUID(), name: "기본", members: [PetSelection(kind: .fox, variant: 0)])
                self.partyPresets = [base]
                self.claudePresetID = base.id
                self.cursorPresetID = base.id
                self.codexPresetID = base.id
                persist(self.partyPresets, forKey: Keys.partyPresets)
                d.set(base.id.uuidString, forKey: Keys.claudePresetID)
                d.set(base.id.uuidString, forKey: Keys.cursorPresetID)
                d.set(base.id.uuidString, forKey: Keys.codexPresetID)
            }
            self.ownedPets = owned
            self.gachaTickets = 3
            // didSet은 init 중엔 트리거되지 않으므로 직접 persist.
            persist(self.ownedPets, forKey: Keys.ownedPets)
            d.set(3, forKey: Keys.gachaTickets)
            d.set(true, forKey: Keys.hasCompletedGachaMigration)
            integrityRebaseNeeded = true
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
            integrityRebaseNeeded = true
        }

        // 5월의 달 기념 — 신규+기존 모든 사용자에게 1회 5,000 coin 지급. v0.7.0 캠페인.
        // onlyExisting=false라 첫 launch 신규 사용자도 환영 보너스로 받음.
        // 주의: init 중엔 CoinLedger.shared 호출 시 Settings.shared 재진입으로 deadlock 위험.
        // 따라서 여기서만 예외적으로 직접 mutate. 그 외 위치에선 CoinLedger.creditBonus() 사용.
        applyOnceMigration(key: Keys.hasReceivedMay2026Bonus,
                           onlyExisting: false,
                           wasExistingUser: wasExistingUser) {
            self.coins += 5000
            self.coinsTotalEarned += 5000
            if self.firstCreditedAt == nil {
                self.firstCreditedAt = Date()
                d.set(self.firstCreditedAt, forKey: Keys.firstCreditedAt)
            }
            d.set(self.coins, forKey: Keys.coins)
            d.set(self.coinsTotalEarned, forKey: Keys.coinsTotalEarned)
            integrityRebaseNeeded = true
        }

        // 최근 서버 불안정 이슈 사과 — 모든 사용자 1회 3,000 coin. v0.8.5 캠페인.
        // May2026Bonus 와 동일하게 init 안에서 직접 mutate (CoinLedger 재진입 회피).
        applyOnceMigration(key: Keys.hasReceivedServerInstabilityBonus,
                           onlyExisting: false,
                           wasExistingUser: wasExistingUser) {
            self.coins += 3000
            self.coinsTotalEarned += 3000
            if self.firstCreditedAt == nil {
                self.firstCreditedAt = Date()
                d.set(self.firstCreditedAt, forKey: Keys.firstCreditedAt)
            }
            d.set(self.coins, forKey: Keys.coins)
            d.set(self.coinsTotalEarned, forKey: Keys.coinsTotalEarned)
            integrityRebaseNeeded = true
        }

        // 코스메틱 장착 슬롯(타입당 1개) 도입 마이그레이션 — 기존 자유 조합에서 category당
        // price 최고 1개만 장착 유지(보유 petEffects는 그대로). init 중 didSet 미동작 → 직접 persist.
        applyOnceMigration(key: Keys.hasMigratedEffectSlots,
                           onlyExisting: false,
                           wasExistingUser: wasExistingUser) {
            var eq = self.equippedEffects
            for (kind, set) in eq {
                var best: [EffectCategory: EffectKind] = [:]
                for e in set where best[e.category].map({ e.price > $0.price }) ?? true {
                    best[e.category] = e
                }
                eq[kind] = Set(best.values)
            }
            self.equippedEffects = eq
            self.persist(eq, forKey: Keys.equippedEffects)
        }

        // claude 로그인 버그(v0.8.10~v0.13.10 재로그인 불능, #77) 사과 — 기존 사용자에게
        // sudo pull(프리미엄 가챠권, premiumTickets) 2장 1회 지급. 신규 사용자는 버그 영향이 없어 제외.
        applyOnceMigration(key: Keys.hasReceivedLoginApologyTickets,
                           onlyExisting: true,
                           wasExistingUser: wasExistingUser) {
            self.premiumTickets += 2
            d.set(self.premiumTickets, forKey: Keys.premiumTickets)
            integrityRebaseNeeded = true
        }

        // 구매제 도입 전부터 동적 테마를 override 로 쓰고 있었다면 보유로 인정 (뺏지 않음).
        // init 끝(모든 프로퍼티 초기화 후)이라 self 자유 사용. init 중 didSet은 안 도므로 직접 persist.
        var migratedThemes = false
        for ov in [themeClaudeOverride, themeCursorOverride, themeCodexOverride] {
            if let t = ov, t.isDynamic, !ownedThemes.contains(t.rawValue) {
                ownedThemes.insert(t.rawValue)
                migratedThemes = true
            }
        }
        if migratedThemes { persist(ownedThemes, forKey: Keys.ownedThemes) }

        // 레거시 파티 → 프리셋 마이그레이션 결과 영속 (위에서 self 메서드 호출 불가라 여기로 지연).
        // 브랜드-신규 사용자는 가챠 마이그레이션 블록에서 이미 persist했으므로 값만 재확인 저장(무해).
        if needsPresetPersist {
            persist(partyPresets, forKey: Keys.partyPresets)
            d.set(claudePresetID.uuidString, forKey: Keys.claudePresetID)
            d.set(cursorPresetID.uuidString, forKey: Keys.cursorPresetID)
            d.set(codexPresetID.uuidString, forKey: Keys.codexPresetID)
        }

        // 이로치 조각 도입 1회 시드 — 기존 펫의 '현재 오버플로우'를 이미 지급됨으로 표시해 과거분
        // 소급 지급을 막는다(조각은 도입 이후 오버플로우부터 적립). 신규 펫은 오버플로우 0이라 no-op.
        applyOnceMigration(key: Keys.hasSeededShardOverflow, onlyExisting: false,
                           wasExistingUser: wasExistingUser) {
            var owned = self.ownedPets
            for kind in Array(owned.keys) {
                guard var ship = owned[kind] else { continue }
                ship.seedCreditedShardUnits(usageSeconds: self.petUsageSeconds[kind] ?? 0)
                owned[kind] = ship
            }
            self.ownedPets = owned
            self.persist(owned, forKey: Keys.ownedPets)
        }

        // 도장 마이그레이션은 init 안에서 호출 금지 — `BadgeRegistry.evaluate`가 `Settings.shared`를
        // 재진입해서 lazy init이 깨짐. App 시작 후 `applyGymMigrationIfNeeded()`에서 처리.

        // 무결성 오탐 사면(1회) — 과거 버전의 1회성 보상 마이그레이션들이 체크섬 재기록 없이
        // 감시 값을 바꿔(init didSet 미동작) 정상 사용자의 integrityViolation이 잘못 켜진 이력이
        // 있다. 진짜 조작과 구분할 수 없으므로, keychain 지문 리베이스와 동일한 근거(가드는
        // casual deterrent, 로컬 조작은 타인 피해 없음)로 1회 신뢰 리셋 + 체크섬 리베이스한다.
        applyOnceMigration(key: Keys.hasResetIntegrityFalsePositive,
                           onlyExisting: true,
                           wasExistingUser: wasExistingUser) {
            if self.integrityViolation {
                self.integrityViolation = false
                d.set(false, forKey: Keys.integrityViolation)
                DebugLog.log("IntegrityGuard: 마이그레이션 오탐 사면 — violation 해제 + 리베이스")
            }
            integrityRebaseNeeded = true
        }

        // 무결성 검증은 모든 init 마이그레이션이 끝난 뒤 1회 — migration의 정상 변경을 조작으로
        // 오탐하지 않도록 마지막에 둔다. 탐지만 하고 데이터는 건드리지 않는다.
        // 이번 실행에서 마이그레이션이 감시 값을 바꿨다면 비교 대신 체크섬을 재기록한다.
        verifyIntegrity(rebaseAfterMigration: integrityRebaseNeeded)
    }

    // MARK: - 무결성 가드 (탐지 전용)

    /// 핵심 로컬 상태(coins·펫·티켓·VP)의 무결성 체크섬을 현재 값 기준으로 재기록. 핵심값 didSet
    /// 에서 호출돼 앱 내 정상 변경은 항상 최신 체크섬을 유지한다(크래시 false positive 최소화).
    /// 데이터는 절대 수정하지 않는다. init 중에는 didSet이 안 돌아 호출되지 않으며, init 끝
    /// `verifyIntegrity()`가 최초 체크섬을 기록한다.
    func recordIntegrityChecksum() {
        let key = Keychain.loadOrCreateIntegrityKey()
        let serialized = ownedPets.keys.map { $0.rawValue }.sorted().joined(separator: ",")
        guard let cs = IntegrityGuard.checksum(
            coins: coins, coinsTotalEarned: coinsTotalEarned,
            gachaTickets: gachaTickets, premiumTickets: premiumTickets,
            guildPermits: guildPermits,
            rankingScoreEarnedVP: rankingScoreEarnedVP,
            ownedPetsSerialized: serialized, keyBase64: key) else { return }
        UserDefaults.standard.set(cs, forKey: Keys.integrityChecksum)
        UserDefaults.standard.set(IntegrityGuard.formatVersion, forKey: Keys.integrityChecksumVersion)
        // 이 체크섬을 만든 키의 지문도 함께 저장 → 다음 verify가 키 교체(유실→재생성)를 감지.
        UserDefaults.standard.set(IntegrityGuard.keyFingerprint(keyBase64: key), forKey: Keys.integrityKeyFingerprint)
    }

    /// 시작 시 1회 — 저장된 체크섬과 현재 값을 비교해 앱 외부 조작을 탐지. 데이터는 수정하지
    /// 않는다. 최초 실행(체크섬 부재)은 현재 상태를 신뢰하고 기록 → 도입 이전 조작은 소급 불가.
    /// 탐지되면 `integrityViolation`을 영속 set(랭킹 제출 시 서버 보고). 정상 사용자는 didSet이
    /// 항상 체크섬을 갱신하므로 켜지지 않는다.
    func verifyIntegrity(rebaseAfterMigration: Bool = false) {
        // init 마이그레이션이 감시 값을 정상 변경한 실행에서는 저장된 체크섬과의 비교가 무의미
        // (정상 지급을 조작으로 오탐) — 현재 상태를 신뢰하고 체크섬만 재기록한다. 조작과
        // 마이그레이션이 같은 실행에 겹치면 놓치지만, 지문 리베이스와 동일하게 수용한다.
        if rebaseAfterMigration {
            recordIntegrityChecksum()
            return
        }
        let key = Keychain.loadOrCreateIntegrityKey()
        let serialized = ownedPets.keys.map { $0.rawValue }.sorted().joined(separator: ",")
        guard let current = IntegrityGuard.checksum(
            coins: coins, coinsTotalEarned: coinsTotalEarned,
            gachaTickets: gachaTickets, premiumTickets: premiumTickets,
            guildPermits: guildPermits,
            rankingScoreEarnedVP: rankingScoreEarnedVP,
            ownedPetsSerialized: serialized, keyBase64: key) else { return }
        guard let stored = UserDefaults.standard.string(forKey: Keys.integrityChecksum) else {
            recordIntegrityChecksum()  // 최초 — 신뢰하고 기록
            return
        }
        // 포맷 버전 마이그레이션 — 구 포맷(v1: guildPermits 없음) 체크섬과는 비교 불가.
        // 업그레이드 직후 1회에 한해 현재 상태를 신뢰하고 새 포맷으로 재기록한다
        // (가드 도입 시점의 "소급 불가"와 동일한 트레이드오프 — 오탐 전면 발생보다 낫다).
        let storedVersion = UserDefaults.standard.integer(forKey: Keys.integrityChecksumVersion)
        if storedVersion < IntegrityGuard.formatVersion {
            recordIntegrityChecksum()
            return
        }
        // 체크섬 키가 바뀌었으면(keychain vault 마이그레이션 부분 실패 등으로 integrityKey가 유실→
        // 재생성) 저장된 체크섬은 옛 키 기반이라 무조건 불일치 — 조작이 아니므로 오탐하면 안 된다.
        // 지문이 없던 레거시(이 필드 도입 전) 역시 첫 실행에서 여기로 흡수돼, 이미 이 버그로 잘못
        // 켜진 integrityViolation을 함께 해제한다(가드는 casual deterrent이고 로컬 조작은 타인 피해가
        // 없어, formatVersion 마이그레이션과 동일하게 1회 신뢰 리베이스를 택한다).
        let storedFingerprint = UserDefaults.standard.string(forKey: Keys.integrityKeyFingerprint)
        let currentFingerprint = IntegrityGuard.keyFingerprint(keyBase64: key)
        if storedFingerprint != currentFingerprint {
            if integrityViolation { integrityViolation = false }
            recordIntegrityChecksum()
            DebugLog.log("IntegrityGuard: 체크섬 키 교체 감지 — 신뢰 재기록(오탐 방지)")
            return
        }
        if stored != current && !integrityViolation {
            integrityViolation = true
            DebugLog.log("IntegrityGuard: 로컬 상태 체크섬 불일치 — 외부 조작 흔적 감지")
        }
    }

    /// 도장 (Gym Badges) 마이그레이션 — Stash·Dependency만 소급, 나머지 6 카테고리는 0부터.
    /// `Settings.shared` 초기화가 끝난 뒤 App 시작 훅(`applicationDidFinishLaunching`)에서 1회 호출.
    func applyGymMigrationIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Keys.hasMigratedGymBadges) else { return }
        BadgeRegistry.evaluate(silent: true)
        d.set(true, forKey: Keys.hasMigratedGymBadges)
    }

    /// Contributor PR 보너스 단가 50 → 1,000 상향(v0.6.10) 소급 적용. 이미 적립된
    /// `creditedPRNumbers`의 카운트 × 950(차액)을 1회만 추가 credit. dedup은
    /// `hasMigratedContributorBonusUpgrade` flag — 두 번 실행 안 됨.
    /// `Settings.shared` 재진입 위험 없음(`creditContributorBonusUpgrade`는 단순 credit).
    func applyContributorBonusUpgradeIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Keys.hasMigratedContributorBonusUpgrade) else { return }
        let prCount = creditedPRNumbers.count
        if prCount > 0 {
            CoinLedger.shared.creditContributorBonusUpgrade(prCount: prCount)
        }
        d.set(true, forKey: Keys.hasMigratedContributorBonusUpgrade)
    }

    /// 펫 컬렉션 셋 보너스 마이그레이션 — v0.6.x에 컬렉션 시스템이 추가되기 전부터 펫을
    /// 모은 기존 사용자에게 회고적 보상. 이미 한 그룹의 base 펫(variant 0)을 모두 보유한
    /// 상태면 컴플리트로 등록 + 코인 보너스 + `pendingCollectionHighlights`에 추가
    /// (사용자가 가챠 화면에서 강조 마크로 인지할 수 있도록).
    ///
    /// `silent: true`로 호출 — `pendingCollectionCelebration`(단발성 배너)은 set 안 함.
    /// 다중 컴플리트가 한꺼번에 발생할 수 있어 배너로는 마지막 1개만 노출되는 한계가 있고,
    /// 어차피 첫 launch 시점엔 사용자가 가챠 화면을 안 봤을 가능성이 높음.
    /// 인지는 모두 `pendingCollectionHighlights` 강조에 위임.
    ///
    /// `BadgeRegistry`처럼 `Settings.shared`를 재진입하므로 init 안에서 호출 금지 — App 시작 후 호출.
    func applyCollectionMigrationIfNeeded() {
        let d = UserDefaults.standard
        if !d.bool(forKey: Keys.hasMigratedCollectionBonuses) {
            PetCollectionRegistry.evaluate(silent: true)
            d.set(true, forKey: Keys.hasMigratedCollectionBonuses)
        }
        // On-Call(v0.12.x 신규 컬렉션) 추가 후 1회 재평가 — 이미 멤버를 다 모은 기존 사용자 소급 보너스.
        // evaluate는 completedCollections 미포함 + 완성된 것만 처리하므로 재호출은 안전(중복 지급 없음).
        if !d.bool(forKey: Keys.hasReevaluatedOnCall) {
            PetCollectionRegistry.evaluate(silent: true)
            d.set(true, forKey: Keys.hasReevaluatedOnCall)
        }
    }

    /// 컬렉션 뱃지 클릭 시 호출 — 그 컬렉션의 강조 표시 해제. 비어있으면 no-op.
    /// `acknowledgeHighlight(_ kind: PetKind)`(펫 슬롯)와 동일 패턴.
    func acknowledgeCollectionHighlight(_ rawValue: String) {
        if pendingCollectionHighlights.contains(rawValue) {
            pendingCollectionHighlights.remove(rawValue)
        }
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

    /// `Codable` 값을 JSON으로 인코딩해 `UserDefaults`에 저장. 인코딩 실패는 무시 — 일시적
    /// 메모리 압박 등 transient 실패에 대해 기존 저장값을 보존하는 게 더 안전 (다음 didSet에서
    /// 재시도). Set/Dict didSet에서 매번 호출되는 hot path이지만 사이즈가 작아 부담 없음.
    /// persist 전용 공유 인코더 — didSet hot path에서 매번 JSONEncoder를 새로 만들던 비용 제거
    /// (issue #19-5). Settings는 @MainActor라 persist 호출이 단일 스레드 → 공유 인스턴스 안전.
    private static let persistEncoder = JSONEncoder()
    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? Self.persistEncoder.encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    // MARK: - 펫 파티 조작 (cf. docs/DESIGN_PET_PARTY.md)

    /// 파티 source별 get/set — 3-way 분기를 한 곳에 모아 아래 helper들이 재사용.
    func party(for source: PetChartSource) -> [PetSelection] {
        switch source {
        case .claude: return petClaudeParty
        case .cursor: return petCursorParty
        case .codex:  return petCodexParty
        }
    }
    private func setParty(_ party: [PetSelection], for source: PetChartSource) {
        switch source {
        case .claude: petClaudeParty = party
        case .cursor: petCursorParty = party
        case .codex:  petCodexParty = party
        }
    }

    /// 리더(party[0])의 kind/variant 교체 — 레거시 단수 setter 라우팅용. 파티가 비면 1마리 생성.
    private func setPartyLeader(source: PetChartSource, kind: PetKind? = nil, variant: Int? = nil) {
        var p = party(for: source)
        let dflt: PetKind = source == .cursor ? .wolf : .fox
        if p.isEmpty {
            p = [PetSelection(kind: kind ?? dflt, variant: variant ?? 0)]
        } else {
            if let kind { p[0].kind = kind }
            if let variant { p[0].variant = variant }
        }
        setParty(p, for: source)
    }

    // 아래 source 기반 편집 helper는 "그 소스에 할당된 프리셋"을 편집한다(프리셋 기반 helper로 위임).
    func addToParty(source: PetChartSource, _ sel: PetSelection) { addToPreset(presetID(for: source), sel) }
    func removeFromParty(source: PetChartSource, kind: PetKind) { removeFromPreset(presetID(for: source), kind: kind) }
    func movePartyMember(source: PetChartSource, from: Int, to: Int) { movePresetMember(presetID(for: source), from: from, to: to) }
    func setPartyVariant(source: PetChartSource, kind: PetKind, variant: Int) { setPresetVariant(presetID(for: source), kind: kind, variant: variant) }

    // MARK: - 파티 프리셋 (라이브러리 + 할당)

    func preset(for id: UUID) -> PartyPreset? { partyPresets.first { $0.id == id } }

    /// 프리셋의 members 교체. (petClaudeParty 등 computed setter의 백엔드.)
    func setPresetMembers(_ id: UUID, _ members: [PetSelection]) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        partyPresets[i].members = members
    }

    func presetID(for source: PetChartSource) -> UUID {
        switch source {
        case .claude: return claudePresetID
        case .cursor: return cursorPresetID
        case .codex:  return codexPresetID
        }
    }

    /// 소스에 프리셋 할당. 존재하는 프리셋만 허용.
    func assignPreset(_ id: UUID, to source: PetChartSource) {
        guard partyPresets.contains(where: { $0.id == id }) else { return }
        switch source {
        case .claude: claudePresetID = id
        case .cursor: cursorPresetID = id
        case .codex:  codexPresetID = id
        }
    }

    /// 새 프리셋 추가 후 id 반환.
    @discardableResult
    func addPreset(name: String, members: [PetSelection] = []) -> UUID {
        let p = PartyPreset(id: UUID(), name: name, members: members)
        partyPresets.append(p)
        return p.id
    }

    func renamePreset(_ id: UUID, to name: String) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        partyPresets[i].name = name
    }

    /// 프리셋 삭제. 어떤 소스에 할당돼 있거나 마지막 1개면 거부(소스가 빈 파티로 orphan 되는 것 방지).
    func canDeletePreset(_ id: UUID) -> Bool {
        partyPresets.count > 1
            && claudePresetID != id && cursorPresetID != id && codexPresetID != id
    }
    func deletePreset(_ id: UUID) {
        guard canDeletePreset(id) else { return }
        partyPresets.removeAll { $0.id == id }
    }

    // 프리셋 members 편집 — 종 유니크 + 최대 `maxPartySize`. `members[0]` = 리더.
    func addToPreset(_ id: UUID, _ sel: PetSelection) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        var m = partyPresets[i].members
        guard m.count < Self.maxPartySize, !m.contains(where: { $0.kind == sel.kind }) else { return }
        m.append(sel)
        partyPresets[i].members = m
    }
    func removeFromPreset(_ id: UUID, kind: PetKind) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        partyPresets[i].members.removeAll { $0.kind == kind }
    }
    func movePresetMember(_ id: UUID, from: Int, to: Int) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        var m = partyPresets[i].members
        guard m.indices.contains(from), to >= 0, to < m.count, from != to else { return }
        let item = m.remove(at: from)
        m.insert(item, at: to)
        partyPresets[i].members = m
    }
    func setPresetVariant(_ id: UUID, kind: PetKind, variant: Int) {
        guard let i = partyPresets.firstIndex(where: { $0.id == id }) else { return }
        guard let j = partyPresets[i].members.firstIndex(where: { $0.kind == kind }) else { return }
        partyPresets[i].members[j].variant = variant
    }

    /// GitHub 연결 해제 — 토큰 폐기 + identity 클리어. creditedPRNumbers는 의도적으로 유지
    /// (재연결 시 같은 PR로 중복 지급 방지).
    func disconnectGitHub() {
        Keychain.clearGitHubToken()
        ContributorBonus.shared.updateToken(nil)
        githubLogin = nil
        githubUserID = nil
        githubCreatedAt = nil
    }

    /// GitHub user 식별 정보를 Settings에 영구 반영. 최초 연결(`GitHubLinkView`)과 랭킹 GitHub
    /// 복구(`RankingSectionView`) 두 곳에서 동일하게 3개 필드를 세팅하던 것을 SSOT로 모음.
    /// 새 필드가 추가될 때 두 호출처를 동시에 업데이트해야 했던 회귀 위험을 제거.
    func persistGitHubUser(_ user: GitHubAuth.GitHubUser) {
        githubLogin = user.login
        githubUserID = user.id
        githubCreatedAt = user.createdAt
    }

    /// 랭킹 계정 로컬 상태 클리어. 서버측 데이터 삭제는 별도 `RankingAPI.deleteAccount()` 호출
    /// 후 본 메서드 호출. HMAC 키도 Keychain에서 제거.
    /// `rankingScoreEarnedVP`는 의도적으로 유지 — 누적 VP는 보드 참여와 무관한 사용량 기록.
    /// 재옵트인 시 다시 보드에 보낼 baseline으로 활용 가능.
    func clearRankingLocalState() {
        Keychain.clearRankingHmacKey()
        rankingEnabled = false
        rankingDeviceID = ""
        rankingNickname = ""
        rankingRecoveryCode = nil
        rankingBaselineCoins = 0
        rankingLastSubmittedTotal = 0
        rankingLastSubmittedAt = nil
        rankingRegistered = false
        rankingPrivacyAccepted = false
        rankingUsesZeroBaseline = false
        // 길드 멤버십은 서버 CASCADE로 함께 사라짐 — 표시 캐시도 클리어.
        // guildPermits(생성권)는 로컬 구매 재화라 유지.
        guildID = ""
        guildName = ""
        isGuildLeader = false
    }

    /// 새 디바이스 복구 직후 서버에서 받은 backup payload를 로컬 상태에 적용.
    /// 정책: **로컬-우선 union/max** — 현재 디바이스에 이미 있는 진행도는 절대 후퇴시키지 않는다.
    /// 두 디바이스 사용자가 한쪽에서 진행 → 다른쪽에서 복원하면 양쪽 합집합이 보존되도록.
    ///   - count/coins/coinsTotalEarned: max(local, backup)
    ///   - unlockedVariants/clearedBadges/completedCollections/ownedTitles/creditedPRNumbers/
    ///     claimedPodiumPeriods/pendingHighlights/notifyThresholds: union
    ///   - 펫 선택(kind/variant)·UI 설정(showMenuBar 등)·운세 dot 날짜: backup 값으로 overwrite
    ///     (사용자 현재 설정이 디바이스 종속이라 백업 측 의도가 더 정확)
    ///   - firstCreditedAt: min(local, backup) — 가장 이른 시점 우선
    /// 옵셔널 필드가 nil이면 변경 없음 (옛 클라이언트가 만든 백업 호환).
    func applyBackup(_ b: ProfileState.BackupPayload) {
        // 펫 인벤토리 — count는 max, unlockedVariants는 union.
        if let remote = b.ownedPets {
            var merged = ownedPets
            for (rawKind, remoteOwn) in remote {
                guard let kind = PetKind(rawValue: rawKind) else { continue }
                if var local = merged[kind] {
                    local.count = max(local.count, remoteOwn.count)
                    local.unlockedVariants.formUnion(remoteOwn.unlockedVariants)
                    merged[kind] = local
                } else {
                    merged[kind] = remoteOwn
                }
            }
            ownedPets = merged
        }
        if let remote = b.petUsageSeconds {
            var merged = petUsageSeconds
            for (rawKind, sec) in remote {
                guard let kind = PetKind(rawValue: rawKind) else { continue }
                merged[kind] = max(merged[kind] ?? 0, sec)
            }
            petUsageSeconds = merged
        }
        if let remote = b.pendingHighlights {
            let kinds = remote.compactMap { PetKind(rawValue: $0) }
            pendingHighlights.formUnion(kinds)
        }

        // 펫 선택 — backup 의도 우선.
        if let raw = b.petClaudeKind, let k = PetKind(rawValue: raw) { petClaudeKind = k }
        if let raw = b.petCursorKind, let k = PetKind(rawValue: raw) { petCursorKind = k }
        if let v = b.petClaudeVariant { petClaudeVariant = v }
        if let v = b.petCursorVariant { petCursorVariant = v }

        // 경제 — 누적·잔액은 max로 (양쪽 진행 보존).
        if let v = b.coins { coins = max(coins, v) }
        if let v = b.gachaTickets { gachaTickets = max(gachaTickets, v) }
        if let v = b.premiumTickets { premiumTickets = max(premiumTickets, v) }  // v2, 구버전 nil → no-op
        if let v = b.coinsTotalEarned { coinsTotalEarned = max(coinsTotalEarned, v) }
        if let remote = b.firstCreditedAt {
            firstCreditedAt = firstCreditedAt.map { min($0, remote) } ?? remote
        }

        // dedup 셋 — union. 한쪽에 들어간 적이 있으면 양쪽 다 들어가야 재지급 안 됨.
        if let remote = b.claimedPodiumPeriods { claimedPodiumPeriods.formUnion(remote) }
        if let remote = b.creditedPRNumbers { creditedPRNumbers.formUnion(remote) }
        if let remote = b.completedCollections { completedCollections.formUnion(remote) }
        if let remote = b.clearedBadges { clearedBadges.formUnion(remote) }
        if let remote = b.masteredRegions { masteredRegions.formUnion(remote) }
        if let remote = b.ownedTitles { ownedTitles.formUnion(remote) }

        // 사용자 설정 — backup 의도 우선.
        if let v = b.notifyEnabled { notifyEnabled = v }
        if let remote = b.notifyThresholds {
            notifyThresholds = Array(Set(notifyThresholds).union(remote)).sorted()
        }
        if let v = b.showMenuBar { showMenuBar = v }
        if let v = b.showGitHubLoginInCard { showGitHubLoginInCard = v }

        // 운세 표시 dedup — backup 값 우선.
        if let v = b.dailyFortuneLastShownDate { dailyFortuneLastShownDate = v }
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
        static let experimentalRemotePetMeta = "settings.experimentalRemotePetMeta"
        static let patchNotesEnabled = "settings.patchNotesEnabled"
        static let lastSeenAnnouncementVersion = "settings.lastSeenAnnouncementVersion"
        static let menuBarPetSource = "settings.menuBarPetSource"
        static let petClaudeEnabled = "settings.petClaudeEnabled"
        static let petCursorEnabled = "settings.petCursorEnabled"
        static let petCodexEnabled  = "settings.petCodexEnabled"
        static let petClaudeKind    = "settings.petClaudeKind"
        static let petCursorKind    = "settings.petCursorKind"
        static let themeClaudeOverride = "settings.themeClaudeOverride"
        static let themeCursorOverride = "settings.themeCursorOverride"
        static let themeCodexOverride  = "settings.themeCodexOverride"
        static let bigDropThreshold = "settings.bigDropThreshold"
        // 날씨 이펙트
        static let weatherEffectEnabled = "settings.weatherEffectEnabled"
        static let weatherLocation      = "settings.weatherLocation"
        // Gacha (M2)
        static let coins                       = "settings.coins"
        static let gachaTickets                = "settings.gachaTickets"
        static let premiumTickets              = "settings.premiumTickets"
        static let guildPermits                = "settings.guildPermits"
        static let guildID                     = "settings.guildID"
        static let guildName                   = "settings.guildName"
        static let isGuildLeader               = "settings.isGuildLeader"
        static let integrityChecksumVersion    = "settings.integrityChecksumVersion"
        static let ownedPets                   = "settings.ownedPets"
        // 무결성 가드 (탐지 전용)
        static let integrityChecksum           = "settings.integrityChecksum"
        static let integrityKeyFingerprint     = "settings.integrityKeyFingerprint"
        static let integrityViolation          = "settings.integrityViolation"
        static let petClaudeVariant            = "settings.petClaudeVariant"
        static let petCursorVariant            = "settings.petCursorVariant"
        // 레거시 per-source 파티 (프리셋 도입 전) — 마이그레이션 읽기용으로만 유지.
        static let petClaudeParty              = "settings.petClaudeParty"
        static let petCursorParty              = "settings.petCursorParty"
        static let petCodexParty               = "settings.petCodexParty"
        // 파티 프리셋 (라이브러리 + 소스별 할당).
        static let partyPresets                = "settings.partyPresets"
        static let claudePresetID              = "settings.claudePresetID"
        static let cursorPresetID              = "settings.cursorPresetID"
        static let codexPresetID               = "settings.codexPresetID"
        static let purchasedPartyPresetSlots   = "settings.purchasedPartyPresetSlots"
        static let lastClaudeFiveHourReset     = "settings.lastClaudeFiveHourReset"
        static let lastClaudeSevenDayReset     = "settings.lastClaudeSevenDayReset"
        static let lastCursorEventCredited     = "settings.lastCursorEventCredited"
        static let lastClaudeFiveHourPctSeen   = "settings.lastClaudeFiveHourPctSeen"
        static let lastClaudeSevenDayPctSeen   = "settings.lastClaudeSevenDayPctSeen"
        static let claudeFiveHourCoinFraction  = "settings.claudeFiveHourCoinFraction"
        static let claudeSevenDayCoinFraction  = "settings.claudeSevenDayCoinFraction"
        static let cursorCoinFraction          = "settings.cursorCoinFraction"
        static let lastCodexFiveHourReset      = "settings.lastCodexFiveHourReset"
        static let lastCodexSevenDayReset      = "settings.lastCodexSevenDayReset"
        static let lastCodexMonthlyReset       = "settings.lastCodexMonthlyReset"
        static let lastCodexFiveHourPctSeen    = "settings.lastCodexFiveHourPctSeen"
        static let lastCodexSevenDayPctSeen    = "settings.lastCodexSevenDayPctSeen"
        static let lastCodexMonthlyPctSeen     = "settings.lastCodexMonthlyPctSeen"
        static let codexFiveHourCoinFraction   = "settings.codexFiveHourCoinFraction"
        static let codexSevenDayCoinFraction   = "settings.codexSevenDayCoinFraction"
        static let codexMonthlyCoinFraction    = "settings.codexMonthlyCoinFraction"
        static let hasCompletedGachaMigration  = "settings.hasCompletedGachaMigration"
        static let coinsTotalEarned            = "settings.coinsTotalEarned"
        static let firstCreditedAt             = "settings.firstCreditedAt"
        static let lastWellnessShownAt         = "settings.lastWellnessShownAt"
        static let dailyFortuneLastShownDate   = "settings.dailyFortuneLastShownDate"
        static let dailyQuizLastSolvedDate     = "settings.dailyQuizLastSolvedDate"
        static let githubCreatedAt             = "settings.githubCreatedAt"
        static let petUsageSeconds             = "settings.petUsageSeconds"
        static let pendingHighlights           = "settings.pendingHighlights"
        static let rp                          = "settings.rp"
        static let shinyShards                 = "settings.shinyShards"
        static let hasSeededShardOverflow      = "settings.hasSeededShardOverflow"
        static let rpTotalEarned               = "settings.rpTotalEarned"
        static let petEffects                  = "settings.petEffects"
        static let equippedEffects             = "settings.equippedEffects"
        static let hasReceivedV032TicketBonus  = "settings.hasReceivedV032TicketBonus"
        static let hasReceivedMay2026Bonus     = "settings.hasReceivedMay2026Bonus"
        static let hasReceivedServerInstabilityBonus = "settings.hasReceivedServerInstabilityBonus"
        static let hasResetIntegrityFalsePositive = "settings.hasResetIntegrityFalsePositive"
        // GitHub 기여자 보너스
        static let githubLogin                 = "settings.githubLogin"
        static let githubUserID                = "settings.githubUserID"
        static let creditedPRNumbers           = "settings.creditedPRNumbers"
        // 랭킹 (글로벌 보드)
        static let rankingEnabled              = "settings.rankingEnabled"
        static let rankingDeviceID             = "settings.rankingDeviceID"
        static let rankingNickname             = "settings.rankingNickname"
        static let rankingRecoveryCode         = "settings.rankingRecoveryCode"
        static let rankingBaselineCoins        = "settings.rankingBaselineCoins"
        static let rankingLastSubmittedTotal   = "settings.rankingLastSubmittedTotal"
        static let rankingUsesZeroBaseline     = "settings.rankingUsesZeroBaseline"
        static let rankingLastSubmittedAt      = "settings.rankingLastSubmittedAt"
        static let rankingRegistered           = "settings.rankingRegistered"
        static let rankingPrivacyAccepted      = "settings.rankingPrivacyAccepted"
        static let rankingScoreEarnedVP        = "settings.rankingScoreEarnedVP"
        static let rankingScoreFractionVP      = "settings.rankingScoreFractionVP"
        static let claimedPodiumPeriods        = "settings.claimedPodiumPeriods"
        static let claimedRpRewards            = "settings.claimedRpRewards"
        static let claimedGrants               = "settings.claimedGrants"
        static let cursorLastRequestsSeen      = "settings.cursorLastRequestsSeen"
        static let cursorLastStartOfMonth      = "settings.cursorLastStartOfMonth"
        static let boardLastSeenAt             = "settings.boardLastSeenAt"
        static let myMedalGold                 = "settings.myMedalGold"
        static let myMedalSilver               = "settings.myMedalSilver"
        static let myMedalBronze               = "settings.myMedalBronze"
        // 도장 (Gym Badges)
        static let wellnessRespondedCount      = "settings.wellnessRespondedCount"
        static let rateLimitWeeksPassed        = "settings.rateLimitWeeksPassed"
        static let claudeCoinsEarned           = "settings.claudeCoinsEarned"
        static let cursorCoinsEarned           = "settings.cursorCoinsEarned"
        static let codexCoinsEarned            = "settings.codexCoinsEarned"
        static let heartbeatStreak             = "settings.heartbeatStreak"
        static let heartbeatLastActiveAt       = "settings.heartbeatLastActiveAt"
        static let nightOwlSecondsAccumulated  = "settings.nightOwlSecondsAccumulated"
        static let usageStreak                 = "settings.usageStreak"
        static let usageStreakLastDay          = "settings.usageStreakLastDay"
        static let clearedBadges               = "settings.clearedBadges"
        static let masteredRegions             = "settings.masteredRegions"
        static let creditedBadgeRewards        = "settings.creditedBadgeRewards"
        static let championBadgeEarnedAt       = "settings.championBadgeEarnedAt"
        static let hasViewedGymPage            = "settings.hasViewedGymPage"
        static let hasViewedGuide              = "settings.hasViewedGuide"
        static let hasReceivedCoffeeReward     = "settings.hasReceivedCoffeeReward"
        static let currentTenant               = "settings.currentTenant"
        static let lastTenantPromptAt          = "settings.lastTenantPromptAt"
        static let hasReceivedTenantVerifyBonus = "settings.hasReceivedTenantVerifyBonus"
        static let tenantPromptOptedOut        = "settings.tenantPromptOptedOut"
        static let hasMigratedGymBadges        = "settings.hasMigratedGymBadges"
        // 펫 컬렉션 (셋 보너스)
        static let completedCollections        = "settings.completedCollections"
        static let collectionCompletedAt       = "settings.collectionCompletedAt"
        static let pendingCollectionCelebration = "settings.pendingCollectionCelebration"
        static let pendingCollectionHighlights = "settings.pendingCollectionHighlights"
        static let hasMigratedCollectionBonuses = "settings.hasMigratedCollectionBonuses"
        static let hasReevaluatedOnCall = "settings.hasReevaluatedOnCall"
        static let hasMigratedEffectSlots = "settings.hasMigratedEffectSlots"
        static let hasReceivedLoginApologyTickets = "settings.hasReceivedLoginApologyTickets"
        // 트레이너 카드 (Report 탭)
        static let trainerID                   = "settings.trainerID"
        static let trainerCard                 = "settings.trainerCard"
        static let ownedAccessories            = "settings.ownedAccessories"
        static let ownedTitles                 = "settings.ownedTitles"
        static let ownedThemes                 = "settings.ownedThemes"
        static let gachaInventoryCollapsed     = "settings.gachaInventoryCollapsed"
        static let showGitHubLoginInCard       = "settings.showGitHubLoginInCard"
        static let hasMigratedContributorBonusUpgrade = "settings.hasMigratedContributorBonusUpgrade"
    }
}

/// 메뉴바 위젯이 어느 데이터 출처(Claude / Cursor)의 펫과 사용률을 표시할지.
enum MenuBarPetSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case claude
    case cursor
    case codex

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .codex:  return "Codex"
        }
    }
}

/// 펫 파티 편성/차트 표시의 데이터 출처 (Claude / Cursor / Codex). PartyView·Settings 파티 helper의
/// 3-way 분기 키. MenuBarPetSource(메뉴바 전용, 단일 펫만 표시)와는 의도적으로 분리한다.
enum PetChartSource: String, CaseIterable, Identifiable, Hashable {
    case claude, cursor, codex
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .cursor: return "Cursor"
        case .codex:  return "Codex"
        }
    }
}
