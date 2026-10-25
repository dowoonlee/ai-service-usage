import Foundation

/// Player-facing copy follows the counters, rather than the short English badge nicknames.
extension BadgeCategory {
    var activityTitle: String {
        switch self {
        case .standup: return "휴식 알림 응답"
        case .rateLimit: return "주간 사용량 관리"
        case .claude: return "Claude 사용 코인"
        case .cursor: return "Cursor 사용 코인"
        case .codex: return "Codex 사용 코인"
        case .heartbeat: return "앱 연속 활동"
        case .nightOwl: return "새벽 앱 활동"
        case .stash: return "누적 코인 획득"
        case .dependency: return "펫 종류 수집"
        case .monorepo: return "컬렉션 완성"
        case .fork: return "이로치 해금"
        case .arenaWins: return "랭크전 승리"
        case .arenaRating: return "최고 레이팅"
        case .guildContribution: return "길드 기여 점수"
        case .guildTenure: return "길드 가입 기간"
        case .dailyQuizCorrect: return "퀴즈 정답 수"
        case .dailyRitual: return "퀴즈 연속 참여"
        case .pullRequest: return "프로젝트 PR 기여"
        case .bugHunter: return "버그 제보"
        }
    }

    /// Always visible, even without hovering a gem.
    var activitySummary: String {
        switch self {
        case .standup: return "펫의 휴식 알림을 5분 안에 눌러 응답 횟수를 쌓으세요."
        case .rateLimit: return "Claude 주간 사용량을 80% 미만으로 마친 주를 셉니다."
        case .claude: return "Claude 사용량 증가로 획득한 코인을 누적합니다."
        case .cursor: return "Cursor Ultra 사용량으로 획득한 코인을 누적합니다."
        case .codex: return "Codex 사용량 증가로 획득한 코인을 누적합니다."
        case .heartbeat: return "앱이 사용량을 확인한 날을 연속으로 쌓으세요."
        case .nightOwl: return "기기 시각 00~06시에 앱이 기록한 활동 시간을 누적합니다."
        case .stash: return "사용과 각종 보상으로 받은 코인의 총합을 쌓으세요."
        case .dependency: return "서로 다른 종류의 펫을 모으세요. 중복 펫은 한 종류로 셉니다."
        case .monorepo: return "컬렉션에 속한 펫을 모두 모아 완성 기록을 쌓으세요."
        case .fork: return "펫별로 해금한 이로치 단계의 총개수를 셉니다."
        case .arenaWins: return "자동 랭크전에서 승리한 기록을 쌓으세요."
        case .arenaRating: return "자동 랭크전에서 자신의 최고 레이팅을 갱신하세요."
        case .guildContribution: return "길드에 기록된 기여 점수를 누적하는 업적입니다."
        case .guildTenure: return "처음 길드에 가입한 날부터 오늘까지 지난 기간입니다."
        case .dailyQuizCorrect: return "데일리 퀴즈에서 맞힌 문항 수를 누적합니다."
        case .dailyRitual: return "매일 데일리 퀴즈 답안을 제출해 연속 참여일을 쌓으세요."
        case .pullRequest: return "AIUsage 프로젝트에 기여해 머지된 PR 기록을 쌓으세요."
        case .bugHunter: return "앱의 버그 제보 기능으로 GitHub 이슈 작성 화면을 연 횟수입니다."
        }
    }

    /// The longer counting rules live in the tooltip, including exclusions that change a player's next action.
    var countingGuide: String {
        switch self {
        case .standup:
            return "휴식 알림에 5분 안에 응답해 보상이 인정되면 1회 올라갑니다. 늦게 닫은 알림은 집계되지 않습니다."
        case .rateLimit:
            return "Claude의 7일 사용량이 초기화될 때, 앱이 마지막으로 확인한 사용률이 80% 미만이면 1주를 인정합니다. 누적 통과 주수이며 연속일 필요는 없습니다."
        case .claude, .cursor, .codex:
            let source = self == .claude ? "Claude" : (self == .cursor ? "Cursor Ultra" : "Codex")
            return "\(source)의 사용량 증가에 따라 받은 코인만 셉니다. 사용량을 앱에서 확인하면 반영되며, 퀴즈·뱃지 등 다른 보상은 이 항목에 포함되지 않습니다. 코인을 사용해도 누적 기록은 유지됩니다."
        case .heartbeat:
            return "앱의 사용량 확인이 다른 날짜에도 이어지면 1일씩 올라갑니다. 마지막 확인 후 36시간이 넘으면 다음 확인 때 1일부터 다시 시작합니다. 실제 AI 사용량 연속 기록과는 별도입니다."
        case .nightOwl:
            return "앱이 새벽 0시부터 6시 사이에 사용량을 확인하면서 기록한 활동 시간입니다. 여러 날의 기록을 합산하고, 1시간 미만은 표시에서 제외합니다."
        case .stash:
            return "사용량·휴식·퀴즈 등으로 지금까지 획득한 코인의 총합입니다. 현재 지갑 잔액이 아니므로 가챠나 구매에 써도 기록은 줄지 않습니다."
        case .dependency:
            return "현재 보유한 펫의 종류 수입니다. 같은 펫을 여러 번 뽑거나 다른 이로치를 해금해도 같은 종류로 셉니다."
        case .monorepo:
            return "완성한 컬렉션의 개수입니다. 상점의 컬렉션 목록에서 빠진 펫을 확인하고 모으면 완성할 수 있습니다."
        case .fork:
            return "기본 색상을 제외하고 펫마다 해금한 이로치 단계를 합산합니다. 한 펫에서 1·2·3단계를 해금하면 3개이며, 조각으로 해금하는 레인보우도 1개로 인정합니다."
        case .arenaWins:
            return "기존 자동 랭크전의 승리 기록입니다. 아레나에서 랭크전 전적을 불러오면 갱신되며, 연습전과 수동 서버 도전의 승리는 포함되지 않습니다."
        case .arenaRating:
            return "기존 자동 랭크전에서 기록한 최고 레이팅입니다. 이후 점수가 내려가도 최고 기록은 유지됩니다. 아레나의 랭크전 화면에서 기록을 갱신할 수 있습니다."
        case .guildContribution:
            return "저장된 길드 기여 점수의 누적값입니다. 현재 버전에서는 기여 활동을 이 지표에 자동 반영하는 기능이 연결되어 있지 않습니다."
        case .guildTenure:
            return "앱에 처음 기록된 길드 가입일을 기준으로 경과일을 계산합니다. 매일 접속해야 하는 연속 출석 업적이 아니며, 길드 변경·탈퇴 후에도 최초 가입일 기준을 유지합니다."
        case .dailyQuizCorrect:
            return "답안 제출이 완료된 데일리 퀴즈에서 맞힌 문항을 모두 더합니다. 하루에 여러 문제를 맞히면 그만큼 올라가며, 정답을 맞힌 날짜 수를 세는 항목은 아닙니다."
        case .dailyRitual:
            return "마지막 퀴즈 제출 기준의 연속 참여일입니다. 정답 수와 관계없이 제출하면 하루 1회 인정합니다. 하루라도 건너뛰면 다음 제출 때 1일부터 다시 시작합니다. 날짜는 기기 달력 기준입니다."
        case .pullRequest:
            return "GitHub 계정을 연결하면 dowoonlee/ai-service-usage에 머지된 내 PR을 확인해 반영합니다. 처음 연결할 때 과거 기여도 확인하며, 같은 PR은 한 번만 셉니다."
        case .bugHunter:
            return "앱의 버그 제보에서 GitHub 이슈 작성 화면을 여는 시점에 1건을 기록합니다. GitHub에서 실제 제출·수정·해결 완료 여부를 확인하는 지표는 아닙니다."
        }
    }

    var metricUnit: String {
        switch self {
        case .standup: return "회"
        case .rateLimit: return "주"
        case .claude, .cursor, .codex, .stash: return "코인"
        case .heartbeat, .guildTenure, .dailyRitual: return "일"
        case .nightOwl: return "시간"
        case .dependency: return "종"
        case .monorepo, .fork: return "개"
        case .arenaWins: return "승"
        case .arenaRating, .guildContribution: return "점"
        case .dailyQuizCorrect: return "문항"
        case .pullRequest, .bugHunter: return "건"
        }
    }

    func metricDescription(_ value: Int) -> String {
        let n = value.formatted()
        switch self {
        case .standup: return "휴식 알림 응답 \(n)회"
        case .rateLimit: return "주간 사용량 관리 \(n)주 통과"
        case .claude: return "Claude로 획득한 코인 \(n)개"
        case .cursor: return "Cursor로 획득한 코인 \(n)개"
        case .codex: return "Codex로 획득한 코인 \(n)개"
        case .heartbeat: return "앱 활동 연속 \(n)일"
        case .nightOwl: return "기록된 새벽 활동 \(n)시간"
        case .stash: return "지금까지 획득한 코인 \(n)개"
        case .dependency: return "서로 다른 펫 \(n)종 보유"
        case .monorepo: return "컬렉션 \(n)개 완성"
        case .fork: return "이로치 단계 총 \(n)개 해금"
        case .arenaWins: return "자동 랭크전 \(n)승"
        case .arenaRating: return "자동 랭크전 최고 \(n)점"
        case .guildContribution: return "기록된 길드 기여 \(n)점"
        case .guildTenure: return "길드 최초 가입 후 \(n)일 경과"
        case .dailyQuizCorrect: return "퀴즈 정답 누적 \(n)문항"
        case .dailyRitual: return "최근 퀴즈 연속 참여 \(n)일"
        case .pullRequest: return "프로젝트에 머지된 내 PR \(n)건"
        case .bugHunter: return "버그 제보 작성 화면 열기 \(n)건"
        }
    }

    func remainingDescription(current: Int, threshold: Int) -> String {
        let remaining = max(0, threshold - current)
        return remaining == 0 ? "이 지표 기준을 충족했습니다" : "이 지표 기준까지 \(remaining.formatted())\(metricUnit) 남았습니다"
    }

    var trackingNotice: String? {
        self == .guildContribution ? "기여 점수 자동 집계 준비 중" : nil
    }

    @MainActor
    func countingContext(_ settings: Settings) -> String? {
        func date(_ value: Date) -> String { value.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)) }
        switch self {
        case .guildTenure:
            return settings.guildJoinedAt.map { "최초 가입 기록: \(date($0))" } ?? "길드에 처음 가입하면 기간 집계가 시작됩니다."
        case .dailyRitual:
            return settings.dailyRitualLastDay.map { "마지막 참여 기록: \(date($0))" } ?? "데일리 퀴즈 답안을 제출해 첫날을 시작하세요."
        default: return nil
        }
    }
}
