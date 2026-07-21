import Foundation

// 펫 스킬 시스템 (Phase A/B1/B2) — 순수 로직. 서버 `_shared/pvp_policy.ts` 스킬 계층과 규칙 1:1.
// 설계 SSOT: docs/plans/pet-skills.md.
//
// 이로치(variant) 단계마다 스킬을 얻는다: variant 0 = generic("핫픽스") / 1 = typeShared(타입 6종) /
// 2 = collectionShared(컬렉션 19종·오프타입 커버리지) / 3 = unique(Epic+ per-kind 고유기·자기타입).
// (Phase C에서 variant 4 궁극기 추가 예정.)
// 데미지식은 "스킬 타입 vs 방어자 타입" 상성(×2.0/×0.5)과 자속(STAB ×1.5)으로 전환 — 패시브 ×1.6/0.625 대체.
// generic/typeShared 는 펫 타입에서 **규칙 파생**이라 per-kind 데이터가 없고, 양측 동일 로직으로 재현된다.

enum SkillTier: String, Codable, Equatable {
    case generic, typeShared, collectionShared, unique, ultimate
}

/// 한 개의 스킬. `type`은 6배틀타입 중 하나, `power`는 데미지 계수, `tier`는 획득 계층.
struct Skill: Equatable {
    let id: String
    let name: String
    let type: BattleType
    let power: Double
    let tier: SkillTier
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
    static func typeShared(for type: BattleType) -> Skill {
        let e = typeSharedTable[type]!   // 6타입 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: type, power: typeSharedPower, tier: .typeShared)
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
    static func collectionShared(for collection: PetCollection) -> Skill {
        let e = collectionSharedTable[collection]!   // 19컬렉션 전부 정의 — 강제 언랩 안전.
        return Skill(id: e.id, name: e.name, type: e.type, power: collectionSharedPower, tier: .collectionShared)
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
    static func unique(for kind: PetKind) -> Skill? {
        guard let e = uniqueTable[kind] else { return nil }
        return Skill(id: e.id, name: e.name, type: kind.battleType, power: uniquePower, tier: .unique)
    }

    static let ultimatePower = 24.0

    /// ultimate — 레인보우(variant 4) 궁극기. **타입별 6종**(규칙 파생), 자기타입 시그니처 power 24.
    /// 정규 슬롯이 아니라 충전 게이지(BattleEngine.ultChargeActions)가 차면 발동. 효과는 effects
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

    /// 이 펫이 variant까지 해금한 정규 스킬 목록. 슬롯 인덱스 순(선택 AI tie-break 기준).
    /// 서버 pvp_policy.skillsFor 1:1.
    static func skills(kind: PetKind, variant: Int) -> [Skill] {
        let t = kind.battleType
        var out = [generic(for: t)]                                      // 슬롯0 — 항상 보유
        if variant >= 1 { out.append(typeShared(for: t)) }              // 슬롯1 — 이로치1
        if variant >= 2 { out.append(collectionShared(for: kind.collection)) }  // 슬롯2 — 이로치2(오프타입 커버리지)
        if variant >= 3, let u = unique(for: kind) { out.append(u) }    // 슬롯3 — 이로치3, Epic+ 고유기(자기타입)
        // Phase C: variant>=4 ultimate(레인보우 궁극기)
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
