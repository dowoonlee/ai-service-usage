import Foundation

// 도장 (Gym Badges) 데이터 모델 + 평가 엔진.
//
// 32 뱃지 = 4 region × 2 카테고리 × 4 tier. 클리어 시 tier별 차등 코인 보너스.
// 사용자 plan에서 가능한 모든 카테고리(예: Pro/Free는 Cursor 잠금이라 28개)를 풀 클리어하면
// 챔피언 뱃지(33번째) 자동 획득 + 5,000 coin 보너스.
//
// metric은 `Settings`의 카운터/기존 필드에서 읽고, 임계 통과한 뱃지만 새로 클리어 처리한다.
// `evaluate()`는 polling cycle 끝 / 사용자 액션(wellness 응답) 직후에 호출.

enum BadgeTier: String, CaseIterable, Codable, Comparable {
    case localhost, dev, staging, production

    static func < (lhs: BadgeTier, rhs: BadgeTier) -> Bool {
        lhs.sortIndex < rhs.sortIndex
    }

    private var sortIndex: Int {
        switch self {
        case .localhost: return 0
        case .dev: return 1
        case .staging: return 2
        case .production: return 3
        }
    }

    var displayName: String {
        switch self {
        case .localhost:  return "localhost"
        case .dev:        return "dev"
        case .staging:    return "staging"
        case .production: return "production"
        }
    }

    /// 클리어 시 받는 코인. production은 마스터급.
    var coinReward: Int {
        switch self {
        case .localhost:  return 50
        case .dev:        return 150
        case .staging:    return 500
        case .production: return 1500
        }
    }
}

/// 대륙 — 본토(mainland) + 클라우드 제도(cloud). 챔피언을 대륙별로 분해해
/// region 증가에도 gold 프레임/챔피언 도달성을 유지한다(gym-map-redesign.md).
enum GymContinent: String, CaseIterable, Codable {
    case mainland, cloud

    var displayName: String {
        switch self {
        case .mainland: return "본토"
        case .cloud:    return "클라우드 제도"
        }
    }

    var regions: [BadgeRegion] {
        BadgeRegion.allCases.filter { $0.continent == self }
    }
}

enum BadgeRegion: String, CaseIterable, Codable {
    case coffee, vibe, cron, repo, registry   // 본토
    case arena, guild, daily, oss              // 클라우드 제도

    var continent: GymContinent {
        switch self {
        case .coffee, .vibe, .cron, .repo, .registry: return .mainland
        case .arena, .guild, .daily, .oss:            return .cloud
        }
    }

    var displayName: String {
        switch self {
        case .coffee:   return "Coffee"
        case .vibe:     return "Vibe"
        case .cron:     return "Cron"
        case .repo:     return "Repo"
        case .registry: return "Registry"
        case .arena:    return "Arena"
        case .guild:    return "Guild"
        case .daily:    return "Daily"
        case .oss:      return "OSS"
        }
    }

    /// 메뉴 아이콘 (SF Symbol — fallback / 콤팩트 표시용).
    var systemImage: String {
        switch self {
        case .coffee:   return "cup.and.saucer.fill"
        case .vibe:     return "cpu"
        case .cron:     return "clock.badge.fill"
        case .repo:     return "archivebox.fill"
        case .registry: return "square.stack.3d.up.fill"
        case .arena:    return "flag.checkered.2.crossed"
        case .guild:    return "person.3.fill"
        case .daily:    return "sun.max.fill"
        case .oss:      return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 도장 페이지 region 그리드용 픽셀 아이콘 (pixelarticons MIT).
    /// 클라우드 제도 region은 우선 기존 아이콘을 재활용(추후 전용 아이콘으로 교체 가능).
    var pixelIcon: PixelIcon {
        switch self {
        case .coffee:   return RegionPixelIcons.coffee
        case .vibe:     return RegionPixelIcons.robotFace
        case .cron:     return RegionPixelIcons.clock
        case .repo:     return RegionPixelIcons.warehouse
        case .registry: return RegionPixelIcons.registry
        case .arena:    return RegionPixelIcons.robotFace
        case .guild:    return RegionPixelIcons.warehouse
        case .daily:    return RegionPixelIcons.clock
        case .oss:      return RegionPixelIcons.registry
        }
    }

    var categories: [BadgeCategory] {
        switch self {
        case .coffee:   return [.standup, .rateLimit]
        case .vibe:     return [.claude, .cursor, .codex]
        case .cron:     return [.heartbeat, .nightOwl]
        case .repo:     return [.stash, .dependency]
        case .registry: return [.monorepo, .fork]
        case .arena:    return [.arenaWins, .arenaRating]
        case .guild:    return [.guildContribution, .guildTenure]
        case .daily:    return [.dailyQuizCorrect, .dailyRitual]
        case .oss:      return [.pullRequest, .bugHunter]
        }
    }
}

enum BadgeCategory: String, CaseIterable, Codable {
    case standup, rateLimit, claude, cursor, heartbeat, nightOwl, stash, dependency
    case codex, monorepo, fork
    // 클라우드 제도 (gym-expansion.md §5.1)
    case arenaWins, arenaRating, guildContribution, guildTenure
    case dailyQuizCorrect, dailyRitual, pullRequest, bugHunter

    var displayName: String {
        switch self {
        case .standup:    return "Standup"
        case .rateLimit:  return "Rate Limit"
        case .claude:     return "Claude"
        case .cursor:     return "Cursor"
        case .heartbeat:  return "Heartbeat"
        case .nightOwl:   return "Night Owl"
        case .stash:      return "Stash"
        case .dependency: return "Dependency"
        case .codex:      return "Codex"
        case .monorepo:   return "Monorepo"
        case .fork:       return "Fork"
        case .arenaWins:        return "Duelist"
        case .arenaRating:      return "Ladder"
        case .guildContribution: return "Contribution"
        case .guildTenure:      return "Tenure"
        case .dailyQuizCorrect: return "Quiz"
        case .dailyRitual:      return "Ritual"
        case .pullRequest:      return "Pull Request"
        case .bugHunter:        return "Bug Hunter"
        }
    }

    var region: BadgeRegion {
        switch self {
        case .standup, .rateLimit:   return .coffee
        case .claude, .cursor, .codex: return .vibe
        case .heartbeat, .nightOwl:  return .cron
        case .stash, .dependency:    return .repo
        case .monorepo, .fork:       return .registry
        case .arenaWins, .arenaRating:          return .arena
        case .guildContribution, .guildTenure:  return .guild
        case .dailyQuizCorrect, .dailyRitual:   return .daily
        case .pullRequest, .bugHunter:          return .oss
        }
    }

    /// 보석 sprite (SF Symbol placeholder — 추후 픽셀 sprite로 교체 가능).
    var systemImage: String {
        switch self {
        case .standup:    return "figure.flexibility"
        case .rateLimit:  return "tachometer.medium"
        case .claude:     return "sparkle"
        case .cursor:     return "cursorarrow.rays"
        case .heartbeat:  return "waveform.path.ecg"
        case .nightOwl:   return "moon.stars.fill"
        case .stash:      return "dollarsign.circle.fill"
        case .dependency: return "books.vertical.fill"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        case .monorepo:   return "square.stack.3d.down.right.fill"
        case .fork:       return "arrow.triangle.branch"
        case .arenaWins:        return "trophy.fill"
        case .arenaRating:      return "chart.line.uptrend.xyaxis"
        case .guildContribution: return "person.3.fill"
        case .guildTenure:      return "calendar"
        case .dailyQuizCorrect: return "questionmark.circle.fill"
        case .dailyRitual:      return "flame.fill"
        case .pullRequest:      return "arrow.triangle.pull"
        case .bugHunter:        return "ant.fill"
        }
    }

    /// 보석 색.
    var gemColorHex: String {
        switch self {
        case .standup:    return "#E8E8E8"   // Pearl
        case .rateLimit:  return "#4A8FE7"   // Sapphire
        case .claude:     return "#9D4EDD"   // Amethyst
        case .cursor:     return "#3FA796"   // Emerald
        case .heartbeat:  return "#E64B4B"   // Ruby
        case .nightOwl:   return "#9DBCEC"   // Opal
        case .stash:      return "#FFC93C"   // Gold
        case .dependency: return "#A0E7E5"   // Diamond
        case .codex:      return "#FEB731"   // Amber
        case .monorepo:   return "#8AD412"   // Peridot
        case .fork:       return "#CE0000"   // Garnet
        case .arenaWins:        return "#E64B4B"   // Ruby
        case .arenaRating:      return "#4A8FE7"   // Sapphire
        case .guildContribution: return "#FFC93C"  // Gold
        case .guildTenure:      return "#A0E7E5"   // Diamond
        case .dailyQuizCorrect: return "#9D4EDD"   // Amethyst
        case .dailyRitual:      return "#FEB731"   // Amber
        case .pullRequest:      return "#3FA796"   // Emerald
        case .bugHunter:        return "#8AD412"   // Peridot
        }
    }

    /// gem 색 luminance에 따라 보석 위 SF Symbol overlay 색 결정.
    /// 어두운 보석(Sapphire/Amethyst/Emerald/Ruby)은 흰 symbol, 밝은 보석(Pearl/Opal/Gold/Diamond)은 검정.
    var gemSymbolDark: Bool {
        switch self {
        case .standup, .nightOwl, .stash, .dependency: return true   // 검정 symbol
        case .codex, .monorepo:                        return true   // Amber/Peridot 밝음 → 검정
        case .rateLimit, .claude, .cursor, .heartbeat: return false  // 흰 symbol
        case .fork:                                    return false  // Garnet 어두움 → 흰
        case .guildContribution, .guildTenure, .dailyRitual, .bugHunter: return true  // 밝은 보석 → 검정
        case .arenaWins, .arenaRating, .dailyQuizCorrect, .pullRequest:  return false // 어두운 보석 → 흰
        }
    }

    /// 카테고리별 풀컬러 픽셀 sprite (Intersect-Assets, CC BY-SA 3.0).
    /// PNG 32×32, `Resources/intersect-jewels/` 안. nil 반환 case 없음.
    var jewelSpriteName: String {
        switch self {
        case .standup:    return "Jewel_Pearl"
        case .rateLimit:  return "Jewel_Sapphire"
        case .claude:     return "Jewel_Amethyst"
        case .cursor:     return "Jewel_Emerald"
        case .heartbeat:  return "Jewel_Ruby"
        case .nightOwl:   return "Jewel_Opal"
        case .stash:      return "Coins_Gold"
        case .dependency: return "Jewel_Diamond"
        case .codex:      return "Jewel_Amber"
        case .monorepo:   return "Jewel_Peridot"
        case .fork:       return "Jewel_Garnet"
        case .arenaWins:        return "Jewel_Ruby"
        case .arenaRating:      return "Jewel_Sapphire"
        case .guildContribution: return "Coins_Gold"
        case .guildTenure:      return "Jewel_Diamond"
        case .dailyQuizCorrect: return "Jewel_Amethyst"
        case .dailyRitual:      return "Jewel_Amber"
        case .pullRequest:      return "Jewel_Emerald"
        case .bugHunter:        return "Jewel_Peridot"
        }
    }

    /// metric 단위 표기 (호버 tooltip용).
    var unit: String {
        switch self {
        case .standup:    return "회 응답"
        case .rateLimit:  return "주 통과"
        case .claude:     return "코인"
        case .cursor:     return "코인"
        case .heartbeat:  return "일 연속"
        case .nightOwl:   return "시간"
        case .stash:      return "코인"
        case .dependency: return "종 보유"
        case .codex:      return "코인"
        case .monorepo:   return "종 완성"
        case .fork:       return "개 해금"
        case .arenaWins:        return "승"
        case .arenaRating:      return "rating"
        case .guildContribution: return "기여"
        case .guildTenure:      return "일"
        case .dailyQuizCorrect: return "정답"
        case .dailyRitual:      return "일 streak"
        case .pullRequest:      return "PR"
        case .bugHunter:        return "리포트"
        }
    }

    /// 4 tier 임계값. 양 끝 invariant: t1 < t2 < t3 < t4.
    /// 곡선은 카테고리마다 의도적으로 다름 (지수형 / 가혹 / 느린 등정 등).
    var thresholds: [BadgeTier: Int] {
        switch self {
        case .standup:    return [.localhost: 3,  .dev: 15,  .staging: 50,    .production: 100]
        case .rateLimit:  return [.localhost: 1,  .dev: 3,   .staging: 8,     .production: 16]
        case .claude:     return [.localhost: 50, .dev: 500, .staging: 2_500, .production: 10_000]
        case .cursor:     return [.localhost: 50, .dev: 500, .staging: 2_500, .production: 10_000]
        case .heartbeat:  return [.localhost: 3,  .dev: 14,  .staging: 60,    .production: 100]
        case .nightOwl:   return [.localhost: 3,  .dev: 20,  .staging: 80,    .production: 200]   // 시간(h)
        case .stash:      return [.localhost: 100, .dev: 1_000, .staging: 5_000, .production: 25_000]
        case .dependency: return [.localhost: 3,  .dev: 15,  .staging: 40,    .production: 70]
        case .codex:      return [.localhost: 50, .dev: 500, .staging: 2_500, .production: 10_000]
        case .monorepo:   return [.localhost: 1,  .dev: 4,   .staging: 8,     .production: 13]   // 전 컬렉션 13
        case .fork:       return [.localhost: 3,  .dev: 10,  .staging: 30,    .production: 80]   // shiny variant 해금
        case .arenaWins:         return [.localhost: 1,    .dev: 10,    .staging: 50,    .production: 200]
        case .arenaRating:       return [.localhost: 1000, .dev: 1200,  .staging: 1400,  .production: 1600]
        case .guildContribution: return [.localhost: 100,  .dev: 1_000, .staging: 5_000, .production: 20_000]
        case .guildTenure:       return [.localhost: 7,    .dev: 30,    .staging: 90,    .production: 180]
        case .dailyQuizCorrect:  return [.localhost: 5,    .dev: 30,    .staging: 100,   .production: 365]
        case .dailyRitual:       return [.localhost: 3,    .dev: 14,    .staging: 60,    .production: 180]
        case .pullRequest:       return [.localhost: 1,    .dev: 3,     .staging: 10,    .production: 25]
        case .bugHunter:         return [.localhost: 1,    .dev: 3,     .staging: 8,     .production: 20]
        }
    }

    /// 현재 metric 값을 Settings에서 읽어옴.
    @MainActor
    func currentValue(_ s: Settings) -> Int {
        switch self {
        case .standup:    return s.wellnessRespondedCount
        case .rateLimit:  return s.rateLimitWeeksPassed
        case .claude:     return s.claudeCoinsEarned
        case .cursor:     return s.cursorCoinsEarned
        case .heartbeat:  return s.heartbeatStreak
        case .nightOwl:   return s.nightOwlSecondsAccumulated / 3600
        case .stash:      return s.coinsTotalEarned
        case .dependency: return s.ownedPets.count
        case .codex:      return s.codexCoinsEarned
        case .monorepo:   return s.completedCollections.count
        case .fork:       return s.ownedPets.values.reduce(0) { $0 + $1.unlockedVariants.filter { $0 > 0 }.count }
        case .arenaWins:         return s.pvpWinsCache
        case .arenaRating:       return s.pvpBestRating
        case .guildContribution: return s.guildContributionTotal
        case .guildTenure:
            guard let joined = s.guildJoinedAt else { return 0 }
            return Calendar.current.dateComponents([.day], from: joined, to: Date()).day ?? 0
        case .dailyQuizCorrect:  return s.dailyQuizCorrectTotal
        case .dailyRitual:       return s.dailyRitualStreak
        case .pullRequest:       return s.creditedPRNumbers.count
        case .bugHunter:         return s.bugReportCount
        }
    }

    /// 사용자 plan에서 진행 가능한지. Cursor 카테고리는 Cursor Ultra 사용자만.
    /// 단, snapshot 기준이 아니라 "이 사용자가 Cursor coin을 한 번이라도 받은 적 있는지"로 판단.
    @MainActor
    func isAvailable(_ s: Settings) -> Bool {
        switch self {
        // codex는 무료 플랜도 있어 '잠금'이 아니라 '미진행' — 항상 진행 가능(진척/챔피언 분모 포함).
        // cursor만 Ultra(유료) 전용이라 미사용 시 잠금(분모 제외).
        case .cursor: return s.cursorCoinsEarned > 0 || hasUltraEverHinted(s)
        default:      return true
        }
    }

    /// 잠긴 카테고리(isAvailable=false) 호버 시 표시할 사유. (현재는 cursor만 잠금 가능)
    var lockReason: String {
        switch self {
        case .cursor: return "Cursor Ultra 사용자 전용"
        default:      return "아직 잠겨 있습니다"
        }
    }

    /// Cursor 카테고리의 잠금 판정 보조 — 첫 진입에 0이라도 잠긴 게 아니라 *진행 중*으로 보여줌.
    /// 진짜 Pro/Free는 영영 0이라 사실상 잠금 표시되지만 임계 0 셀이라 lcoalhost는 즉시 클리어 안 됨.
    @MainActor
    private func hasUltraEverHinted(_ s: Settings) -> Bool {
        // 향후 plan 정보 직접 노출되면 교체. 현재는 단순히 cursor coin 누적 여부로 판단.
        return s.cursorCoinsEarned > 0
    }
}

struct BadgeID: Hashable, Codable {
    let category: BadgeCategory
    let tier: BadgeTier

    var key: String { "\(category.rawValue).\(tier.rawValue)" }
}

@MainActor
enum BadgeRegistry {
    /// 모든 32 뱃지. 순수 enum 조합이라 `nonisolated` — MainActor 의존 없음.
    nonisolated static var allBadges: [BadgeID] {
        BadgeCategory.allCases.flatMap { cat in
            BadgeTier.allCases.map { BadgeID(category: cat, tier: $0) }
        }
    }

    /// 대륙 챔피언 보너스.
    static let championCoinReward = 3_000
    /// Grand Champion — 모든 대륙 정복 보너스.
    static let grandChampionCoinReward = 10_000

    /// polling cycle 끝 / 사용자 액션 후 호출.
    /// 새로 임계 통과한 뱃지를 모두 클리어 처리하고 (코인 보너스 + 알림), 챔피언 조건도 평가.
    /// migration 흐름에서 알림 없이 silent 클리어가 필요할 땐 `silent: true`.
    static func evaluate(silent: Bool = false) {
        let s = Settings.shared
        var newlyCleared: [BadgeID] = []

        for cat in BadgeCategory.allCases {
            let value = cat.currentValue(s)
            for tier in BadgeTier.allCases {
                let id = BadgeID(category: cat, tier: tier)
                if s.clearedBadges.contains(id.key) { continue }
                guard let threshold = cat.thresholds[tier] else { continue }
                if value >= threshold {
                    s.clearedBadges.insert(id.key)
                    // 보상 dedup — 한 번 코인 받은 뱃지는 clearedBadges가 어떤 이유로 리셋돼도 재지급 X.
                    if !s.creditedBadgeRewards.contains(id.key) {
                        CoinLedger.shared.creditBonus(tier.coinReward, reason: "badge.\(id.key)")
                        s.creditedBadgeRewards.insert(id.key)
                        newlyCleared.append(id)
                    } else {
                        DebugLog.log("Badge re-cleared: \(id.key) (이미 보상 지급됨, skip)")
                    }
                }
            }
        }

        if !newlyCleared.isEmpty && !silent {
            NotificationManager.shared.badgesCleared(ids: newlyCleared)
        }

        // 대륙별 챔피언 — region 증가에도 도달성 유지(gym-map-redesign.md).
        // championBadgeEarnedAt은 '본토 챔피언'으로 의미 승계(기존 전체 달성자는 본토도 완료라 그대로 유지).
        if s.championBadgeEarnedAt == nil && isChampionEarned(s, continent: .mainland) {
            s.championBadgeEarnedAt = Date()
            CoinLedger.shared.creditBonus(championCoinReward, reason: "badge.champion.mainland")
            if !silent { NotificationManager.shared.championEarned() }
        }
        if s.cloudChampionAt == nil && isChampionEarned(s, continent: .cloud) {
            s.cloudChampionAt = Date()
            s.premiumTickets += 2
            CoinLedger.shared.creditBonus(championCoinReward, reason: "badge.champion.cloud")
            if !silent { NotificationManager.shared.championEarned() }
        }
        // Grand Champion — 모든 대륙 정복.
        if s.grandChampionAt == nil,
           GymContinent.allCases.allSatisfy({ isChampionEarned(s, continent: $0) }) {
            s.grandChampionAt = Date()
            CoinLedger.shared.creditBonus(grandChampionCoinReward, reason: "badge.champion.grand")
            if !silent { NotificationManager.shared.championEarned() }
        }

        // 지역 마스터 — 한 region의 (가능한) 모든 도장 클리어 시 프리미엄 가챠권 1장. dedup으로 1회만.
        for region in BadgeRegion.allCases where !s.masteredRegions.contains(region.rawValue) {
            guard isRegionMastered(region, s) else { continue }
            s.masteredRegions.insert(region.rawValue)
            s.premiumTickets += 1
            DebugLog.log("Region mastered: \(region.rawValue) → +1 premium ticket (total=\(s.premiumTickets))")
            if !silent {
                NotificationManager.shared.regionMastered(region: region)
            }
        }
    }

    /// 한 지역의 (사용자 plan에서 가능한) 모든 카테고리×tier 클리어 검사. `isChampionEarned`의 region 한정 버전.
    static func isRegionMastered(_ region: BadgeRegion, _ s: Settings) -> Bool {
        let avail = region.categories.filter { $0.isAvailable(s) }
        guard !avail.isEmpty else { return false }   // 전부 잠긴 지역은 마스터 대상 아님
        for cat in avail {
            for tier in BadgeTier.allCases where !s.clearedBadges.contains(BadgeID(category: cat, tier: tier).key) {
                return false
            }
        }
        return true
    }

    /// 특정 대륙의 (사용자 plan에서 가능한) 모든 카테고리×tier 클리어 검사.
    /// 전부 잠긴 대륙은 챔피언 대상 아님(anyAvailable=false).
    static func isChampionEarned(_ s: Settings, continent: GymContinent) -> Bool {
        var anyAvailable = false
        for region in continent.regions {
            for cat in region.categories where cat.isAvailable(s) {
                anyAvailable = true
                for tier in BadgeTier.allCases {
                    if !s.clearedBadges.contains(BadgeID(category: cat, tier: tier).key) { return false }
                }
            }
        }
        return anyAvailable
    }

    /// 전체(모든 대륙) 챔피언 — 하위 호환용.
    static func isChampionEarned(_ s: Settings) -> Bool {
        GymContinent.allCases.allSatisfy { isChampionEarned(s, continent: $0) }
    }

    /// 특정 region 진행도 (cleared / total). 잠긴 카테고리는 분모에서 제외해서 표시.
    static func progress(forRegion region: BadgeRegion, _ s: Settings) -> (cleared: Int, total: Int) {
        progress(forCategories: region.categories, s)
    }

    /// 전체 진행도.
    static func totalProgress(_ s: Settings) -> (cleared: Int, total: Int) {
        progress(forCategories: BadgeCategory.allCases, s)
    }

    /// 잠긴 카테고리는 분모에서 제외하고 (cleared / total) 집계 — region/전체가 공유.
    private static func progress(forCategories categories: [BadgeCategory], _ s: Settings) -> (cleared: Int, total: Int) {
        var cleared = 0
        var total = 0
        for cat in categories where cat.isAvailable(s) {
            for tier in BadgeTier.allCases {
                total += 1
                if s.clearedBadges.contains(BadgeID(category: cat, tier: tier).key) {
                    cleared += 1
                }
            }
        }
        return (cleared, total)
    }
}
