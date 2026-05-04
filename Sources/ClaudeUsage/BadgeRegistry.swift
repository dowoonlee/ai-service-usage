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
        Self.allCases.firstIndex(of: lhs)! < Self.allCases.firstIndex(of: rhs)!
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

enum BadgeRegion: String, CaseIterable, Codable {
    case coffee, vibe, cron, repo

    var displayName: String {
        switch self {
        case .coffee: return "Coffee"
        case .vibe:   return "Vibe"
        case .cron:   return "Cron"
        case .repo:   return "Repo"
        }
    }

    /// 메뉴 아이콘 (SF Symbol — fallback / 콤팩트 표시용).
    var systemImage: String {
        switch self {
        case .coffee: return "cup.and.saucer.fill"
        case .vibe:   return "cpu"
        case .cron:   return "clock.badge.fill"
        case .repo:   return "archivebox.fill"
        }
    }

    /// 도장 페이지 region 그리드용 픽셀 아이콘 (pixelarticons MIT).
    var pixelIcon: PixelIcon {
        switch self {
        case .coffee: return RegionPixelIcons.coffee
        case .vibe:   return RegionPixelIcons.robotFace
        case .cron:   return RegionPixelIcons.clock
        case .repo:   return RegionPixelIcons.warehouse
        }
    }

    var categories: [BadgeCategory] {
        switch self {
        case .coffee: return [.standup, .rateLimit]
        case .vibe:   return [.claude, .cursor]
        case .cron:   return [.heartbeat, .nightOwl]
        case .repo:   return [.stash, .dependency]
        }
    }
}

enum BadgeCategory: String, CaseIterable, Codable {
    case standup, rateLimit, claude, cursor, heartbeat, nightOwl, stash, dependency

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
        }
    }

    var region: BadgeRegion {
        switch self {
        case .standup, .rateLimit:   return .coffee
        case .claude, .cursor:       return .vibe
        case .heartbeat, .nightOwl:  return .cron
        case .stash, .dependency:    return .repo
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
        }
    }

    /// gem 색 luminance에 따라 보석 위 SF Symbol overlay 색 결정.
    /// 어두운 보석(Sapphire/Amethyst/Emerald/Ruby)은 흰 symbol, 밝은 보석(Pearl/Opal/Gold/Diamond)은 검정.
    var gemSymbolDark: Bool {
        switch self {
        case .standup, .nightOwl, .stash, .dependency: return true   // 검정 symbol
        case .rateLimit, .claude, .cursor, .heartbeat: return false  // 흰 symbol
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
        }
    }

    /// 사용자 plan에서 진행 가능한지. Cursor 카테고리는 Cursor Ultra 사용자만.
    /// 단, snapshot 기준이 아니라 "이 사용자가 Cursor coin을 한 번이라도 받은 적 있는지"로 판단.
    @MainActor
    func isAvailable(_ s: Settings) -> Bool {
        switch self {
        case .cursor: return s.cursorCoinsEarned > 0 || hasUltraEverHinted(s)
        default:      return true
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
    /// 모든 32 뱃지.
    static var allBadges: [BadgeID] {
        BadgeCategory.allCases.flatMap { cat in
            BadgeTier.allCases.map { BadgeID(category: cat, tier: $0) }
        }
    }

    /// 챔피언 보너스 (33번째).
    static let championCoinReward = 3_000

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
                    s.coins += tier.coinReward
                    s.coinsTotalEarned += tier.coinReward
                    newlyCleared.append(id)
                    DebugLog.log("Badge cleared: \(id.key) → +\(tier.coinReward) coin")
                }
            }
        }

        if !newlyCleared.isEmpty && !silent {
            NotificationManager.shared.badgesCleared(ids: newlyCleared)
        }

        // 챔피언 평가 — 사용자 plan에서 가능한 모든 카테고리×tier 풀세트면 획득.
        if s.championBadgeEarnedAt == nil && isChampionEarned(s) {
            s.championBadgeEarnedAt = Date()
            s.coins += championCoinReward
            s.coinsTotalEarned += championCoinReward
            DebugLog.log("Champion badge earned → +\(championCoinReward) coin")
            if !silent {
                NotificationManager.shared.championEarned()
            }
        }
    }

    /// "사용자 plan에서 가능한 모든 카테고리 풀세트 클리어" 검사.
    /// Cursor 잠금 사용자(Pro/Free)는 cursor 4셀 제외하고 28/28 클리어로 인정.
    static func isChampionEarned(_ s: Settings) -> Bool {
        for cat in BadgeCategory.allCases {
            guard cat.isAvailable(s) else { continue }
            for tier in BadgeTier.allCases {
                let id = BadgeID(category: cat, tier: tier)
                if !s.clearedBadges.contains(id.key) { return false }
            }
        }
        return true
    }

    /// 특정 region 진행도 (cleared / total). 잠긴 카테고리는 분모에서 제외해서 표시.
    static func progress(forRegion region: BadgeRegion, _ s: Settings) -> (cleared: Int, total: Int) {
        var cleared = 0
        var total = 0
        for cat in region.categories where cat.isAvailable(s) {
            for tier in BadgeTier.allCases {
                total += 1
                if s.clearedBadges.contains(BadgeID(category: cat, tier: tier).key) {
                    cleared += 1
                }
            }
        }
        return (cleared, total)
    }

    /// 전체 진행도.
    static func totalProgress(_ s: Settings) -> (cleared: Int, total: Int) {
        var cleared = 0
        var total = 0
        for cat in BadgeCategory.allCases where cat.isAvailable(s) {
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
