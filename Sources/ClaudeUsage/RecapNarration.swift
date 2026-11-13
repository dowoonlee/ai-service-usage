import Foundation

/// 저장된 사실만으로 고르는 펫의 대사. 서버 요청이나 이벤트 로그 수집을 기다리지 않는다.
/// 게임 수치는 누적값이므로 올해에 한정된 성과라고 단정하지 않는다.
enum RecapNarration {
    static func text(for sceneID: String, facts: RecapFacts) -> String {
        let u = facts.usage
        let g = facts.game
        switch sceneID {
        case "boot":
            return u.activeDays == 0
                ? "나는 \(g.narrator.kind.displayName). 아직 사용 기록은 적지만, 우리 이야기는 여기서 시작이야."
                : "나는 \(g.narrator.kind.displayName). 네가 작업하는 동안 곁에 있었지. 남겨 둔 기록을 같이 펼쳐 볼까?"
        case "yearline":
            return "기록에 남은 활동일은 \(u.activeDays)일. 선이 높이 솟은 날도, 잠잠한 날도 네 페이스였어."
        case "gauges":
            return u.claudeFiveHourWallHits > 0
                ? "기록상 Claude 5시간 한도에 닿은 창이 \(u.claudeFiveHourWallHits)번이야. 게이지가 차는 동안 나도 옆에서 기다렸지."
                : "사용 기록을 주간 한도 크기로 쌓아 봤어. 작은 조각들도 모아 놓으니 제법 높은 탑이지?"
        case "vs":
            return "이 비율은 도구별로 모은 누적 코인이야. 사용 시간 비율은 아니지만, 함께한 도구들의 흔적이지."
        case "cursor":
            return "저장된 Cursor 기록의 청구액을 모았어. 기록이 없는 기간은 빠져 있으니, 전체 청구서와는 다를 수 있어."
        case "grass":
            return "가장 길게 이어진 사용 기록은 \(u.longestStreak)일이야. 중간에 쉬어도 괜찮아. 다음 칸은 언제든 다시 채우면 돼."
        case "golden":
            guard let hour = u.goldenHour else { return "아직 자주 활동한 시간대를 고를 만큼 기록이 없네. 천천히 알아가 보자." }
            return hour < 6 || hour >= 22
                ? "기록은 \(hour)시 무렵에 가장 활발했어. 조용한 시간이 좋았나 봐. 그래도 잠은 챙기자."
                : "기록은 \(hour)시 무렵에 가장 활발했어. 시간대와 요일은 따로 집계한 거야. 네 리듬이 조금 보이지?"
        case "gacha":
            if g.shinySpecies > 0 {
                return "지금까지 만난 펫 중 \(g.shinySpecies)종은 색다른 모습도 열었네. 다음 알을 기다리는 표정은 늘 똑같더라."
            }
            return "지금까지 \(g.speciesOwned)종의 펫을 만났어. 처음 보는 친구도, 다시 찾아온 친구도 네 도감에 자리를 잡았지."
        case "partner":
            guard let partner = g.partners.first else { return "함께 걸은 시간은 이제부터 쌓으면 돼. 오늘은 내가 옆에 있을게." }
            return "누적 동행 시간이 가장 긴 친구는 \(partner.kind.displayName). 특별한 날보다 평범한 날을 오래 함께했나 봐."
        case "gym":
            return "모아 둔 뱃지는 \(g.badges)개, 완성한 컬렉션은 \(g.collectionsCompleted)개야. 하나씩 열던 순간을 기억해?"
        case "arena":
            return "아레나 누적 \(g.arenaWins)승. 이긴 판만큼, 다음 판을 위해 파티를 고르던 시간도 네 기록이야."
        case "life":
            if g.quizCorrect == 0 && g.wellnessResponded == 0 {
                return "아직 퀴즈와 웰니스 기록은 없네. 다음엔 문제 하나 풀고, 잠깐 몸도 풀어 보는 건 어때?"
            }
            return "퀴즈 정답 \(g.quizCorrect)번, 웰니스 응답 \(g.wellnessResponded)번. 작업 사이의 작은 쉼표도 이렇게 남았네."
        case "ending":
            return u.activeDays == 0
                ? "오늘은 짧은 첫 페이지였네. 기록이 쌓이면 다시 보러 와. 다음 이야기에도 내가 함께할게."
                : "여기까지가 지금 남아 있는 우리 기록이야. 다음에 열면 이야기가 더 쌓여 있겠지. 오늘도 곁에서 걸을게."
        default:
            return "이것도 우리가 남긴 기록이네. 다음 이야기도 같이 보자."
        }
    }
}
