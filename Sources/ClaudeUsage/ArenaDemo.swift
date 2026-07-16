import Foundation

// 아레나 엔진 CLI 데모 (`swift run ClaudeUsage --arena-demo`).
// 실제 컴파일된 PetBattleStats / PetSynergy / EnhanceEngine / BattleEngine을 돌려
// 스탯 파생·타입 상성·펫간 상성·강화 도박·3v3 배틀을 stdout에 출력한다.
// UI/서버/에셋 없이 "엔진이 실재하고 동작한다"를 증명하는 용도. 게임 로직 무의존.
enum ArenaDemo {
    // 이름은 렌더용 displayName(@MainActor) 대신 rawValue로 — 데모는 nonisolated 유지.
    private static func name(_ k: PetKind) -> String { k.rawValue }
    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
    private static func rarity(_ k: PetKind) -> String { (PetKind.rarityFor(k) ?? .common).displayName }

    static func run() {
        let bar = String(repeating: "═", count: 60)
        print("\n\(bar)")
        print("  AIUsage 아레나 엔진 데모  (--arena-demo)")
        print("  실제 코드: PetBattleStats · PetSynergy · EnhanceEngine · BattleEngine")
        print(bar)

        statsSection()
        typeSection()
        synergySection()
        enhanceSection(seed: 20_260_716)
        battleSection(seed: 7_251_990)

        print("\n\(bar)\n  끝 — 위 전부 컴파일된 엔진의 실제 출력입니다.\n\(bar)\n")
    }

    // MARK: 스탯 파생
    private static func statsSection() {
        print("\n[ 스탯 파생 ]  base(rarity) × archetype(type) × 성장 × variant")
        func row(_ k: PetKind, enh: Int, pu: Double, label: String) {
            let s = PetBattleStats.compute(kind: k, variant: 0, enhanceLevel: enh, progressUnits: pu)
            print("  \(pad(name(k),10)) \(pad(k.battleType.displayName,8)) \(pad(rarity(k),9)) "
                + "+\(pad(String(enh),2))  HP \(pad(String(s.hp),4)) ATK \(pad(String(s.atk),4)) "
                + "DEF \(pad(String(s.def),4)) SPD \(pad(String(s.spd),4))  Σ\(s.total)  \(label)")
        }
        row(.fox, enh: 0, pu: 0, label: "무강")
        row(.fox, enh: 15, pu: 8, label: "풀강+숙련 만렙")
        row(.warrior, enh: 0, pu: 0, label: "무강 Mythic")
        row(.scrapBot, enh: 10, pu: 4, label: "+10 Machine(탱커)")
    }

    // MARK: 타입 상성
    private static func typeSection() {
        print("\n[ 타입 상성 6-사이클 ]  우위 ×1.6 / 열위 ×0.625")
        for t in BattleType.allCases {
            print("  \(pad(t.displayName,8)) ▶ \(pad(t.beats.displayName,8))  (역: \(t.beats.displayName) ▶ \(t.displayName) ×0.625)")
        }
    }

    // MARK: 펫간 상성
    private static func synergySection() {
        print("\n[ 펫간 상성 3층 ]")
        let mono = [BattlePetSnapshot(kind: .fox), BattlePetSnapshot(kind: .wolf), BattlePetSnapshot(kind: .bear)]
        print(String(format: "  A. 팀 시너지: [fox,wolf,bear] 모노 mainframe → 팀 스탯 ×%.2f", TeamSynergy.multiplier(for: mono)))
        let m1 = PetSynergy.matchup(.noVerify, vs: .ciRunners)
        print(String(format: "  B. 밈 라이벌: noVerify ▶ ciRunners ×%.2f  \"%@\"", m1.mult, m1.quip ?? ""))
        let m2 = PetSynergy.matchup(.mainframe, vs: .deprecated)
        print(String(format: "  C. 컬렉션 상성망: mainframe ▶ deprecated ×%.2f", m2.mult))
        let m3 = PetSynergy.matchup(.mainframe, vs: .dns)
        print(String(format: "     (dns▶mainframe 밈의 역방향: mainframe▶dns ×%.2f — 중립 아님)", m3.mult))
    }

    // MARK: 강화 도박
    private static func enhanceSection(seed: UInt64) {
        print("\n[ 강화 도박 ]  seed=\(seed) — 실제 서버 RNG와 동일 로직")
        var rng = SeededRNG(seed: seed)
        var level = 10
        var spentVP = 0
        var attempts = 0
        while attempts < 18 && level < EnhanceEngine.maxLevel {
            attempts += 1
            let cost = EnhanceEngine.cost(level: level)
            spentVP += cost
            let before = level
            let outcome = EnhanceEngine.roll(level: level, using: &rng)
            level = EnhanceEngine.apply(level: before, outcome: outcome)
            let icon: String
            switch outcome {
            case .success:   icon = "✅ 성공 → +\(level)"
            case .stay:      icon = "· 유지"
            case .downgrade: icon = "🔻 강등 → +\(level)"
            case .destroy:   icon = "💥 파괴! → +\(level)"
            }
            print("  시도\(pad(String(attempts),2)) +\(pad(String(before),2)) (VP \(pad(String(cost),4)))  \(icon)")
        }
        print("  누적 VP 소모 \(spentVP.formatted()) · 최종 +\(level)")
        print("  참고: +15 도달 기대 VP = \(Int(EnhanceEngine.expectedVP(toReach: 15)).formatted()) (파괴 리셋 반영)")
    }

    // MARK: 3v3 배틀
    private static func battleSection(seed: UInt64) {
        // A: --no-verify 해적 + beast 2 / B: CI 로봇 2 + beast 1  → 타입·밈 상성 둘 다 등장
        let teamA = BattleTeam([
            BattlePetSnapshot(kind: .baldPirate, enhanceLevel: 8, progressUnits: 4),  // noVerify / warrior
            BattlePetSnapshot(kind: .fox, enhanceLevel: 8, progressUnits: 4),          // mainframe / beast
            BattlePetSnapshot(kind: .wolf, enhanceLevel: 8, progressUnits: 4),         // mainframe / beast
        ])
        let teamB = BattleTeam([
            BattlePetSnapshot(kind: .scrapBot, enhanceLevel: 8, progressUnits: 4),     // ciRunners / machine (beast 카운터)
            BattlePetSnapshot(kind: .antennaBot, enhanceLevel: 8, progressUnits: 4),   // ciRunners / machine
            BattlePetSnapshot(kind: .bear, enhanceLevel: 8, progressUnits: 4),         // mainframe / beast
        ])
        print("\n[ 3v3 배틀 ]  seed=\(seed)")
        print("  A: baldPirate(noVerify) · fox · wolf   vs   B: scrapBot(machine) · antennaBot · bear")
        let r = BattleEngine.simulate(teamA: teamA, teamB: teamB, seed: seed)
        for e in r.log {
            let side = e.attacker == .a ? "A" : "B"
            var extras: [String] = []
            if e.effectiveness > 1 { extras.append("타입▲") } else if e.effectiveness < 1 { extras.append("타입▼") }
            if e.collectionMult > 1.01 { extras.append("상성▲") } else if e.collectionMult < 0.99 { extras.append("상성▼") }
            if e.defenderFainted { extras.append("💀 KO") }
            let tag = extras.isEmpty ? "" : "  [\(extras.joined(separator: " "))]"
            let quip = e.quip.map { "  «\($0)»" } ?? ""
            print("  R\(pad(String(e.round),2)) \(side) \(pad(name(e.attackerKind),11)) ▶ \(pad(name(e.defenderKind),11)) "
                + "\(pad(e.move,9)) dmg \(pad(String(e.damage),3))\(tag)\(quip)")
        }
        let winner = r.winner.map { $0 == .a ? "팀 A" : "팀 B" } ?? "무승부"
        print("  ── 승자: \(winner)  (\(r.rounds) 라운드, \(r.log.count) 액션) ──")
    }
}
