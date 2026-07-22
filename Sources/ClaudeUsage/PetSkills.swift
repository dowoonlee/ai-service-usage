import Foundation

// 펫 스킬 시스템 (Phase A/B1/B2/C) — 순수 로직. 서버 `_shared/pvp_policy.ts` 스킬 계층과 규칙 1:1.
// 설계 SSOT: docs/plans/pet-skills.md.
//
// 이로치(variant) 단계마다 스킬을 얻는다: variant 0 = generic("핫픽스") / 1 = typeShared(타입 6종) /
// 2 = collectionShared(컬렉션 19종·오프타입 커버리지) / 3 = unique(Epic+ per-kind 고유기·자기타입).
// variant 4 = **궁극기**(타입 6종) — 정규 슬롯이 아니라 BattleEngine의 충전 게이지로 발동(아래 ultimateTable).
// 데미지식은 "스킬 타입 vs 방어자 타입" 상성(×2.0/×0.5)과 자속(STAB ×1.5)으로 전환 — 패시브 ×1.6/0.625 대체.
// generic/typeShared 는 펫 타입에서 **규칙 파생**이라 per-kind 데이터가 없고, 양측 동일 로직으로 재현된다.

enum SkillTier: String, Codable, Equatable {
    case generic, typeShared, collectionShared, unique, ultimate
}

/// 스킬 부수효과(rider) — 공격이 적중하면 chance 확률로 효과를 부여한다 (E2, pet-effects.md §3).
/// `chance == 1.0`은 확정 부여로 **rng draw를 소비하지 않는다**(결정성 — 확률일 때만 draw).
/// `selfTarget == true`면 시전자 자신(버프), false면 적 활성 펫(디버프 — 막타로 기절 시 부여 생략, draw도 생략).
struct SkillRider: Equatable {
    let effectId: String
    let chance: Double
    let selfTarget: Bool
}

/// 한 개의 스킬. `type`은 6배틀타입 중 하나, `power`는 데미지 계수, `tier`는 획득 계층.
/// `rider`는 부수효과(E2) — 없으면 nil(기존 스킬과 동작 동일).
struct Skill: Equatable {
    let id: String
    let name: String
    let type: BattleType
    let power: Double
    let tier: SkillTier
    var rider: SkillRider? = nil
}

/// 효과 정의 카탈로그 (E2) — pet-effects.md §2 + §7.5(궁극기 부여용 2종). 서버 pvp_policy.EFFECTS 1:1.
/// 스킬 id와 같은 이름의 효과(mem_leak 등)는 "그 스킬이 부여하는 효과" — 스킬/효과는 별도 네임스페이스라
/// 충돌이 아니며, 표시명 조회도 각자 카탈로그를 쓴다(status doc의 네임스페이스 정리 = 이 규칙 명문화).
enum EffectCatalog {
    /// id → (표시명, 정의). magnitude/duration/chance 의미는 BattleEngine.BattleEffect 참조. 수치는 튜닝 대상.
    static let table: [String: (name: String, def: BattleEngine.BattleEffect)] = {
        func fx(_ id: String, _ name: String, _ kind: BattleEngine.EffectKind,
                _ magnitude: Double, _ duration: Int, _ chance: Double? = nil) -> (String, (String, BattleEngine.BattleEffect)) {
            (id, (name, BattleEngine.BattleEffect(id: id, kind: kind, magnitude: magnitude, duration: duration, chance: chance)))
        }
        return Dictionary(uniqueKeysWithValues: [
            // 상태이상(디버프)
            fx("mem_leak",      "메모리 릭",      .dot, 0.05, 3),
            fx("infinite_loop", "무한 루프",      .dot, 0.08, 3),
            fx("deadlock",      "데드락",         .controlChance, 0, 3, 0.35),
            fx("rate_limited",  "레이트 리밋",    .controlFixed, 0, 2),
            fx("tech_debt",     "기술 부채",      .statMod(.atk), 0.80, 3),
            fx("legacy",        "레거시",         .statMod(.spd), 0.75, 3),
            // 버프(자신)
            fx("optimization",  "최적화",         .statMod(.atk), 1.25, 3),
            fx("firewall",      "방화벽",         .statMod(.def), 1.30, 3),
            fx("caching",       "캐싱",           .statMod(.spd), 1.25, 3),
            fx("load_balancer", "로드 밸런서",    .shield, 0.20, 3),
            fx("autoscaling",   "오토스케일링",   .regen, 0.06, 3),
            fx("hot_reload",    "핫 리로드",      .cleanse, 0, 0),
            // 궁극기 부여 전용 (§7.5 — 카탈로그판과 지속이 달라 별도 id)
            fx("outage_stun",   "전면 장애",      .controlFixed, 0, 1),
            fx("bsod_lag",      "블루 스크린",    .statMod(.spd), 0.60, 2),
        ])
    }()
    static func effect(_ id: String) -> BattleEngine.BattleEffect? { table[id]?.def }
    static func displayName(_ id: String) -> String? { table[id]?.name }
}

enum SkillCatalog {
    // 스킬 상성 — 타입 6-사이클(`BattleType.beats`)을 재사용하고 배수만 ×2.0/×0.5로 전환(패시브 ×1.6/0.625 대체).
    static let skillSuper = 2.0
    static let skillWeak = 0.5

    /// 스킬 타입이 방어자 타입을 이기면 ×2.0, 지면 ×0.5, 중립 ×1.0. 서버 pvp_policy.skillEffectiveness 1:1.
    static func skillEffectiveness(_ skillType: BattleType, vs defender: BattleType) -> Double {
        if skillType.beats == defender { return skillSuper }
        if defender.beats == skillType { return skillWeak }
        return 1.0
    }

    /// 자속(STAB) — 스킬 타입 == 펫 타입이면 ×1.5(자기 타입 스킬 보상).
    static let stabMult = 1.5
    static func stab(skillType: BattleType, petType: BattleType) -> Double {
        skillType == petType ? stabMult : 1.0
    }

    static let genericPower = 8.0
    static let typeSharedPower = 11.0

    /// generic — 전 펫 공용(variant 0). 항상 펫 자기 타입(자속). id "hotfix".
    static func generic(for type: BattleType) -> Skill {
        Skill(id: "hotfix", name: "핫픽스", type: type, power: genericPower, tier: .generic)
    }

    /// typeShared — 같은 배틀 타입끼리 공유(variant 1). 자기 타입, power 11.
    static let typeSharedTable: [BattleType: (id: String, name: String)] = [
        .beast:   ("mem_leak", "메모리 릭"),
        .warrior: ("force_push", "강제 푸시"),
        .chaos:   ("friday_deploy", "금요일 배포"),
        .arcane:  ("context_overflow", "컨텍스트 폭발"),
        .machine: ("regression_sweep", "회귀 스윕"),
        .mascot:  ("onboarding", "온보딩"),
    ]
    /// typeShared 부수효과(E2) — 타입당 1개, 밈 정합 매핑. 디버프 25~30% / 버프(onboarding) 확정 자부여.
    /// 서버 pvp_policy.TYPE_SHARED_RIDER 1:1. 수치는 밸런스 튜닝 대상(E2는 골든 승률 실측 전 초기값).
    static let typeSharedRiderTable: [BattleType: SkillRider] = [
        .beast:   SkillRider(effectId: "mem_leak", chance: 0.30, selfTarget: false),       // 램 잠식 DoT
        .warrior: SkillRider(effectId: "tech_debt", chance: 0.30, selfTarget: false),      // 강제 푸시 → 부채
        .chaos:   SkillRider(effectId: "infinite_loop", chance: 0.25, selfTarget: false),  // 주말 장애 DoT
        .arcane:  SkillRider(effectId: "deadlock", chance: 0.25, selfTarget: false),       // 컨텍스트 혼란
        .machine: SkillRider(effectId: "legacy", chance: 0.30, selfTarget: false),         // 회귀에 발목
        .mascot:  SkillRider(effectId: "load_balancer", chance: 1.0, selfTarget: true),    // 방어형 실드(확정)
    ]
    static func typeShared(for type: BattleType) -> Skill {
        let e = typeSharedTable[type]!   // 6타입 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: type, power: typeSharedPower, tier: .typeShared,
                     rider: typeSharedRiderTable[type])
    }

    static let collectionSharedPower = 12.0

    /// collectionShared — 컬렉션 밈 스킬(variant 2). **오프타입**: 각 컬렉션의 자기 배틀타입과 다른 타입을
    /// 부여해 "자기타입 STAB 무브 vs 오프타입 상성 무브" 커버리지 선택을 만든다(스킬 타입 시스템의 본래 목적).
    /// power 12. 타입은 밸런스 레버 — 6타입에 고르게 분산. Swift 유닛테스트가 "자기타입 아님"을 회귀 가드.
    static let collectionSharedTable: [PetCollection: (id: String, name: String, type: BattleType)] = [
        // beast 컬렉션(자기타입 beast → 오프타입 부여)
        .mainframe:        ("mainframe_overload", "메인프레임 과부하", .machine),
        .emotionalSupport: ("emotional_support", "정서적 지지", .mascot),
        .npmInstall:       ("dependency_hell", "의존성 지옥", .chaos),
        .nodeModules:      ("node_modules_summon", "node_modules 소환", .arcane),
        .dns:              ("dns_propagation", "DNS 전파 지연", .arcane),
        .deprecated:       ("deprecated_strike", "@deprecated", .warrior),
        // warrior 컬렉션
        .vibeCoders:       ("vibe_coding", "바이브 코딩", .chaos),
        .tenXEngineer:     ("tenx_refactor", "10x 리팩터", .beast),
        .onCall:           ("oncall_page", "온콜 호출", .beast),
        .rustEvangelists:  ("rewrite_in_rust", "Rust로 재작성", .machine),
        .noVerify:         ("no_verify", "--no-verify", .chaos),
        // chaos 컬렉션
        .wontfix:          ("wontfix_close", "won't fix", .mascot),
        .oomKilled:        ("oom_kill", "OOM 킬러", .machine),
        .fridayDeploy:     ("friday_5pm", "금요일 5시 배포", .warrior),
        // arcane 컬렉션
        .tokenBurners:     ("token_burn", "토큰 소각", .chaos),
        .todoSince2019:    ("tech_debt_invoice", "기술부채 청구서", .warrior),
        // machine 컬렉션
        .ciRunners:        ("pipeline_stall", "파이프라인 병목", .arcane),
        // mascot 컬렉션
        .happyPath:        ("happy_path", "해피 패스", .beast),
        .helloWorld:       ("hello_world", "Hello, World!", .arcane),
    ]
    /// collectionShared 부수효과(E2) — 첫 배치는 happyPath(자기 regen 확정)만. 나머지 18종은 콘텐츠
    /// 패스에서 확장(효과 kind 커버리지 목적의 최소 배치). 서버 COLLECTION_SHARED_RIDER 1:1.
    static let collectionSharedRiderTable: [PetCollection: SkillRider] = [
        .happyPath: SkillRider(effectId: "autoscaling", chance: 1.0, selfTarget: true),   // 낙관 회복(확정)
    ]
    static func collectionShared(for collection: PetCollection) -> Skill {
        let e = collectionSharedTable[collection]!   // 19컬렉션 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: e.type, power: collectionSharedPower, tier: .collectionShared,
                     rider: collectionSharedRiderTable[collection])
    }

    static let uniquePower = 14.0

    /// unique — Epic 이상 per-kind 고유기(variant 3). **자기타입 시그니처**(고파워 STAB) — variant 2
    /// collectionShared가 오프타입 커버리지를 주므로, variant 3은 "자기타입 한 방" 역할. power 14.
    /// per-kind 데이터라 서버는 `scripts/gen_pet_meta.py`가 pet_meta_gen.ts `UNIQUE_SKILL`로 포팅.
    /// **저레어(Common/Rare)는 여기 없음** → variant 3에서도 3슬롯 유지(레어리티 차별화). 톤: 개발 + AI 밈.
    static let uniqueTable: [PetKind: (id: String, name: String)] = [
        // Epic (23)
        .maskDude:      ("anon_commit", "익명 커밋"),
        .ghost:         ("zombie_process", "좀비 프로세스"),
        .plant:         ("dependency_tree", "의존성 트리"),
        .skull:         ("segfault", "세그폴트"),
        .ogre:          ("monolith", "모놀리스"),
        .bigDemon:      ("prod_outage", "프로덕션 장애"),
        .kingHuman:     ("legacy_monarch", "레거시 군주"),
        .clownCaptain:  ("clown_deploy", "광대 배포"),
        .wizardM:       ("hallucination", "환각 시전"),
        .knightF:       ("blue_green", "블루-그린 배포"),
        .visorBot:      ("gradient_explosion", "그래디언트 폭발"),
        .princessSera:  ("graceful_shutdown", "우아한 종료"),
        .mrMochi:       ("infinite_scroll", "무한 스크롤"),
        .geralt:        ("prompt_injection", "프롬프트 인젝션"),
        .roboRetro:     ("quantization", "양자화"),
        .orc:           ("brute_merge", "강제 머지"),
        .fairy:         ("pixie_patch", "픽시 패치"),
        .gordon:        ("crunch_mode", "크런치 모드"),
        .skeletonLord:  ("dead_code", "데드 코드"),
        .dinoDragon:    ("dino_stack", "공룡 스택"),
        .pterodactyl:   ("race_condition", "레이스 컨디션"),
        .heroKnight:    ("full_refactor", "풀 리팩터"),
        .huntress:      ("pinpoint_debug", "핀포인트 디버그"),
        // Legendary (6)
        .ninjaFrog:     ("stealth_deploy", "은신 배포"),
        .knightM:       ("zero_downtime", "무중단 배포"),
        .pirateCaptain: ("code_plunder", "코드 약탈"),
        .whale:         ("docker_whale", "도커 웨일"),
        .tRex:          ("extinction_event", "레거시 멸종"),
        .medievalKing:  ("feudal_arch", "봉건 아키텍처"),
        // Mythic (5)
        .warrior:       ("fullstack_smash", "풀스택 강타"),
        .lancer:        ("zero_day", "제로데이"),
        .monk:          ("zen_mode", "젠 모드"),
        .archer:        ("remote_exec", "원격 실행"),
        .pawn:          ("merge_conflict", "머지 컨플릭트"),
    ]
    /// Epic+ 고유기(자기타입 시그니처). 저레어는 nil. 서버 pvp_policy.uniqueSkill 1:1.
    /// rider는 자기 타입의 typeShared rider를 **상속** — 선택 AI가 같은 타입 고파워 unique로 typeShared를
    /// 항상 지배하므로(21 > 16.5), 상속하지 않으면 Epic+ 펫은 rider가 영영 발동하지 않는다(E2 실측).
    /// 사실상 "타입 특성": 자기타입 공격(ts/unique)이면 타입 rider가 살아있다.
    static func unique(for kind: PetKind) -> Skill? {
        guard let e = uniqueTable[kind] else { return nil }
        return Skill(id: e.id, name: e.name, type: kind.battleType, power: uniquePower, tier: .unique,
                     rider: typeSharedRiderTable[kind.battleType])
    }

    static let ultimatePower = 24.0

    /// ultimate — 레인보우(variant 4) 궁극기. **타입별 6종**(규칙 파생), 자기타입 시그니처 power 24.
    /// 정규 슬롯이 아니라 충전 게이지(BattleEngine.ultChargeCost)가 차면 발동. 효과는 effects
    /// 페이즈로 분리(현재 순수 고파워). 톤: 개발 밈 아이코닉. 서버 pvp_policy.ultimateSkill 1:1.
    static let ultimateTable: [BattleType: (id: String, name: String)] = [
        .beast:   ("kernel_panic", "커널 패닉"),
        .warrior: ("rm_rf", "rm -rf --no-preserve-root"),
        .chaos:   ("total_outage", "전면 장애"),
        .arcane:  ("context_window_exceeded", "컨텍스트 초과"),
        .machine: ("blue_screen", "블루 스크린"),
        .mascot:  ("full_rollback", "전체 롤백"),
    ]
    /// 타입의 궁극기(순수 — 발동 조건 variant4는 엔진이 isRainbow로 게이팅).
    static func ultimate(for type: BattleType) -> Skill {
        let e = ultimateTable[type]!   // 6타입 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: type, power: ultimatePower, tier: .ultimate)
    }
    static let ultimateIds: Set<String> = Set(ultimateTable.values.map { $0.id })
    static func isUltimate(_ id: String) -> Bool { ultimateIds.contains(id) }

    /// 궁극기 특수효과 (E2, pet-effects.md §7.5) — 히트 변형 3종(그 한 방의 계산 변경) + 지속/즉시 3종.
    /// 서버 pvp_policy.ULT_EFFECT 1:1. 발동은 BattleEngine.attack이 궁극기 시전 시 적용.
    enum UltimateEffect: Equatable {
        case defIgnore          // rm_rf — 방어무시: defEff × ultDefIgnoreMult로 계산
        case forceCrit          // context_window_exceeded — 확정 크리(크리 draw는 소비, 결과만 강제 — 스트림 보존)
        case splash             // kernel_panic — 후열 전원에 최종 데미지 × ultSplashMult
        case grant(String)      // total_outage/blue_screen — 적 활성에 효과 부여(확정)
        case selfHeal(Double)   // full_rollback — 자힐 maxHP 비율(즉시)
    }
    static let ultDefIgnoreMult = 0.3
    static let ultSplashMult = 0.3
    static let ultimateEffectTable: [String: UltimateEffect] = [
        "rm_rf":                   .defIgnore,
        "context_window_exceeded": .forceCrit,
        "kernel_panic":            .splash,
        "total_outage":            .grant("outage_stun"),
        "blue_screen":             .grant("bsod_lag"),
        "full_rollback":           .selfHeal(0.25),
    ]

    /// 이 펫이 variant까지 해금한 정규 스킬 목록. 슬롯 인덱스 순(선택 AI tie-break 기준).
    /// 서버 pvp_policy.skillsFor 1:1.
    static func skills(kind: PetKind, variant: Int) -> [Skill] {
        let t = kind.battleType
        var out = [generic(for: t)]                                      // 슬롯0 — 항상 보유
        if variant >= 1 { out.append(typeShared(for: t)) }              // 슬롯1 — 이로치1
        if variant >= 2 { out.append(collectionShared(for: kind.collection)) }  // 슬롯2 — 이로치2(오프타입 커버리지)
        if variant >= 3, let u = unique(for: kind) { out.append(u) }    // 슬롯3 — 이로치3, Epic+ 고유기(자기타입)
        // 궁극기(variant 4)는 **의도적으로 여기 없음** — 정규 선택 슬롯이 아니라 BattleEngine 충전 게이지로 발동.
        return out
    }

    /// 스킬 기대 데미지 점수 = power × skillEff × stab (결정적, RNG 없음).
    static func score(_ s: Skill, attackerType: BattleType, defenderType: BattleType) -> Double {
        s.power * skillEffectiveness(s.type, vs: defenderType) * stab(skillType: s.type, petType: attackerType)
    }

    /// 결정적 선택 AI — 점수 최대, 동점이면 슬롯 인덱스 낮은 것(strict >). 서버 selectSkill 1:1.
    /// 전제: `skills`는 비지 않음(`skills(kind:variant:)`가 generic을 항상 첫 슬롯에 넣음).
    /// ⚠️ 파리티: score(power×eff×stab)가 Phase A/B1에선 전부 dyadic rational(power 8/11/12, 배수
    /// 0.5/1.0/1.5/2.0)이라 Swift Double·JS number가 비트동일 → tie-break 결과 일치. B2에서 비-dyadic
    /// power/배수(예: 13, ×1.3)를 도입하면 반올림이 갈려 동점 tie-break가 어긋날 수 있으니 dyadic 유지.
    static func select(from skills: [Skill], attackerType: BattleType, defenderType: BattleType) -> Skill {
        var best = skills[0]
        var bestScore = score(best, attackerType: attackerType, defenderType: defenderType)
        for s in skills.dropFirst() {
            let sc = score(s, attackerType: attackerType, defenderType: defenderType)
            if sc > bestScore { bestScore = sc; best = s }
        }
        return best
    }

    /// 스킬 id → 표시명(로그 UI). 구 로그의 "basic"/"signature"는 없음(호출부에서 레거시 폴백).
    static let nameById: [String: String] = {
        var m: [String: String] = ["hotfix": "핫픽스"]
        for (_, e) in typeSharedTable { m[e.id] = e.name }
        for (_, e) in collectionSharedTable { m[e.id] = e.name }
        for (_, e) in uniqueTable { m[e.id] = e.name }
        for (_, e) in ultimateTable { m[e.id] = e.name }
        return m
    }()
    static func displayName(id: String) -> String? { nameById[id] }
}
