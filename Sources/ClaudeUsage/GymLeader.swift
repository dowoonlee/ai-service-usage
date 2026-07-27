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
        case .registry:
            // Semver — semantic versioning + 큐레이터. 모든 fork·컬렉션을 등재하는 질서의 수호자. Mythic 전사.
            return GymLeader(
                region: .registry, kind: .warrior,
                name: "Semver",
                dialogues: [
                    "variant 0뿐인가. fork 한 번 안 떠봤군.",
                    "shiny가 깨어나는군. 이로치는 노력의 증표다.",
                    "컬렉션이 채워진다. registry가 살쪄가는군.",
                    "...모든 fork를 등재했다. 짐의 monorepo에 영원히 기록되리라."
                ]
            )
        // ── 클라우드 제도 (gym-expansion.md 부록 B) ──
        case .arena:
            // Load Balancer — 트래픽을 가르는 투기장 주인. 거구.
            return GymLeader(
                region: .arena, kind: .ogre,
                name: "Load Balancer",
                dialogues: [
                    "요청 0건. 링에 오를 자격도 없군.",
                    "트래픽이 들어오는군. 몇 판 붙어봤나.",
                    "라운드로빈처럼 승수를 분산하는군. 안정적이다.",
                    "...너의 레이팅은 이제 5-nine이다. 무패에 가깝군. 인정."
                ]
            )
        case .guild:
            // Merge Conflict — 길드 파벌 다툼의 화신.
            return GymLeader(
                region: .guild, kind: .orcWarrior,
                name: "Merge Conflict",
                dialogues: [
                    "<<<<<<< 소속 없음. 너는 어느 브랜치냐.",
                    "기여가 쌓인다. 충돌을 해소하기 시작했군.",
                    "길드에 오래 남는군. HEAD가 안정적이다.",
                    "=======  >>>>>>> 모든 충돌을 해소했다. clean merge. 인정."
                ]
            )
        case .daily:
            // Cron-tab Monk — 매일 같은 시각의 수도승.
            return GymLeader(
                region: .daily, kind: .monk,
                name: "Cron-tab Monk",
                dialogues: [
                    "하루도 오지 않는 날이 있군. 수행이 끊겼다.",
                    "매일의 정진이 시작됐군. 0 0 * * *.",
                    "연속된 나날이 쌓인다. 흔들림 없는 리듬이군.",
                    "...365일 정답과 정진. 너는 이미 깨달음에 이르렀다."
                ]
            )
        case .oss:
            // Maintainer — PR을 심판하는 지친 오픈소스 관리자.
            return GymLeader(
                region: .oss, kind: .wizardM,
                name: "Maintainer",
                dialogues: [
                    "PR도, 이슈도 없군. 이 저장소는 아직 비어있다.",
                    "첫 기여가 머지됐군. LGTM.",
                    "리뷰가 쌓인다. 너는 신뢰받는 컨트리뷰터다.",
                    "...너에게 커밋 권한을 준다. 이제 이 저장소는 너의 것이기도 하다."
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

// MARK: - 관장 배틀 팀 (gym-battle.md §3)
//
// 난이도 설계 근거 — 배틀 엔진은 데미지가 atk/def **비율식**이라, 승패가 두 팀 전투력 비의 대략
// **세제곱**에 좌우된다([[arena-balance-snowball]]): 10% 우위 → (1.1)³≈1.33× TTK → 5v5 소모전에서
// 사실상 확정승. 따라서 "조금 더 어렵게" 같은 미세 튜닝은 무의미하고, **관장 팀의 절대 전투력을
// 내 팀이 도달 가능한 밴드에 정확히 놓는 것**이 전부다.
//
// 두 제약:
//  1. 내 팀은 **로컬 배틀에서 강화 0**(강화는 서버 authoritative → 로컬 미반영). 그래서 내 EP 상한은
//     base(레어도) × 이로치(vb ≤1.18) × 컬렉션 시너지(collMult ≤~1.3)로 묶인다.
//  2. 관장 kind의 base(레어도)는 제각각(rare48 ~ mythic78)이고 kind는 맵 아바타·대사에 고정이라 못 바꾼다.
//
// → 서포터는 **전부 common(base40)**으로 고정해 팀 평균 base를 내 팀 밴드로 낮추고, tier 난이도는
//   "펫당 목표 EP"에 맞춰 **강화 레벨을 역산**(레어도 보정)해서 준다. 그러면 mythic 관장이든 rare
//   관장이든 같은 tier면 비슷한 난이도가 된다. 튜닝은 `targetEP`의 4개 상수만 만지면 전 지역이 함께 움직인다.

extension GymLeader {
    /// tier(=지역 진행 스케일) 난이도로 구성된 관장 팀 — 관장 kind가 선봉 + 지역 테마 common 서포터 4.
    /// **각 펫을 목표 EP로 맞추도록 강화를 개별 역산**(레어도·이로치 보정) → 팀 전체가 균일한 targetEP.
    /// 단일 강화로 주면 base가 높은 선봉이 tier가 오를수록 벽처럼 치솟아(비율식 세제곱 → 사실상 확정승)
    /// production이 불가능해진다. 균일 EP로 두고, 보스의 "격"은 production 선봉의 레인보우(궁극기+크리+연출)로
    /// 표현한다. 완전 로컬 — 서버 의존 0.
    func team(tier: BadgeTier) -> BattleTeam {
        // production 관장(선봉)만 레인보우 — 궁극기 게이지·컷인·크리(스탯 벽 아닌 "보스 엣지").
        let leadVariant = (tier == .production) ? BattleEngine.rainbowVariant : 0
        // 팀 시너지(collMult)는 kind 구성으로만 정해짐(강화·이로치 무관) → 목표 EP를 그만큼 낮춰 강화를
        // 역산(상쇄). 관장 팀은 **테마대로 한 컬렉션에 몰아 시너지를 살리고**(언데드/데몬 gym 등), 밸런스는
        // 강화 레벨에서 맞춘다. (풀시너지 팀은 오히려 common으로도 production까지 도달 가능 — 시너지가
        // 데미지 비율을 올려주므로.) 타입 시너지(대표 스탯 1개)는 상쇄 안 하고 "테마 시그니처"로 남긴다.
        let kinds = [kind] + Self.supportKinds(region)
        let collMult = TeamSynergy.bonus(for: kinds.map { BattlePetSnapshot(kind: $0) }).collectionMult
        let target = Self.targetEP(tier) / collMult
        let lead = Self.snapshot(kind, variant: leadVariant, targetEP: target)
        let mooks = Self.supportKinds(region).map { Self.snapshot($0, variant: 0, targetEP: target) }
        return BattleTeam([lead] + mooks)
    }

    /// 한 펫을 목표 EP(≈ base × 성장 × 이로치)에 맞추는 스냅샷 — 이로치(vb)를 반영해 강화를 역산.
    /// base가 target보다 이미 큰 저 tier의 고레어도 관장은 강화 0으로도 target 초과(하한) — 의도된 편차.
    private static func snapshot(_ k: PetKind, variant: Int, targetEP: Double) -> BattlePetSnapshot {
        let vb = 1.0 + PetBattleStats.variantMultiplier(variant: variant)
        let enhance = solveEnhance(targetGrowth: targetEP / (baseFor(k) * vb))
        return BattlePetSnapshot(kind: k, variant: variant, enhanceLevel: enhance)
    }

    /// tier별 관장 팀의 목표 "펫당 실효 전투력"(EP ≈ base × 성장 × 이로치, 앱 표시 전투력 ≈ EP×4.6).
    /// 내 팀은 gym에서도 **실제 강화 레벨**을 반영(GymBattleView가 서버에서 로드)하므로, 강화 포함 팀을
    /// 기준으로 잡는다. 이 값이 곧 "이길 수 있는 팀의 하한"(≈ 전투력 EP×4.6).
    ///  - localhost(50 ≈ 전투력 230): 캐주얼(rare·강화3·무시너지 ~257)이 돌파.
    ///  - dev(68 ≈ 313): 어느 정도 강화·이로치.
    ///  - staging(88 ≈ 405): 강화6+이로치+시너지(중반 ~390과 접전).
    ///  - production(110 ≈ 506): 강화9+이로치3~4+시너지(투자 ~501)라야 잡는 endgame. 고래(~1000)는 압도.
    /// common 서포터는 강화 상한(+15, growth 2.35)이라 EP≈94(전투력 405)에서 캡 → 고 tier 팀 평균은
    /// 그보다 낮고, 선봉(고레어도)만 더 높아 자연스러운 "보스+졸개" 구조가 된다. 실측 후 이 4상수만 조정.
    private static func targetEP(_ tier: BadgeTier) -> Double {
        switch tier {
        case .localhost:  return 50
        case .dev:        return 68
        case .staging:    return 88
        case .production: return 110
        }
    }

    /// kind 레어도 → base 스탯(PetBattleStats.rarityBase).
    private static func baseFor(_ kind: PetKind) -> Double {
        PetBattleStats.rarityBase(PetKind.rarityFor(kind) ?? .common)
    }

    /// 목표 성장배수에 가장 가까운 강화 레벨(0…max). 성장은 1.0 미만으로 못 내려가므로(강화 하한),
    /// 목표<1.0이면 0을 반환 → 그 팀은 그 tier에서 하한 EP=avgBase. mythic 관장(warrior/monk)이
    /// 저 tier에서 목표보다 약간 센 이유(의도된 "엘리트 보스" 편차, ~+8%).
    private static func solveEnhance(targetGrowth: Double) -> Int {
        var best = 0, bestDiff = Double.greatestFiniteMagnitude
        for lv in 0...PetBattleStats.maxEnhanceLevel {
            let g = PetBattleStats.growthMultiplier(enhanceLevel: lv, progressUnits: 0)
            let d = abs(g - targetGrowth)
            if d < bestDiff { bestDiff = d; best = lv }
        }
        return best
    }

    /// 지역 테마 서포터 4종 — **전부 common(base40)**, 팀 내 유니크(선봉 관장과도 중복 없음).
    /// **컬렉션이 곧 테마**라, 테마를 그대로 맞춰 **한 컬렉션/타입에 몰아 시너지를 살린다**(언데드 gym·데몬
    /// gym·전사단·아케인 등). 그로 인한 collMult(1.05~1.26)는 `team(tier:)`이 강화 역산에서 상쇄하므로
    /// 난이도는 균일하게 유지된다. 타입 시너지(대표 스탯 1개)는 상쇄 안 하고 테마 시그니처로 남긴다.
    private static func supportKinds(_ region: BadgeRegion) -> [PetKind] {
        switch region {
        case .coffee:   return [.skelet, .tinyZombie, .iceZombie, .zombie]  // 유령 카페 (언데드 wontfix×5)
        case .vibe:     return [.imp, .chort, .pumpkinDude, .wogol]         // 에이전트 데몬 군단 (fridayDeploy×5)
        case .cron:     return [.zombie, .skelet, .blankey, .skeletonG]     // 되살아난 job (언데드 wontfix×5)
        case .repo:     return [.dwarfF, .elfF, .lizardF, .angel]           // schema 왕국 근위대
        case .registry: return [.goblin, .lizardF, .dwarfF, .elfF]          // 수호 전사단 (warrior 타입×5)
        case .arena:    return [.muddy, .swampy, .martianRed, .bigRed]      // 거구 괴물 군단 (fridayDeploy×5)
        case .guild:    return [.goblin, .lizardF, .chort, .skelet]         // 오크 파벌 (rustEvangelists×3)
        case .daily:    return [.angel, .rabbit, .deer, .oposum]            // 정진의 수행자들 (담백)
        case .oss:      return [.angel, .bushly, .wispyFire, .gloppySlime]  // 마법사·사역마 (arcane 타입×5)
        }
    }
}
