import Foundation

// 펫간 상성 3층 (P0.5) — 타입 6-사이클(PetBattleStats) 위에 얹는 세밀 상성.
// 설계 SSOT: docs/plans/pet-battle.md §2-10.
//
//  A. 팀 시너지     — 같은 컬렉션/타입 팀원끼리 스탯 버프 (팀 빌딩 전략)
//  B. 밈 라이벌      — 큐레이션 dev-밈 라이벌 페어, 큰 보너스 + 배틀로그 대사
//  C. 컬렉션 상성망  — 컬렉션 간 강약(타입 6개보다 세밀), 작은 보너스
//
// B/C는 데미지식에서 타입 상성과 곱해진다: dmg = (atk/def)×power×typeEff×collectionMult×rng.
// A는 팀 구성 시 스탯에 곱해진다.

// MARK: - A. 팀 시너지

/// 스탯 선택자 — 방향성 타입 시너지가 어느 스탯을 강화하는지.
enum StatKind: Equatable { case hp, atk, def, spd }

enum TeamSynergy {
    /// 같은 컬렉션(동족) 최대 수 → **전 스탯** 버프(강한 유대라 크게). 5마리까지 가속 누진.
    static let collectionBonus: [Int: Double] = [2: 0.05, 3: 0.10, 4: 0.17, 5: 0.26]
    /// 같은 배틀 타입 최대 동속 수 → **그 타입 대표 스탯만** 버프(방향성). 5마리까지 가속 누진.
    static let typeBonus: [Int: Double] = [2: 0.03, 3: 0.06, 4: 0.10, 5: 0.15]

    /// 각 타입 시너지가 강화하는 대표 스탯(아키타입 성향). 타입 정체성 강화·팀빌딩 다양화.
    static func signatureStat(of type: BattleType) -> StatKind {
        switch type {
        case .beast:   return .spd   // 짐승 = 민첩
        case .warrior: return .atk   // 전사 = 공격
        case .arcane:  return .atk   // 비전 = 유리대포(공격)
        case .chaos:   return .spd   // 혼돈 = 난동(속도)
        case .machine: return .def   // 기계 = 장갑(방어)
        case .mascot:  return .hp    // 마스코트 = 탱커(체력)
        }
    }

    /// 팀 시너지 결과 — 동족(전 스탯 곱) + 동타입(대표 스탯만 추가 곱).
    struct Bonus: Equatable {
        var collectionMult: Double   // 전 스탯에 곱(≥1.0)
        var typeStat: StatKind?      // 방향성 버프 대상 스탯(없으면 nil)
        var typeAdd: Double          // 그 스탯에 추가로 더해질 배수분
        static let none = Bonus(collectionMult: 1.0, typeStat: nil, typeAdd: 0)
    }

    /// 팀 구성에서 시너지 산출. 종 유니크 전제라 컬렉션/타입 그룹 크기로 판정.
    /// 최다 타입 tie-break는 **팀 순서 first-max(strict >)** — 서버 pvp_policy.teamSynergyBonus 와 1:1.
    /// (5마리 팀은 타입이 2+2+1처럼 동수로 갈릴 수 있어, Dictionary 비결정 순서 대신 팀 순서로 확정.)
    static func bonus(for members: [BattlePetSnapshot]) -> Bonus {
        guard members.count >= 2 else { return .none }
        // 같은 컬렉션 최대 수 — 값만 필요(순서 무관).
        var collCounts: [PetCollection: Int] = [:]
        for m in members { collCounts[m.kind.collection, default: 0] += 1 }
        let maxCollection = collCounts.values.max() ?? 1
        let collMult = 1.0 + (collectionBonus[maxCollection] ?? 0)
        // 최다 타입 — 팀 순서로 순회하며 strict > 로 갱신 → 동수면 먼저 등장한 타입 채택(서버와 동일).
        var typeCounts: [BattleType: Int] = [:]
        for m in members { typeCounts[m.kind.battleType, default: 0] += 1 }
        var topType: BattleType? = nil
        var topCount = 0
        for m in members {
            let c = typeCounts[m.kind.battleType] ?? 0
            if c > topCount { topCount = c; topType = m.kind.battleType }
        }
        if let topType, let add = typeBonus[topCount] {
            return Bonus(collectionMult: collMult, typeStat: signatureStat(of: topType), typeAdd: add)
        }
        return Bonus(collectionMult: collMult, typeStat: nil, typeAdd: 0)
    }

    /// 특정 스탯의 최종 시너지 배수. finalStats·서버 파리티에서 사용.
    static func statMultiplier(_ b: Bonus, _ stat: StatKind) -> Double {
        b.collectionMult + (b.typeStat == stat ? b.typeAdd : 0)
    }
}

// MARK: - B/C. 컬렉션 상성 (밈 라이벌 + 상성망)

enum PetSynergy {
    /// 밈 라이벌 우위 배수 (큰 보너스).
    static let memeMultiplier = 1.30
    /// 컬렉션 상성망 우위 배수 (작은 보너스). 역방향은 역수.
    static let networkMultiplier = 1.12

    /// B. 밈 라이벌 — attacker ▶ defender 시 큰 보너스 + 배틀로그 대사. dev-밈 근거.
    /// (역방향, 즉 라이벌에게 공격받는 쪽은 1/memeMultiplier로 약화)
    static let memeRivals: [PetCollection: [PetCollection: String]] = [
        .noVerify:        [.ciRunners:     "--no-verify. CI? 그게 뭔데."],
        .dns:             [.mainframe:     "네 컴퓨터가 아니라 DNS였어."],
        .onCall:          [.fridayDeploy:  "삐삐 울렸다. 금요일 장애, 진압."],
        .rustEvangelists: [.deprecated:    "그거, Rust로 다시 짜면 되잖아?"],
        .oomKilled:       [.nodeModules:   "node_modules가 메모리를 다 먹었다."],
        .wontfix:         [.todoSince2019: "닫아도 닫아도 살아 돌아온다."],
        .tenXEngineer:    [.vibeCoders:    "vibe로는 안 돼. 실력으로 갈아넣는다."],
        .tokenBurners:    [.npmInstall:    "의존성 지옥? context에 통째로 태워버려."],
        .fridayDeploy:    [.happyPath:     "금요일 5시. 평화는 끝났다."],
    ]

    /// C. 컬렉션 상성망 — attacker가 강한 상대들(대사 없는 작은 보너스). 밈 라이벌과 모순되지 않게 큐레이션.
    static let networkStrong: [PetCollection: Set<PetCollection>] = [
        .mainframe:        [.deprecated],
        .emotionalSupport: [.oomKilled],
        .vibeCoders:       [.todoSince2019],
        .npmInstall:       [.happyPath],
        .ciRunners:        [.wontfix],
        .tokenBurners:     [.helloWorld],
        .onCall:           [.oomKilled],
        .rustEvangelists:  [.npmInstall],
    ]

    /// 컬렉션 상성 배수 + (밈 라이벌이면) 배틀로그 대사. 우선순위: 밈 > 상성망 > 중립.
    static func matchup(_ attacker: PetCollection, vs defender: PetCollection) -> (mult: Double, quip: String?) {
        if let quip = memeRivals[attacker]?[defender] {
            return (memeMultiplier, quip)                      // A ▶ D 밈 우위
        }
        if memeRivals[defender]?[attacker] != nil {
            return (1.0 / memeMultiplier, nil)                 // D ▶ A 밈 → A는 약화
        }
        if networkStrong[attacker]?.contains(defender) == true {
            return (networkMultiplier, nil)                    // 상성망 우위
        }
        if networkStrong[defender]?.contains(attacker) == true {
            return (1.0 / networkMultiplier, nil)              // 상성망 열위
        }
        return (1.0, nil)
    }
}
