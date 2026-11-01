import Foundation

/// 시즌 레지스트리 — "지금 활성인 시즌이 무엇인가"의 **유일한** 진입점.
///
/// 스위치 3겹(cf. docs/plans/seasonal-events.md §2):
///   * 사용자: `Settings.seasonalEffectsEnabled` — 모든 시즌 연출 일괄 off. 시즌별 토글은 없다.
///   * 개발:   환경변수 `AIUSAGE_SEASON=xmas` / `none` — 날짜·설정 무시하고 강제(프리뷰·dev run).
///            테스트는 `override`로 같은 일을 한다(프로세스 환경을 바꾸지 않고).
///   * 운영:   `Settings.disabledSeasons` — `sync` 응답의 `disabledSeasons`. 배포 후 버그 시 릴리스 없이 끈다.
///
/// 소비자는 `active()`가 돌려주는 `Season` 필드만 읽는다. 날짜 비교는 여기서 끝난다.
enum SeasonRegistry {

    // MARK: - 데이터

    nonisolated static let all: [Season] = [
        Season(
            kind: .xmas, displayName: "크리스마스",
            window: .yearly(12, 1, to: 12, 26),
            ambient: .seasonSnow,
            headwear: "santa_hat",
            quotes: [
                "cron은 0 0 25 12 * 입니다.",
                "올해 커밋 트리에 장식 다는 중.",
                "산타도 rate limit은 못 피해요.",
                "선물 배송은 at-least-once예요.",
                "눈 오니 빌드가 느린 기분.",
                "연말 배포 freeze 아직이죠?",
                "트리 밑에 PR 두고 갔어요.",
                "12월엔 토큰도 따뜻하게.",
                "루돌프는 GPU 없이 뜁니다.",
                "올해 마지막 force-push는 참아요.",
            ],
            officeWindowParticles: true,
            grassDecoration: .snow,
            rewardDays: 1...24,
            boss: SeasonalBoss(
                lead: SkinnedPet(kind: .deer, skin: .snow, headwear: "santa_hat", displayName: "Rudolph"),
                supports: [
                    SkinnedPet(kind: .bear, skin: .snow, displayName: "북극곰"),
                    SkinnedPet(kind: .fox, skin: .snow, displayName: "북극여우"),
                    SkinnedPet(kind: .wolf, skin: .snow, displayName: "흰늑대"),
                    SkinnedPet(kind: .orchidOwl, skin: .snow, displayName: "흰올빼미"),
                ],
                name: "Rudolph", title: "배송 라우팅 관장",
                dialogues: [
                    "배송 큐가 비었군. 아직 아무것도 안 쓴 건가.",
                    "패킷이 들어오기 시작했다. 경로는 내가 잡지.",
                    "절반 넘겼군. 썰매도 이 정도면 autoscale 된다.",
                    "...눈길에서도 배포가 되는군. 인정.",
                ],
                tierThresholds: [.localhost: 0, .dev: 6, .staging: 12, .production: 18],
                // 지역 관장(50/150/500/1500)의 10~20배 — 사용자 결정(§26). 시즌당 1회, production은 18일 참여 뒤.
                rewards: [
                    .localhost: BossReward(coins: 1_000),
                    .dev: BossReward(coins: 3_000),
                    .staging: BossReward(coins: 6_000),
                    .production: BossReward(coins: 15_000, premiumTickets: 1),
                ],
                titleReward: .snowDeployer
            )
        ),
        Season(
            kind: .newYear, displayName: "연말연시",
            window: .yearly(12, 26, to: 1, 4),
            ambient: .seasonSnow,
            headwear: nil,
            quotes: [
                "올해 커밋 수 세어 봤어요?",
                "연말 정산은 git log --since.",
                "새해 다짐도 버전 관리하세요.",
                "12월 31일 배포는 전설이 돼요.",
                "올해 버그는 올해 안에.",
                "내년 로드맵, 아직 TODO.",
                "카운트다운도 polling이죠.",
                "새해엔 main 브랜치처럼 깔끔하게.",
                "작년 나: 리팩토링한다더니.",
                "Happy New Year, no new bugs.",
            ],
            officeWindowParticles: true,
            grassDecoration: .snow,
            rewardDays: nil,
            boss: nil
        ),
    ]

    nonisolated static func season(_ kind: Season.Kind) -> Season? {
        all.first { $0.kind == kind }
    }

    // MARK: - 강제 (테스트·프리뷰)

    enum Override: Equatable {
        case none
        case season(Season.Kind)
    }

    /// 테스트·프리뷰용 강제. `AIUSAGE_SEASON` 환경변수와 같은 의미이며 환경변수보다 우선한다.
    /// `SandboxedTestCase`가 매 테스트 전에 nil로 되돌린다.
    nonisolated(unsafe) static var override: Override? = nil

    /// `AIUSAGE_SEASON` 환경변수. 모르는 값은 무시(nil).
    nonisolated static func environmentOverride(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Override? {
        guard let raw = env["AIUSAGE_SEASON"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.lowercased() == "none" { return Override.none }
        return Season.Kind(rawValue: raw).map { Override.season($0) }
    }

    // MARK: - 판정

    /// 날짜만으로 고른 시즌(설정·강제 무시). 창이 겹치지 않으므로 최대 1개.
    nonisolated static func scheduled(now: Date, calendar: Calendar = .kst) -> Season? {
        all.first { $0.window.contains(now, calendar: calendar) }
    }

    /// 지금 활성인 시즌. 강제 → 설정 off → 운영 킬스위치 → 날짜 순으로 합성.
    @MainActor
    static func active(now: Date = Date(), settings: Settings? = nil) -> Season? {
        let settings = settings ?? Settings.shared
        if let forced = override ?? environmentOverride() {
            switch forced {
            case .none: return nil
            case .season(let k): return season(k)
            }
        }
        guard settings.seasonalEffectsEnabled else { return nil }
        guard let s = scheduled(now: now) else { return nil }
        if settings.disabledSeasons.contains(s.kind.rawValue) { return nil }
        return s
    }

    /// `date` 이후 가장 가까운 시즌 경계(모든 시즌의 시작/끝 중 최소). 경계 타이머용.
    nonisolated static func nextBoundary(after date: Date, calendar: Calendar = .kst) -> Date? {
        all.compactMap { $0.window.nextBoundary(after: date, calendar: calendar) }.min()
    }
}
