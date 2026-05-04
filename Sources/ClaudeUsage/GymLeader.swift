import Foundation

// 도장 관장 — region별 빌런 1명씩. 진척도(0/8 → 8/8)에 따라 자세(Action)와 대사가 변함.
//
// 4단계 progression:
//   stage 0 — 0/8         : scan (강한 보스 모드) + 도전 대사
//   stage 1 — 1~3/8       : walk (활동) + 인정 시작
//   stage 2 — 4~7/8       : sit (지침) + 거의 패배
//   stage 3 — 8/8 (master): sit (defeat 톤) + 항복 대사

struct GymLeader {
    let region: BadgeRegion
    let kind: PetKind
    let dialogues: [String]   // 4개, stage 0~3 순서

    func dialogue(stage: Int) -> String {
        guard stage >= 0 && stage < dialogues.count else { return "" }
        return dialogues[stage]
    }

    /// 진척도(0~total)를 4단계로 매핑.
    static func stage(cleared: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        if cleared <= 0 { return 0 }
        let ratio = Double(cleared) / Double(total)
        if cleared >= total { return 3 }
        if ratio < 0.5 { return 1 }
        return 2
    }

    static func leader(for region: BadgeRegion) -> GymLeader {
        switch region {
        case .coffee:
            return GymLeader(
                region: .coffee, kind: .ghost,
                dialogues: [
                    "Claude한테 시켜놓고 모니터에 박혀있지 마라.",
                    "Pomodoro 한 사이클 돌리는군.",
                    "자리 비울 줄도 아는구나. 좋은 prompt는 산책 중에 떠오른다.",
                    "쉬는 법을 아는 자가 좋은 질문을 한다."
                ]
            )
        case .vibe:
            return GymLeader(
                region: .vibe, kind: .bigDemon,
                dialogues: [
                    "프롬프트 한 줄 던지고 magic을 기대하나?",
                    "Cursor Tab 쓸 줄은 아는군.",
                    "context를 풍부하게 채우는구나. Claude도 Cursor도.",
                    "프롬프트의 마스터 — 토큰이 헛되지 않다."
                ]
            )
        case .cron:
            return GymLeader(
                region: .cron, kind: .necromancer,
                dialogues: [
                    "주말에만 LLM 켜지 마라. 매일 익숙해져야 한다.",
                    "며칠 연속 쓰는군. prompt가 손에 익기 시작했나.",
                    "새벽에도 Claude를 부리는 자...",
                    "AI와 함께 사는 법을 깨우쳤다."
                ]
            )
        case .repo:
            return GymLeader(
                region: .repo, kind: .kingHuman,
                dialogues: [
                    "Free tier로 뭘 하려고. 한도 차면 끝이다.",
                    "코인이 좀 모였군. 그러나 진정한 컬렉터는...",
                    "도감을 거의 채웠다. Legendary는 아직 부족하지?",
                    "풀세트 컬렉터 — 진정한 수집가다."
                ]
            )
        }
    }
}

extension GymLeader {
    /// stage 0~3 → PetController.Action.
    func action(stage: Int) -> PetController.Action {
        switch stage {
        case 0: return .scan
        case 1: return .walk
        default: return .sit
        }
    }
}
