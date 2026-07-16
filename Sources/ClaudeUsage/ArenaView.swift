import SwiftUI

// 아레나 탭 (P1 UI — 로컬 슬라이스). 서버/에셋 없이 P0 엔진(BattleEngine·EnhanceEngine·
// PetBattleStats·PetSynergy)을 직접 써서 "연습전(로컬 자동전투)"과 "강화소(로컬 도박 샌드박스)"를
// 클릭·관전 가능하게 한다. VP 차감·레이팅·시즌 보상·도트 연출은 후속(P1b 서버 연동 + 에셋).
// 설계: docs/plans/pet-battle.md §2-2 / §2-9 / §5-1.
@MainActor
struct ArenaView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var mode: Mode = .practice

    // 연습전
    @State private var teamKinds: [PetKind] = []
    @State private var opponentKinds: [PetKind] = []
    @State private var result: BattleResult?

    // 강화소 (로컬 샌드박스)
    @State private var enhanceKind: PetKind?
    @State private var localLevels: [PetKind: Int] = [:]
    @State private var enhanceHistory: [EnhanceLine] = []
    @State private var enhanceSeed: UInt64 = 1

    enum Mode: String, CaseIterable, Identifiable {
        case practice = "연습전", enhance = "강화소"
        var id: String { rawValue }
    }
    struct EnhanceLine: Identifiable { let id = UUID(); let text: String; let color: Color }

    private var owned: [PetKind] { PetKind.allCases.filter { settings.ownedPets[$0] != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if owned.isEmpty {
                    emptyGate
                } else {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()

                    if mode == .practice { practiceSection } else { enhanceSection }
                }
            }
            .padding(16)
        }
        .onAppear {
            if teamKinds.isEmpty { teamKinds = Array(owned.prefix(3)) }
            if enhanceKind == nil { enhanceKind = owned.first }
        }
    }

    // MARK: 헤더 / 게이트

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("⚔️ 아레나").font(.system(size: 15, weight: .bold))
            Text("연습전·강화소는 로컬 미리보기입니다 — 레이팅·VP·시즌 보상·도트 연출은 서버 연동 후.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private var emptyGate: some View {
        VStack(spacing: 8) {
            Image(systemName: "pawprint.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("배틀에 쓸 펫이 없습니다.").font(.system(size: 12))
            Text("상점 탭에서 가챠를 돌려 펫을 모으세요.").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    // MARK: 연습전

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("내 배틀 팀").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(String(format: "팀 시너지 ×%.2f", teamSynergy))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tint)
                Button { teamKinds = Array(owned.shuffled().prefix(3)); result = nil } label: {
                    Label("팀 새로 뽑기", systemImage: "shuffle").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            HStack(spacing: 8) {
                ForEach(teamKinds, id: \.self) { petCard($0) }
                if teamKinds.isEmpty { Text("펫 없음").font(.system(size: 11)).foregroundStyle(.secondary) }
            }

            Button { fight() } label: {
                Text("⚔️ 연습전 시작").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }.buttonStyle(.plain).disabled(teamKinds.isEmpty)

            if let r = result { resultView(r) }
        }
    }

    private func petCard(_ kind: PetKind) -> some View {
        let s = PetBattleStats.compute(kind: kind, variant: 0, enhanceLevel: 0, progressUnits: 0)
        return VStack(spacing: 3) {
            thumb(kind, h: 30)
            Text(PetMetaStore.shared.displayName(for: kind)).font(.system(size: 8)).lineLimit(1)
            typeBadge(kind.battleType)
            Text("Σ\(s.total)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
        }
        .frame(width: 74).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.08)))
    }

    private func resultView(_ r: BattleResult) -> some View {
        let win = r.winner
        let title = win == .a ? "🏆 승리!" : (win == .b ? "패배…" : "무승부")
        let color: Color = win == .a ? .green : (win == .b ? .red : .secondary)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
                Spacer()
                Text("vs \(opponentKinds.map { PetMetaStore.shared.displayName(for: $0) }.joined(separator: ", "))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            Text("\(r.rounds) 라운드 · \(r.log.count) 액션").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(r.log.enumerated()), id: \.offset) { _, e in logLine(e) }
                }
            }
            .frame(height: 190)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
        }
    }

    private func logLine(_ e: BattleEvent) -> some View {
        let side = e.attacker == .a ? "A" : "B"
        var tags = ""
        if e.effectiveness > 1 { tags += " 타입▲" } else if e.effectiveness < 1 { tags += " 타입▼" }
        if e.collectionMult > 1.01 { tags += " 상성▲" } else if e.collectionMult < 0.99 { tags += " 상성▼" }
        if e.defenderFainted { tags += " 💀" }
        return VStack(alignment: .leading, spacing: 0) {
            Text("R\(e.round) \(side)  \(PetMetaStore.shared.displayName(for: e.attackerKind)) ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind))  \(e.damage)\(tags)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(e.attacker == .a ? Color.primary : Color.secondary)
            if let q = e.quip {
                Text("  «\(q)»").font(.system(size: 9)).italic().foregroundStyle(.tint)
            }
        }
    }

    private var teamSynergy: Double {
        TeamSynergy.multiplier(for: teamKinds.map { BattlePetSnapshot(kind: $0) })
    }

    private func fight() {
        opponentKinds = Array(PetKind.allCases.shuffled().prefix(min(3, max(1, teamKinds.count))))
        let a = BattleTeam(teamKinds.map { BattlePetSnapshot(kind: $0) })
        let b = BattleTeam(opponentKinds.map { BattlePetSnapshot(kind: $0) })
        result = BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64.random(in: 1...UInt64.max))
    }

    // MARK: 강화소 (로컬 샌드박스)

    private var enhanceSection: some View {
        let kind = enhanceKind ?? owned.first ?? .fox
        let level = localLevels[kind] ?? 0
        let stats = PetBattleStats.compute(kind: kind, variant: 0, enhanceLevel: level, progressUnits: 0)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                thumb(kind, h: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Picker("", selection: Binding(get: { kind }, set: { enhanceKind = $0 })) {
                        ForEach(owned, id: \.self) { Text(PetMetaStore.shared.displayName(for: $0)).tag($0) }
                    }.labelsHidden().frame(maxWidth: 180)
                    HStack(spacing: 6) {
                        typeBadge(kind.battleType)
                        Text("강화 +\(level)").font(.system(size: 12, weight: .bold)).foregroundStyle(.tint)
                    }
                    Text("HP \(stats.hp)  ATK \(stats.atk)  DEF \(stats.def)  SPD \(stats.spd)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            if level < EnhanceEngine.maxLevel {
                oddsBar(level: level)
                HStack {
                    Text("이번 시도 VP \(EnhanceEngine.cost(level: level).formatted())")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text(zoneLabel(level)).font(.system(size: 10, weight: .semibold)).foregroundStyle(zoneColor(level))
                }
                Button { attemptEnhance(kind) } label: {
                    Text("⚒️ 강화 시도").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.orange))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            } else {
                Text("★ 만렙 (+\(EnhanceEngine.maxLevel)) 달성").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            }

            Text("로컬 미리보기 — VP 미차감·미저장. +15 도달 기대 VP ≈ \(Int(EnhanceEngine.expectedVP(toReach: 15)).formatted()) (파괴 리셋 반영)")
                .font(.system(size: 9)).foregroundStyle(.secondary)

            if !enhanceHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(enhanceHistory.reversed()) { line in
                            Text(line.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(line.color)
                        }
                    }
                }
                .frame(height: 150)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    private func oddsBar(level: Int) -> some View {
        let o = EnhanceEngine.odds[level]
        let segs: [(Double, Color)] = [(o[0], .green), (o[1], .gray), (o[2], .orange), (o[3], .red)].filter { $0.0 > 0 }
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                    Rectangle().fill(seg.1)
                        .frame(width: max(0, geo.size.width * seg.0 - 1))
                        .overlay(Text("\(Int((seg.0 * 100).rounded()))%")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white).opacity(seg.0 >= 0.14 ? 1 : 0))
                }
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func attemptEnhance(_ kind: PetKind) {
        let level = localLevels[kind] ?? 0
        var rng = SeededRNG(seed: enhanceSeed)
        enhanceSeed = enhanceSeed &* 6_364_136_223_846_793_005 &+ 1
        let outcome = EnhanceEngine.roll(level: level, using: &rng)
        let newLevel = EnhanceEngine.apply(level: level, outcome: outcome)
        localLevels[kind] = newLevel
        let text: String, color: Color
        switch outcome {
        case .success:   text = "+\(level) → +\(newLevel)  ✅ 성공"; color = .green
        case .stay:      text = "+\(level)  · 유지";               color = .secondary
        case .downgrade: text = "+\(level) → +\(newLevel)  🔻 강등"; color = .orange
        case .destroy:   text = "+\(level) → +0  💥 파괴!";         color = .red
        }
        enhanceHistory.append(EnhanceLine(text: text, color: color))
        if enhanceHistory.count > 40 { enhanceHistory.removeFirst(enhanceHistory.count - 40) }
    }

    private func zoneLabel(_ level: Int) -> String {
        switch EnhanceEngine.zone(level: level) {
        case .safe: return "안전 구간"
        case .downgrade: return "하락 구간"
        case .destroy: return "파괴 구간"
        }
    }
    private func zoneColor(_ level: Int) -> Color {
        switch EnhanceEngine.zone(level: level) {
        case .safe: return .green
        case .downgrade: return .orange
        case .destroy: return .red
        }
    }

    // MARK: 공용

    @ViewBuilder private func thumb(_ kind: PetKind, h: CGFloat) -> some View {
        if let img = PetSprite.frames(for: kind, action: .walk).first ?? PetSprite.frames(for: kind, action: .sit).first {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit).frame(height: h)
        } else {
            Image(systemName: "pawprint").font(.system(size: h * 0.7)).foregroundStyle(.secondary)
        }
    }

    private func typeBadge(_ t: BattleType) -> some View {
        Text(t.displayName)
            .font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(typeColor(t).opacity(0.2)))
            .foregroundStyle(typeColor(t))
    }

    private func typeColor(_ t: BattleType) -> Color {
        switch t {
        case .beast:   return .green
        case .warrior: return .red
        case .arcane:  return .purple
        case .chaos:   return .indigo
        case .machine: return .cyan
        case .mascot:  return .pink
        }
    }
}
