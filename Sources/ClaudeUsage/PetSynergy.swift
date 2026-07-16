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

enum TeamSynergy {
    /// 같은 컬렉션(dev-밈 그룹) 최대 동족 수 → 버프. 강한 유대라 크게.
    static let collectionBonus: [Int: Double] = [2: 0.05, 3: 0.10]
    /// 같은 배틀 타입 최대 동속 수 → 버프. 느슨한 유대라 작게. (동족은 자동으로 동속이라 소폭 중첩 = 의도)
    static let typeBonus: [Int: Double] = [2: 0.03, 3: 0.05]

    /// 팀 전체에 곱해질 스탯 배수. 종 유니크 전제라 컬렉션/타입 그룹 크기로 판정.
    static func multiplier(for members: [BattlePetSnapshot]) -> Double {
        guard members.count >= 2 else { return 1.0 }
        let maxCollection = Dictionary(grouping: members, by: { $0.kind.collection })
            .values.map(\.count).max() ?? 1
        let maxType = Dictionary(grouping: members, by: { $0.kind.battleType })
            .values.map(\.count).max() ?? 1
        return 1.0 + (collectionBonus[maxCollection] ?? 0) + (typeBonus[maxType] ?? 0)
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
