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
    let name: String          // 표시용 이름. 도메인/캐릭터 펀.
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
            // Mr. Bean — UK 코미디 + 커피콩. 새벽 카페의 과묵한 영혼. Python 스택.
            return GymLeader(
                region: .coffee, kind: .ghost,
                name: "Mr. Bean",
                dialogues: [
                    "...빈 잔으로 모니터 노려보지 마라.",
                    "한 모금에 한 줄. 페이스가 잡혀가는군.",
                    "산책 다녀올 줄 아는군. 좋은 prompt는 거기서 온다.",
                    "...잘 우려낸 prompt는 잘 내린 커피 같다. 인정."
                ]
            )
        case .vibe:
            // Agent V — LangChain agent + 스파이. 임무 브리핑 톤.
            return GymLeader(
                region: .vibe, kind: .bigDemon,
                name: "Agent V",
                dialogues: [
                    "임무 실패. context 부족, tool 없음.",
                    "tool 호출 시작했군. 보고서 들어온다.",
                    "agent loop 안정. context window를 제대로 쓰는군.",
                    "...훌륭한 agent였다. 다음 임무도 부탁한다."
                ]
            )
        case .cron:
            // Jobs — cron job + 인명. 죽은 job 깨우는 네크로맨서, 시간 강박.
            return GymLeader(
                region: .cron, kind: .necromancer,
                name: "Jobs",
                dialogues: [
                    "주말에만 켜는 job? 그건 죽은 job이다.",
                    "* * * * *. 매분 너를 보고 있다.",
                    "재시도 정책이 있군. 잘 살아남는다.",
                    "cron이 흐르는 한, 너는 살아있다. 인정."
                ]
            )
        case .repo:
            // J.SON — JSON parser + Jason(왕). schema/validate 격식체.
            return GymLeader(
                region: .repo, kind: .kingHuman,
                name: "J.SON",
                dialogues: [
                    "schema 미충족. 도감, 아직 unmarshal 실패다.",
                    "필드가 좀 채워졌군. 허나 nullable이 많다.",
                    "거의 valid한 도감이다. Legendary 필드만 비어있을 뿐.",
                    "정렬된 컬렉션이군. 짐의 schema에 통과되었다."
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
