import Foundation

/// 도장 Guild·Contribution 지표(`Settings.guildContributionTotal`)의 유일한 적립 경로.
///
/// 서버는 누적 기여도를 들고 있지 않다 — `guild-info`가 내려주는 건 `guild_member_monthly_vp` 뷰의
/// **이번 달** VP(이번 달 accepted 제출 합)뿐이고 달이 바뀌면 0부터 다시 센다. 뱃지 임계는 누적
/// (100 / 1,000 / 5,000 / 20,000)이라 월별 값을 이어 붙여야 한다. 그래서 "마지막으로 본 (월, 월간 VP)"를
/// 기억해 두고:
///   - 같은 달이면 **증가분만** 적립한다 (월간 VP는 서버 정산·trim으로 줄 수도 있으니 기준선은 절대 뒤로
///     가지 않는다 — 줄었다가 돌아오는 구간을 두 번 세지 않기 위함).
///   - 달이 바뀌었으면 새 달의 값 **전체**를 적립하고 기준선을 새 달로 옮긴다.
///   - 처음 동기화(기준선 없음)는 이번 달 값을 그대로 적립한다.
///
/// 지난달 이전의 기여는 서버가 따로 내려주는 **가입 이후 누적 VP**(`myContributionTotal`,
/// `guild_member_contribution_vp` 뷰)로 소급한다. 위 월간 적립을 먼저 한 뒤 `max(로컬, 서버)`로
/// 끌어올리기만 한다 — 더하는 게 아니라서 두 경로가 같은 VP를 두 번 세지 않는다. 로컬이 더 큰 경우
/// (이전 길드에서 쌓은 분, 가입한 달의 가입 전 제출)는 그대로 둔다. 이 필드가 없는 구버전 서버에서는
/// 월간 적립만으로 동작한다.
///
/// 월 경계는 **서버와 같은 Asia/Seoul 달력**으로 자른다. 뷰가 `date_trunc('month', now() AT TIME ZONE
/// 'Asia/Seoul')`이라 기기 시간대로 자르면 해외 사용자는 경계가 어긋나 전달 값을 이중 적립한다.
/// 같은 이유로 클라이언트 시계가 서버보다 몇 분 앞서 "새 달"을 먼저 맞는 구간을 막기 위해, 달이 바뀐 직후
/// 1시간 안에 서버 값이 전달 기준선 이상으로 들어오면(= 서버는 아직 전달) 그 응답은 건너뛴다.
///
/// 호출은 `guild-info` 응답을 받는 자리(길드 탭 `refresh`, 로고 캐시 보강)에서 `record(info:)` 하나로 한다.
/// 폴링에 guild-info를 추가하지 않는 건 의도다 — 멤버 프로필까지 실리는 무거운 응답이라 Egress 예산에
/// 맞지 않고, 길드 탭을 열어야 쌓이는 정도면 충분하다.
enum GuildContributionTracker {
    static let serverTimeZone = TimeZone(identifier: "Asia/Seoul")!

    /// 달 바뀐 직후 서버/클라 시계 어긋남을 흡수하는 유예. 이 안에서 "전달 값 그대로"가 오면 보류.
    static let rolloverGraceSec: TimeInterval = 3600

    struct Baseline: Equatable {
        /// "yyyy-MM"(Asia/Seoul). 빈 문자열 = 아직 한 번도 동기화 안 함.
        var month: String
        var seenVP: Int
    }

    struct Reconciliation: Equatable {
        /// `guildContributionTotal`에 더할 값. 보류/변화 없음이면 0.
        let delta: Int
        let baseline: Baseline
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = serverTimeZone
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static func monthKey(for date: Date) -> String { monthFormatter.string(from: date) }

    /// 이번 달(Asia/Seoul) 시작 시각.
    static func monthStart(for date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = serverTimeZone
        return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    }

    /// 순수 함수 — 서버가 준 이번 달 VP와 저장된 기준선으로 적립량과 새 기준선을 계산한다.
    static func reconcile(monthlyVP: Int, now: Date, baseline: Baseline) -> Reconciliation {
        let month = monthKey(for: now)
        let vp = max(0, monthlyVP)

        if baseline.month == month {
            let delta = max(0, vp - baseline.seenVP)
            return Reconciliation(delta: delta,
                                  baseline: Baseline(month: month, seenVP: max(baseline.seenVP, vp)))
        }

        // 달이 바뀜. 직후 유예 안에서 전달 기준선 이상이 오면 서버는 아직 전달일 가능성 — 보류.
        if !baseline.month.isEmpty, baseline.seenVP > 0, vp >= baseline.seenVP,
           now.timeIntervalSince(monthStart(for: now)) < rolloverGraceSec {
            return Reconciliation(delta: 0, baseline: baseline)
        }

        // 새 달(또는 첫 동기화): 이번 달 값 전체를 적립하고 기준선을 옮긴다.
        return Reconciliation(delta: vp, baseline: Baseline(month: month, seenVP: vp))
    }

    /// `guild-info` 응답에서 내 월간 VP를 찾아 적립한다. 내 행이 없으면(탈퇴 직후 등) 아무것도 안 한다.
    @MainActor
    static func record(info: RankingAPI.GuildInfoResponse, now: Date = Date()) {
        guard let mine = info.members.first(where: { $0.isMe }) else { return }
        record(myMonthlyVP: mine.monthlyVP, serverTotal: info.myContributionTotal, now: now)
    }

    @MainActor
    static func record(myMonthlyVP: Int, serverTotal: Int? = nil, now: Date = Date()) {
        let s = Settings.shared
        let before = Baseline(month: s.guildContributionSyncMonth, seenVP: s.guildContributionSyncSeenVP)
        let r = reconcile(monthlyVP: myMonthlyVP, now: now, baseline: before)
        // 월간 증가분을 먼저 더한 뒤 서버 누적으로 끌어올린다(순서가 바뀌면 같은 VP를 두 번 센다).
        let target = max(s.guildContributionTotal + r.delta, serverTotal ?? 0)
        let gained = target - s.guildContributionTotal
        guard gained > 0 || r.baseline != before else { return }
        if gained > 0 { s.guildContributionTotal = target }
        s.guildContributionSyncMonth = r.baseline.month
        s.guildContributionSyncSeenVP = r.baseline.seenVP
        if gained > 0 {
            DebugLog.log("Guild: 기여 지표 +\(gained) → \(s.guildContributionTotal) (\(r.baseline.month) 월간 \(r.baseline.seenVP), 서버 누적 \(serverTotal.map(String.init) ?? "-"))")
            // 길드 탭에서 바로 뱃지 자격이 갱신되도록 — 폴링 끝의 evaluate를 기다리지 않는다.
            BadgeRegistry.evaluate()
        }
    }
}
