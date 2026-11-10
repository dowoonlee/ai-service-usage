import Foundation
import CoreGraphics

// ============================================================================
// 시즌 이벤트 — 데이터 모델 (cf. docs/plans/seasonal-events.md §1)
// ============================================================================
//
// 시즌은 **데이터**다. 렌더러·대사·상점은 `SeasonRegistry.active()`가 돌려주는 `Season`의 필드만 읽고,
// 날짜는 절대 직접 보지 않는다(소비자 코드에 `Calendar`/`Date` 비교가 나오면 리뷰에서 반려).
// 새 시즌(할로윈·벚꽃)은 `SeasonRegistry.all`에 리터럴 하나 + 리소스 PNG + 대사 10줄로 끝나야 한다 —
// 그 이상 코드를 건드려야 하면 추상화가 새는 신호.
//
// 규칙:
//   * `Season.Kind` case는 **삭제 금지** — 저장된 rawValue(seasonalFlags 등)가 깨진다. 폐지는 `all`에서만 뺀다.
//   * 1회성 지급 dedup은 `instanceID`(연도 포함), 코스메틱 노출 판정은 `id`(연도 없음).
//   * 시즌 창은 서로 겹치지 않는다(테스트가 고정). 동시에 활성인 시즌은 최대 1개.

/// 시즌 창. 날짜 경계는 **KST** — 서버 보상(`reward_grants`)·퀴즈·잔디와 같은 날짜선을 쓴다.
struct SeasonWindow: Equatable {
    struct MonthDay: Equatable, Comparable {
        let month: Int
        let day: Int
        static func < (a: MonthDay, b: MonthDay) -> Bool { (a.month, a.day) < (b.month, b.day) }
    }

    enum Rule: Equatable {
        /// 매년 반복. `[start, end)` — end는 **배타**(12/26 00:00에 끝남). start > end면 연도를 넘는 창(12/26 → 1/4).
        case yearly(start: MonthDay, end: MonthDay)
        /// 연도별 고정 구간(설날·추석처럼 음력). 테이블에 없는 연도는 비활성.
        case fixed([DateInterval])
    }

    let rule: Rule

    static func yearly(_ sm: Int, _ sd: Int, to em: Int, _ ed: Int) -> SeasonWindow {
        SeasonWindow(rule: .yearly(start: MonthDay(month: sm, day: sd), end: MonthDay(month: em, day: ed)))
    }

    func contains(_ date: Date, calendar: Calendar = .kst) -> Bool {
        switch rule {
        case .fixed(let intervals):
            return intervals.contains { $0.contains(date) && date < $0.end }
        case .yearly(let start, let end):
            let c = calendar.dateComponents([.month, .day], from: date)
            let md = MonthDay(month: c.month ?? 1, day: c.day ?? 1)
            if start < end { return md >= start && md < end }
            // 연도 넘김: [start, 12/31] ∪ [1/1, end)
            return md >= start || md < end
        }
    }

    /// 이 창의 "인스턴스 연도" — 연도를 넘는 창(12/26→1/4)은 시작 연도로 묶는다(1/2도 "2026 인스턴스").
    /// `date`가 창 밖이면 그 날짜의 연도.
    func instanceYear(for date: Date, calendar: Calendar = .kst) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let year = c.year ?? 1970
        guard case .yearly(let start, let end) = rule, start > end else { return year }
        let md = MonthDay(month: c.month ?? 1, day: c.day ?? 1)
        return md < end ? year - 1 : year
    }

    /// `date` 이후 가장 가까운 창 경계(시작 또는 끝, KST 00:00). 경계 타이머용. 없으면 nil.
    func nextBoundary(after date: Date, calendar: Calendar = .kst) -> Date? {
        switch rule {
        case .fixed(let intervals):
            return intervals.flatMap { [$0.start, $0.end] }.filter { $0 > date }.min()
        case .yearly(let start, let end):
            let year = calendar.component(.year, from: date)
            var candidates: [Date] = []
            for y in year...(year + 1) {
                for md in [start, end] {
                    if let d = calendar.date(from: DateComponents(year: y, month: md.month, day: md.day)) {
                        candidates.append(d)
                    }
                }
            }
            return candidates.filter { $0 > date }.min()
        }
    }
}

/// 메인 패널 파티클(비·눈·꽃잎) 생성 파라미터. 날씨(`WeatherCondition`)와 시즌 ambient가 같은 구조체를
/// 넘겨 `WeatherParticles` 한 뷰로 그린다 — 눈을 "가짜 날씨"로 꾸미지 않는다.
struct ParticleStyle: Equatable {
    let sprite: String
    let pixel: CGSize
    /// 강도 1.0일 때 파티클 수.
    let maxCount: Int
    /// 0...1 밀도. 날씨는 강수량 정규화값, 시즌 ambient는 고정(가랑눈 0.35).
    let intensity: Double
    let speed: ClosedRange<Double>
    let scale: ClosedRange<Double>
    let opacity: ClosedRange<Double>
    /// 좌우 흔들림 진폭(정규화 x). 0...0이면 직하.
    let sway: ClosedRange<Double>
    /// 낙하 중 수평 이동(사선). 비만 사용.
    let drift: ClosedRange<Double>
    let spins: Bool
    let thunder: Bool
    /// WalkingCat 날씨 공통 대사 풀을 고를 조건. 시즌 눈도 `.snow` 대사가 나오게.
    let quoteCondition: WeatherCondition?

    static let snow = ParticleStyle(
        sprite: "snowflake", pixel: CGSize(width: 9, height: 9), maxCount: 26, intensity: 1,
        speed: 0.067...0.134, scale: 0.8...1.5, opacity: 0.6...0.95, sway: 0.02...0.06, drift: 0...0,
        spins: true, thunder: false, quoteCondition: .snow)
    static let rain = ParticleStyle(
        sprite: "raindrop", pixel: CGSize(width: 3, height: 7), maxCount: 40, intensity: 1,
        speed: 0.35...0.55, scale: 0.9...1.4, opacity: 0.45...0.8, sway: 0...0, drift: 0.06...0.14,
        spins: false, thunder: false, quoteCondition: .rain)

    /// 시즌 가랑눈 — 한 달 내내 떠 있으니 조용해야 한다.
    static let seasonSnow = ParticleStyle.snow.with(intensity: 0.35)

    func with(intensity: Double) -> ParticleStyle {
        ParticleStyle(sprite: sprite, pixel: pixel, maxCount: maxCount, intensity: intensity,
                      speed: speed, scale: scale, opacity: opacity, sway: sway, drift: drift,
                      spins: spins, thunder: thunder, quoteCondition: quoteCondition)
    }

    func with(thunder: Bool) -> ParticleStyle {
        ParticleStyle(sprite: sprite, pixel: pixel, maxCount: maxCount, intensity: intensity,
                      speed: speed, scale: scale, opacity: opacity, sway: sway, drift: drift,
                      spins: spins, thunder: thunder, quoteCondition: quoteCondition)
    }

    /// 실제 날씨 → 스타일. clear면 nil(상위가 렌더 안 함).
    static func weather(_ condition: WeatherCondition, intensity: Double) -> ParticleStyle? {
        switch condition {
        case .clear:   return nil
        case .snow:    return snow.with(intensity: intensity)
        case .rain:    return rain.with(intensity: intensity)
        case .thunder: return rain.with(intensity: intensity).with(thunder: true)
        }
    }
}

/// 잔디 불 켜진 셀 위 시즌 장식.
enum GrassDecoration: Equatable {
    case snow
}

/// 이벤트 전용 런타임 리컬러. 새 PNG를 그리지 않는다 — 이로치가 hueRotation으로 틴트하듯 CoreImage 필터.
/// (cf. docs/plans/seasonal-events.md §25) `BattlePetSnapshot`에는 넣지 않는다(서버 파리티·HMAC 페이로드).
enum PetSkin: String, Equatable {
    /// 청백 단색화 + 밝기 보정 — 흰색으로 바꾸면 그대로 북극 동물이 된다.
    case snow
}

/// 스킨·머리 장식을 입힌 펫 — 보스 팀 구성원. 렌더 전용(`kind`만 배틀에 간다).
struct SkinnedPet: Equatable {
    let kind: PetKind
    var skin: PetSkin? = nil
    var headwear: String? = nil
    /// 표시명 덮어쓰기(북극곰 등). nil이면 종 이름.
    var displayName: String? = nil
}

/// 보스 tier 격파 보상. 로컬 재화만 — 보스 배틀이 완전 로컬이라 서버 grant currency 제약을 받지 않는다.
struct BossReward: Equatable {
    let coins: Int
    var premiumTickets: Int = 0
}

/// 뱃지·지역과 무관한 시즌 보스 (cf. §24). 팀 생성은 지역 관장과 같은 EP 솔버(`GymLeader.team(lead:supports:tier:)`).
struct SeasonalBoss: Equatable {
    let lead: SkinnedPet
    /// 서포터 4 — 전부 common(EP 밴드). 리컬러 결과가 뭉개지는 종은 프리뷰 보고 교체.
    let supports: [SkinnedPet]
    let name: String
    let title: String
    /// 4단계 — 3번 보상 진행도(일)에 연동: 0 / 1~5 / 6+ / production 격파.
    let dialogues: [String]
    /// tier 오픈에 필요한 보상 일수(3번 `claimedGrants` 접두 행 수).
    let tierThresholds: [BadgeTier: Int]
    let rewards: [BadgeTier: BossReward]
    /// production 격파 칭호.
    let titleReward: CardTitle?
    /// 도장 월드맵의 진입점 — 하늘에 뜬 이벤트 섬. 이 섬을 고르면 보스 카드가 나온다.
    let island: EventIsland
}

/// 날짜별 선물 한 개(KST 그날 하루만 열린다). 지급·dedup은 `SeasonGiftBox`.
struct SeasonGift: Equatable {
    let month: Int
    let day: Int
    let coins: Int
    /// 일반 가챠권. RP·프리미엄권은 서버가 검증하는 화폐라 로컬 선물에 넣지 않는다.
    let tickets: Int

    /// "코인 800 + 가챠권 1장" — 패널 배너 문구.
    var summary: String {
        tickets > 0 ? "코인 \(coins.formatted()) + 가챠권 \(tickets)장" : "코인 \(coins.formatted())"
    }
}

/// 시즌 하나의 정의. 데이터만 들고 있고 로직은 없다.
struct Season: Identifiable, Equatable {
    /// case 삭제 금지 — 저장된 rawValue가 깨진다. 폐지는 `SeasonRegistry.all`에서만 뺀다.
    enum Kind: String, CaseIterable, Codable, Sendable {
        case xmas, newYear, halloween, sakura
    }

    let kind: Kind
    let displayName: String
    let window: SeasonWindow

    // ── 1번: 분위기 ──
    /// 메인 패널 ambient 파티클. 실제 강수가 있으면 그쪽이 우선한다(`ViewModel.ambientStyle`).
    let ambient: ParticleStyle?
    /// 펫 머리 장식 리소스명(`Resources/seasonal/<name>.png`). 메뉴바·차트 WalkingCat이 알파 스캔 앵커로 얹는다.
    let headwear: String?
    let quotes: [String]
    let officeWindowParticles: Bool

    // ── 3번: 잔디 장식·보상 구간 ──
    let grassDecoration: GrassDecoration?
    /// 서버 일일 보상 구간(일). nil이면 보상 없음. grant_key는 `advent-<instanceYear>-<MM>-<DD>`.
    let rewardDays: ClosedRange<Int>?

    // ── 4번: 겨울 관장 ──
    let boss: SeasonalBoss?

    // ── 날짜별 선물 (날짜순, 뒤로 갈수록 커진다) ──
    var gifts: [SeasonGift] = []

    var id: String { kind.rawValue }

    /// 1회성 지급·클레임 dedup 키. 연도가 붙어야 내년에 다시 받을 수 있다. 예: `xmas-2026`.
    func instanceID(now: Date, calendar: Calendar = .kst) -> String {
        "\(kind.rawValue)-\(window.instanceYear(for: now, calendar: calendar))"
    }

    /// 서버 일일 보상 grant_key 접두(`advent-<year>-<MM>-`). 서버 `_shared/season.ts`의 `adventDailyPrefix`와 합의.
    /// 보상 구간은 창 시작 월에 속한다(12월).
    func rewardGrantPrefix(now: Date, calendar: Calendar = .kst) -> String? {
        guard rewardDays != nil, case .yearly(let start, _) = window.rule else { return nil }
        return String(format: "advent-%04d-%02d-", window.instanceYear(for: now, calendar: calendar), start.month)
    }

    /// 완주 grant_key(`advent-<year>-complete`).
    func rewardCompleteKey(now: Date, calendar: Calendar = .kst) -> String? {
        guard rewardDays != nil else { return nil }
        return "advent-\(window.instanceYear(for: now, calendar: calendar))-complete"
    }
}

/// 상점 아이템(액세서리·이펙트·테마·칭호·데코)이 자기 시즌을 안다. 상시 아이템은 nil.
/// 시즌이 아이템 목록을 들고 있는 역방향 필드는 두지 않는다 — 같은 정보가 두 곳이면 어긋났을 때
/// 어느 쪽이 맞는지 알 수 없다. 노출 판정은 `Settings.shopVisible(_:owned:)`.
protocol SeasonalItem {
    var season: Season.Kind? { get }
}
