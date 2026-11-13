import Foundation

/// 연말 리캡에 쓰는 사용량 사실들. 스냅샷·이벤트 원본에서 **순수하게** 계산한다(상태 접근 없음).
///
/// 원본 데이터에는 그대로 합산하면 틀리는 함정이 셋 있다 — 각각 테스트가 고정한다.
/// - Claude `resetAt`은 폴링마다 몇 초씩 흔들린다. 같은 창인지는 1시간 넘게 점프했는지로 본다.
/// - Codex 7일 창은 롤링이라 `resetAt`이 계속 밀린다. 창 단위로 묶을 수 없어 연속 스냅샷의
///   % 증가분을 더해 환산한다.
/// - 로그인 직후 등에 %가 비어 있는 행이 섞인다. 값이 없는 행은 건너뛴다.
struct RecapUsageFacts: Equatable {
    struct Peak: Equatable { var pct: Double; var at: Date }

    var firstDay: Date?
    /// 첫 기록일부터 `now`까지 하루 단위 연속 시계열(활동 없는 날은 0).
    var daily: [Double]
    var activeDays: Int
    var longestStreak: Int
    /// 오늘(또는 어제)까지 이어지는 연속 활동 일수.
    var currentStreak: Int
    /// 7일 이동평균이 가장 높았던 날. 하루 최고치보다 차트에서 덜 튄다.
    var peakWeekDay: Date?
    var hours: [Double]      // 24칸
    var weekdays: [Double]   // 7칸, 월요일 = 0

    var claudeWeeklyGauges: Double
    var claudeWeeklyPeak: Peak?
    var claudeFiveHourWallHits: Int
    var codexWeeklyGauges: Double
    var codexWeeklyPeak: Peak?

    var cursorUSD: Double
    var cursorTopModel: String?
    var cursorFirst: Date?
    var cursorLast: Date?

    var goldenHour: Int? { Self.argmax(hours) }
    var busiestWeekday: Int? { Self.argmax(weekdays) }

    /// 같은 창으로 볼 `resetAt` 흔들림 허용치.
    static let windowJitter: TimeInterval = 3600
    /// Codex 7일 % 1포인트를 Claude 5시간 % 몇 포인트로 칠지. 7일 창은 5시간 창보다
    /// 훨씬 크게 잡혀 있어 같은 1%가 더 많은 사용량이다(대략치).
    static let codexWeeklyActivityWeight = 3.0

    static func compute(claude: [UsageSnapshot], codex: [CodexSnapshot], cursor: [CursorEvent],
                        now: Date, calendar: Calendar = .current) -> RecapUsageFacts {
        let claude = claude.sorted { $0.takenAt < $1.takenAt }
        let codex = codex.sorted { $0.takenAt < $1.takenAt }

        // 활동 = % 증가분. Claude는 같은 5시간 창 안에서만, Codex는 롤링이라 연속 행끼리.
        // 빈 행을 먼저 걸러야 한다 — 10 → (빈 행) → 30 을 쌍으로 비교하면 20%p가 사라진다.
        let fiveHour = claude.filter { $0.fiveHourPct != nil && $0.fiveHourResetAt != nil }
        var activity: [(Date, Double)] = []
        for (a, b) in zip(fiveHour, fiveHour.dropFirst()) {
            guard let p0 = a.fiveHourPct, let p1 = b.fiveHourPct, p1 > p0,
                  let r0 = a.fiveHourResetAt, let r1 = b.fiveHourResetAt,
                  abs(r1.timeIntervalSince(r0)) <= windowJitter else { continue }
            activity.append((b.takenAt, p1 - p0))
        }
        let codexWeekly = codex.compactMap { s in s.sevenDayPct.map { (s.takenAt, $0) } }
        var codexBurned = 0.0
        for (a, b) in zip(codexWeekly, codexWeekly.dropFirst()) where b.1 > a.1 {
            codexBurned += b.1 - a.1
            activity.append((b.0, (b.1 - a.1) * codexWeeklyActivityWeight))
        }

        var hours = [Double](repeating: 0, count: 24)
        var weekdays = [Double](repeating: 0, count: 7)
        var byDay: [Date: Double] = [:]
        for (t, v) in activity {
            hours[calendar.component(.hour, from: t)] += v
            weekdays[(calendar.component(.weekday, from: t) + 5) % 7] += v
            byDay[calendar.startOfDay(for: t), default: 0] += v
        }

        let firstDay = [claude.first?.takenAt, codex.first?.takenAt, cursor.map(\.timestamp).min()]
            .compactMap { $0 }.min().map { calendar.startOfDay(for: $0) }
        var daily: [Double] = []
        if let firstDay {
            var d = firstDay
            let end = calendar.startOfDay(for: now)
            while d <= end {
                daily.append(byDay[d] ?? 0)
                guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
                d = next
            }
        }

        var longest = 0, run = 0
        for v in daily { run = v > 0 ? run + 1 : 0; longest = max(longest, run) }
        // 오늘 아직 안 썼으면 어제까지의 연속을 현재 연속으로 본다.
        var current = 0, idx = daily.count - 1
        if idx >= 0, daily[idx] == 0 { idx -= 1 }
        while idx >= 0, daily[idx] > 0 { current += 1; idx -= 1 }

        let smooth = daily.indices.map { i -> Double in
            let lo = max(0, i - 3), hi = min(daily.count - 1, i + 3)
            return daily[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        let peakWeekDay = Self.argmax(smooth).flatMap { i in firstDay.flatMap { calendar.date(byAdding: .day, value: i, to: $0) } }

        let weeklyWindows = Self.windows(claude.compactMap { s in
            guard let p = s.sevenDayPct, let r = s.sevenDayResetAt else { return nil }
            return (s.takenAt, p, r)
        })
        let fiveHourWindows = Self.windows(claude.compactMap { s in
            guard let p = s.fiveHourPct, let r = s.fiveHourResetAt else { return nil }
            return (s.takenAt, p, r)
        })

        let cents = cursor.reduce(0) { $0 + $1.chargedCents }
        let models = Dictionary(grouping: cursor.compactMap(\.model), by: { $0 }).mapValues(\.count)

        return RecapUsageFacts(
            firstDay: firstDay, daily: daily, activeDays: daily.filter { $0 > 0 }.count,
            longestStreak: longest, currentStreak: current, peakWeekDay: peakWeekDay,
            hours: hours, weekdays: weekdays,
            claudeWeeklyGauges: weeklyWindows.reduce(0) { $0 + $1.max } / 100,
            claudeWeeklyPeak: Self.peak(claude.compactMap { s in s.sevenDayPct.map { (s.takenAt, $0) } }),
            claudeFiveHourWallHits: fiveHourWindows.filter { $0.max >= 100 }.count,
            codexWeeklyGauges: codexBurned / 100,
            codexWeeklyPeak: Self.peak(codexWeekly),
            cursorUSD: cents / 100,
            cursorTopModel: models.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key,
            cursorFirst: cursor.map(\.timestamp).min(), cursorLast: cursor.map(\.timestamp).max()
        )
    }

    /// 시간순 (takenAt, pct, resetAt)을 창 단위로 묶는다. resetAt이 직전 창 기준에서
    /// `windowJitter`보다 크게 움직였을 때만 새 창.
    private static func windows(_ rows: [(Date, Double, Date)]) -> [(reset: Date, max: Double)] {
        var out: [(reset: Date, max: Double)] = []
        for (_, p, r) in rows {
            if let last = out.last, abs(r.timeIntervalSince(last.reset)) <= windowJitter {
                out[out.count - 1].max = max(last.max, p)
            } else {
                out.append((r, p))
            }
        }
        return out
    }

    /// 최고치. 같은 값이면 먼저 찍힌 시각.
    private static func peak(_ rows: [(Date, Double)]) -> Peak? {
        rows.reduce(nil as Peak?) { best, row in
            guard let best else { return Peak(pct: row.1, at: row.0) }
            return row.1 > best.pct ? Peak(pct: row.1, at: row.0) : best
        }
    }

    private static func argmax(_ xs: [Double]) -> Int? {
        guard let m = xs.max(), m > 0 else { return nil }
        return xs.firstIndex(of: m)
    }
}

/// 게임 쪽 사실들. 대부분 `Settings`의 누적값이고, 시간 축이 필요한 것만 `RecapLog`에서 온다.
struct RecapGameFacts {
    struct PetHours: Equatable { var kind: PetKind; var hours: Double }

    var pulls: Int
    var speciesOwned: Int
    var rosterSize: Int
    var topDuplicate: (kind: PetKind, count: Int)?
    var shinySpecies: Int
    var prestigeKinds: [PetKind]
    /// 사용 시간 상위 3 — 1위가 "올해의 파트너".
    var partners: [PetHours]
    /// 내레이터 = 트레이너 카드 아바타(유저가 직접 고른 얼굴).
    var narrator: PetSelection
    var collectionsCompleted: Int
    var collectionsTotal: Int
    var firstCollectionAt: Date?
    var lastCollectionAt: Date?
    var badges: Int
    var masteredRegions: Int
    var arenaWins: Int
    var arenaBestRating: Int
    var arenaBestRank: Int?
    var quizCorrect: Int
    var wellnessResponded: Int
    var nightOwlHours: Int
    var prBonuses: Int
    var guildName: String?
    var isGuildLeader: Bool
    var nickname: String
    /// 도구별 누적 코인 — "claude" / "codex" / "cursor".
    var coinsBySource: [String: Int]
    var events: [RecapEvent]

    @MainActor
    static func gather(_ settings: Settings? = nil, events: [RecapEvent]? = nil) -> RecapGameFacts {
        let s = settings ?? .shared
        let events = events ?? RecapLog.loadAll()
        let owned = s.ownedPets
        let top = owned.max { a, b in a.value.count != b.value.count ? a.value.count < b.value.count : a.key.rawValue > b.key.rawValue }
        let partners = s.petUsageSeconds.sorted { a, b in a.value != b.value ? a.value > b.value : a.key.rawValue < b.key.rawValue }
            .prefix(3).map { PetHours(kind: $0.key, hours: $0.value / 3600) }
        let shinyTiers: Set<Int> = [1, 2, 3]
        let completed = s.collectionCompletedAt.values
        return RecapGameFacts(
            pulls: owned.values.reduce(0) { $0 + $1.count },
            speciesOwned: owned.count,
            rosterSize: Gacha.pool.values.reduce(0) { $0 + $1.count },
            topDuplicate: top.map { ($0.key, $0.value.count) },
            shinySpecies: owned.values.filter { !$0.unlockedVariants.isDisjoint(with: shinyTiers) }.count,
            prestigeKinds: owned.filter { $0.value.unlockedVariants.contains(PetOwnership.prestigeVariant) }
                .map(\.key).sorted { $0.rawValue < $1.rawValue },
            partners: Array(partners),
            narrator: s.trainerCard.avatar,
            collectionsCompleted: s.completedCollections.count,
            collectionsTotal: PetCollection.allCases.count,
            firstCollectionAt: completed.min(), lastCollectionAt: completed.max(),
            badges: s.clearedBadges.count,
            masteredRegions: s.masteredRegions.count,
            arenaWins: s.pvpWinsCache,
            arenaBestRating: s.pvpBestRating,
            arenaBestRank: s.pvpBestRank == Int.max ? nil : s.pvpBestRank,
            quizCorrect: s.dailyQuizCorrectTotal,
            wellnessResponded: s.wellnessRespondedCount,
            nightOwlHours: s.nightOwlSecondsAccumulated / 3600,
            prBonuses: s.creditedPRNumbers.count,
            guildName: s.guildName.isEmpty ? nil : s.guildName,
            isGuildLeader: s.isGuildLeader,
            nickname: s.rankingNickname,
            coinsBySource: ["claude": s.claudeCoinsEarned, "codex": s.codexCoinsEarned, "cursor": s.cursorCoinsEarned],
            events: events
        )
    }
}

struct RecapFacts {
    var usage: RecapUsageFacts
    var game: RecapGameFacts

    /// 로컬 저장소 전체를 읽는다. JSONL 전체 스캔이라 창을 열 때 한 번만 부를 것.
    @MainActor
    static func load(now: Date = Date()) -> RecapFacts {
        let usage = RecapUsageFacts.compute(
            claude: SnapshotStore.claude.loadRecent(limit: 200_000),
            codex: SnapshotStore.codex.loadRecent(limit: 200_000),
            cursor: SnapshotStore.cursorEvents.loadRecent(limit: 200_000),
            now: now)
        return RecapFacts(usage: usage, game: .gather())
    }
}
