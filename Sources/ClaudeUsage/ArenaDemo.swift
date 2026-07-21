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
        battleSection5v5(seed: 5_555_555)
        battleSectionRainbow(seed: 9_999_999)
        battleSectionCoverage(seed: 2_468_013)

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
        print("\n[ 스킬 타입 상성 6-사이클 ]  우위 ×2.0 / 열위 ×0.5  (+ 자속 STAB ×1.5)")
        for t in BattleType.allCases {
            print("  \(pad(t.displayName,8)) ▶ \(pad(t.beats.displayName,8))  (역: \(t.beats.displayName) ▶ \(t.displayName) ×0.5)")
        }
    }

    // MARK: 펫간 상성
    private static func synergySection() {
        print("\n[ 펫간 상성 3층 ]")
        let mono = [BattlePetSnapshot(kind: .fox), BattlePetSnapshot(kind: .wolf), BattlePetSnapshot(kind: .bear)]
        let bonus = TeamSynergy.bonus(for: mono)
        print(String(format: "  A. 팀 시너지: [fox,wolf,bear] 모노 mainframe(beast) → 전 스탯 ×%.2f + 속도 추가 ×%.2f",
                     bonus.collectionMult, bonus.collectionMult + bonus.typeAdd))
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
            if e.parried { extras.append("🛡️가드") }
            if e.defenderFainted { extras.append("💀 KO") }
            let tag = extras.isEmpty ? "" : "  [\(extras.joined(separator: " "))]"
            let quip = e.quip.map { "  «\($0)»" } ?? ""
            print("  R\(pad(String(e.round),2)) \(side) \(pad(name(e.attackerKind),11)) ▶ \(pad(name(e.defenderKind),11)) "
                + "\(pad(e.move,9)) dmg \(pad(String(e.damage),3))\(tag)\(quip)")
        }
        let winner = r.winner.map { $0 == .a ? "팀 A" : "팀 B" } ?? "무승부"
        print("  ── 승자: \(winner)  (\(r.rounds) 라운드, \(r.log.count) 액션) ──")
    }

    // MARK: 5v5 배틀 (누진 시너지 4/5 티어 + 타입 동수 tie-break 파리티용 골든)
    private static func battleSection5v5(seed: UInt64) {
        // A: warrior 컬렉션 5동족(컬렉션5=+0.26 · 타입5=+0.15 atk) — 최고 티어 경로.
        // B: 타입 동수(beast fox,wolf=2 · machine scrapBot,antennaBot=2 · warrior 1) → tie는 팀 순서상
        //    먼저 등장한 beast(spd) 채택 — tie-break 파리티 경로.
        let teamA = BattleTeam([
            BattlePetSnapshot(kind: .warrior, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .lancer, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .monk, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .archer, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .pawn, enhanceLevel: 5, progressUnits: 2),
        ])
        let teamB = BattleTeam([
            BattlePetSnapshot(kind: .fox, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .wolf, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .scrapBot, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .antennaBot, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .warrior, enhanceLevel: 5, progressUnits: 2),
        ])
        print("\n[ 5v5 배틀 ]  seed=\(seed)")
        print("  A: warrior·lancer·monk·archer·pawn (5동족)   vs   B: fox·wolf·scrapBot·antennaBot·warrior (타입 동수)")
        let r = BattleEngine.simulate(teamA: teamA, teamB: teamB, seed: seed)
        let winner = r.winner.map { $0 == .a ? "a" : "b" } ?? "draw"
        // 파리티 골든 캡처용 한 줄 요약(TS pvp_engine.parity.test.ts 와 대조).
        print("  PARITY5V5 winner=\(winner) rounds=\(r.rounds) dmg=[\(r.log.map { String($0.damage) }.joined(separator: ","))]")
    }

    // MARK: 레인보우 배틀 (이로치 버프 +18% + 레인보우 크리 파리티용 골든)
    private static func battleSectionRainbow(seed: UInt64) {
        // A: 레인보우(variant 4) — 이로치 버프 + 크리 발동 / B: 기본(variant 0).
        let teamA = BattleTeam([
            BattlePetSnapshot(kind: .fox, variant: 4, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .wolf, variant: 4, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .bear, variant: 4, enhanceLevel: 5, progressUnits: 2),
        ])
        let teamB = BattleTeam([
            BattlePetSnapshot(kind: .scrapBot, variant: 0, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .antennaBot, variant: 0, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .warrior, variant: 0, enhanceLevel: 5, progressUnits: 2),
        ])
        print("\n[ 레인보우 배틀 ]  seed=\(seed)")
        let r = BattleEngine.simulate(teamA: teamA, teamB: teamB, seed: seed)
        let winner = r.winner.map { $0 == .a ? "a" : "b" } ?? "draw"
        let crits = r.log.filter { $0.crit == true }.count
        print("  PARITYRAINBOW winner=\(winner) rounds=\(r.rounds) crits=\(crits) dmg=[\(r.log.map { String($0.damage) }.joined(separator: ","))]")
    }

    // MARK: 커버리지 배틀 (variant 2 오프타입 collectionShared 선택 파리티용 골든)
    private static func battleSectionCoverage(seed: UInt64) {
        // A: variant2 mainframe(beast) 3마리 — 자기타입 beast는 machine에 약(×0.5)이라 오프타입
        //    collectionShared(mainframe_overload=machine)를 선택 AI가 골라 커버리지 발동.
        // B: variant0 machine 3마리(스킬 hotfix만).
        let teamA = BattleTeam([
            BattlePetSnapshot(kind: .fox, variant: 2, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .wolf, variant: 2, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .bear, variant: 2, enhanceLevel: 5, progressUnits: 2),
        ])
        let teamB = BattleTeam([
            BattlePetSnapshot(kind: .scrapBot, variant: 0, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .antennaBot, variant: 0, enhanceLevel: 5, progressUnits: 2),
            BattlePetSnapshot(kind: .pixelBot, variant: 0, enhanceLevel: 5, progressUnits: 2),
        ])
        print("\n[ 커버리지 배틀 ]  seed=\(seed)  (variant2 오프타입 collectionShared)")
        let r = BattleEngine.simulate(teamA: teamA, teamB: teamB, seed: seed)
        let winner = r.winner.map { $0 == .a ? "a" : "b" } ?? "draw"
        let aMoves = Set(r.log.filter { $0.attacker == .a }.map { $0.move }).sorted().joined(separator: ",")
        print("  PARITYCOVERAGE winner=\(winner) rounds=\(r.rounds) aMoves=[\(aMoves)] "
            + "dmg=[\(r.log.map { String($0.damage) }.joined(separator: ","))]")
    }
}
