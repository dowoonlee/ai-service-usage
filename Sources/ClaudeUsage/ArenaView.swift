import SwiftUI

// 아레나 탭 (P1 UI — 로컬 슬라이스). 서버/에셋 없이 P0 엔진(BattleEngine·EnhanceEngine·
// PetBattleStats·PetSynergy)을 직접 써서 "연습전(공유 스테이지 관전)"과 "강화소(펫 반응 이펙트)"를
// 클릭·관전 가능하게 한다.
//
// 배틀 레이아웃: 포켓몬 골드 배틀 UI 관례를 참고해 재구성(저작권 그래픽 복제 아님, 오리지널 도트).
//   - 상대 우상단 / 나 좌하단, 대각선 HP 박스, HP색 초록>50%/노랑20~50%/빨강<20%
//   - 상단 양 팀 파티 아이콘(기절=흑백+X), 공격 시 lunge + 피격 brightness flash
//   docs/research/pokemon-gold-battle-ui.md
// 강화 이펙트: 차지 펄스 → 성공 플래시+팝 / 강등 흔들림 / 파괴 그레이스케일+흔들림 (네이티브).
//   화려한 도트 VFX(폭발/파편/충격파)는 에셋 확보 후 얹음. docs/research/enhancement-effects.md
// VP 차감·레이팅·시즌 보상은 서버 연동 후(P1b). 설계: docs/plans/pet-battle.md §2-2 / §2-9 / §5-1.
@MainActor
struct ArenaView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var mode: Mode = .practice

    // 연습전
    @State private var teamKinds: [PetKind] = []
    @State private var opponentKinds: [PetKind] = []
    @State private var result: BattleResult?
    @State private var playbackStep = 0
    @State private var playbackTask: Task<Void, Never>?
    @State private var showFullLog = false
    // 배틀 연출 상태
    @State private var lungeSide: BattleSide?
    @State private var lungeAmount: CGFloat = 0
    @State private var flashSide: BattleSide?
    @State private var flashBrightness: Double = 0
    // 대사 말풍선
    @State private var speechText: String?
    @State private var speechSide: BattleSide?
    @State private var defenderText: String?
    @State private var defenderSide: BattleSide?

    // 강화소
    @State private var enhanceKind: PetKind?
    @State private var localLevels: [PetKind: Int] = [:]
    @State private var enhanceHistory: [EnhanceLine] = []
    @State private var enhanceSeed: UInt64 = 1
    @State private var enhancePhase: EnhancePhase = .idle
    @State private var enhanceShake: CGFloat = 0
    @State private var enhancePulse = false
    @State private var enhancePop: CGFloat = 1
    @State private var enhanceBright: Double = 0
    @State private var enhanceTask: Task<Void, Never>?
    // 대상 선택: 정렬 / 검색 / 최근 강화
    @State private var enhanceSearch = ""
    @State private var enhanceSort: TargetSort = .recent
    @State private var recentEnhanced: [PetKind] = []

    enum Mode: String, CaseIterable, Identifiable {
        case practice = "연습전", enhance = "강화소"
        var id: String { rawValue }
    }
    enum EnhancePhase: Equatable { case idle, charging, result(EnhanceOutcome) }
    struct EnhanceLine: Identifiable { let id = UUID(); let text: String; let color: Color }
    enum TargetSort: String, CaseIterable, Identifiable {
        case recent = "최근", dex = "도감", rarity = "희귀도", name = "이름"
        var id: String { rawValue }
    }

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
        .onDisappear { playbackTask?.cancel(); enhanceTask?.cancel() }
    }

    // MARK: 헤더 / 게이트

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("⚔️ 아레나").font(.system(size: 15, weight: .bold))
            Text("로컬 미리보기 — 레이팅·VP·시즌 보상은 서버 연동 후. 화려한 도트 임팩트는 에셋 확보 후.")
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
                Button { teamKinds = Array(owned.shuffled().prefix(3)); stopPlayback(); result = nil } label: {
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

            if result != nil { battleArena }
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

    // MARK: 배틀 관전 (공유 스테이지 + 파티 아이콘 + lunge/flash)

    private var battleArena: some View {
        let log = result?.log ?? []
        let done = playbackStep >= log.count
        let hp = hpDicts(step: playbackStep)
        let current: BattleEvent? = (playbackStep > 0 && playbackStep <= log.count) ? log[playbackStep - 1] : nil
        let aActive = teamKinds.first { (hp.a[$0] ?? 0) > 0 }
        let bActive = opponentKinds.first { (hp.b[$0] ?? 0) > 0 }
        return VStack(spacing: 8) {
            partyRow(hp: hp, aActive: aActive, bActive: bActive)
            battleStage(hp: hp, aActive: aActive, bActive: bActive, current: current)
                .overlay { if done { resultBanner(result?.winner) } }
            currentActionLine(current)
            controls(total: log.count)
            if showFullLog { fullLog(log) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.secondary.opacity(0.06)))
    }

    private func partyRow(hp: (a: [PetKind: Int], b: [PetKind: Int]), aActive: PetKind?, bActive: PetKind?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(teamKinds, id: \.self) { partyIcon($0, fainted: (hp.a[$0] ?? 0) <= 0, active: $0 == aActive) }
            }
            Spacer()
            Text("VS").font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 3) {
                ForEach(opponentKinds, id: \.self) { partyIcon($0, fainted: (hp.b[$0] ?? 0) <= 0, active: $0 == bActive) }
            }
        }
    }

    private func partyIcon(_ kind: PetKind, fainted: Bool, active: Bool) -> some View {
        thumb(kind, h: 18)
            .grayscale(fainted ? 1 : 0)
            .opacity(fainted ? 0.55 : 1)
            .frame(width: 24, height: 24)
            .overlay { if fainted { Image(systemName: "xmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(.red.opacity(0.85)) } }
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? Color.accentColor.opacity(0.18) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1.2))
    }

    private func battleStage(hp: (a: [PetKind: Int], b: [PetKind: Int]), aActive: PetKind?, bActive: PetKind?, current: BattleEvent?) -> some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // 지면
                LinearGradient(colors: [Color.secondary.opacity(0.05), Color.secondary.opacity(0.13)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(Color.secondary.opacity(0.10)).frame(height: 1).position(x: w/2, y: h*0.62)

                if let k = bActive {
                    stagePet(k, side: .b).position(x: w * 0.73, y: h * 0.36)
                }
                if let k = aActive {
                    stagePet(k, side: .a).position(x: w * 0.27, y: h * 0.68)
                }
                // 대사 말풍선 (공격자 / 방어자 반응)
                if let t = speechText, let s = speechSide {
                    speechBubble(t, faint: false).position(x: bubbleX(s, w), y: bubbleY(s, h))
                }
                if let t = defenderText, let s = defenderSide {
                    speechBubble(t, faint: true).position(x: bubbleX(s, w), y: bubbleY(s, h))
                }
            }
            .overlay(alignment: .topLeading) {
                if let k = bActive { hpBox(k, cur: hp.b[k] ?? 0, showNumbers: false).padding(6) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let k = aActive { hpBox(k, cur: hp.a[k] ?? 0, showNumbers: true).padding(6) }
            }
        }
        .frame(height: 176)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private func bubbleX(_ s: BattleSide, _ w: CGFloat) -> CGFloat { s == .a ? w * 0.27 : w * 0.73 }
    private func bubbleY(_ s: BattleSide, _ h: CGFloat) -> CGFloat { (s == .a ? h * 0.68 : h * 0.36) - 46 }

    private func speechBubble(_ text: String, faint: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(faint ? Color.red.opacity(0.88) : Color(nsColor: .windowBackgroundColor).opacity(0.96)))
            .foregroundStyle(faint ? Color.white : Color.primary)
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            .fixedSize()
            .id(playbackStep)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
    }

    private func stagePet(_ kind: PetKind, side: BattleSide) -> some View {
        let isLunge = side == lungeSide
        let lunge: CGSize = isLunge
            ? (side == .a ? CGSize(width: lungeAmount * 34, height: -lungeAmount * 12)
                          : CGSize(width: -lungeAmount * 34, height: lungeAmount * 12))
            : .zero
        return thumb(kind, h: 56)
            .scaleEffect(x: side == .b ? -1 : 1, y: 1)   // 상대는 마주보게 좌우 반전
            .brightness(side == flashSide ? flashBrightness : 0)
            .offset(lunge)
            .id(kind)   // 교체 시 자연스러운 전환
            .transition(.opacity)
    }

    private func hpBox(_ kind: PetKind, cur: Int, showNumbers: Bool) -> some View {
        let maxv = maxHP(kind)
        let frac = maxv > 0 ? Double(max(0, cur)) / Double(maxv) : 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(PetMetaStore.shared.displayName(for: kind)).font(.system(size: 9, weight: .bold)).lineLimit(1)
                typeDot(kind.battleType)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.18))
                    Capsule().fill(hpColor(cur, maxv)).frame(width: max(0, g.size.width * frac))
                        .animation(.easeOut(duration: 0.35), value: cur)
                }
            }.frame(width: 96, height: 6)
            if showNumbers {
                Text("\(max(0, cur))/\(maxv)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
    }

    private func hpColor(_ cur: Int, _ maxv: Int) -> Color {
        guard maxv > 0 else { return .red }
        let f = Double(max(0, cur)) / Double(maxv)
        if f > 0.5 { return .green }
        if f >= 0.2 { return .yellow }
        return .red
    }

    private func controls(total: Int) -> some View {
        HStack(spacing: 12) {
            if playbackStep < total {
                Button { skipToEnd() } label: { Label("건너뛰기", systemImage: "forward.end.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            } else {
                Button { replay() } label: { Label("다시 재생", systemImage: "arrow.counterclockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.tint)
            }
            Spacer()
            Text("\(min(playbackStep, total))/\(total)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            Button { showFullLog.toggle() } label: {
                Label(showFullLog ? "로그 접기" : "전체 로그", systemImage: "list.bullet").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    private func tagString(_ e: BattleEvent) -> String {
        var tags: [String] = []
        if e.effectiveness > 1 { tags.append("타입▲") } else if e.effectiveness < 1 { tags.append("타입▼") }
        if e.collectionMult > 1.01 { tags.append("상성▲") } else if e.collectionMult < 0.99 { tags.append("상성▼") }
        if e.parried { tags.append("🛡️ 가드") }
        if e.defenderFainted { tags.append("💀 KO") }
        return tags.joined(separator: " ")
    }

    @ViewBuilder
    private func currentActionLine(_ e: BattleEvent?) -> some View {
        if let e {
            VStack(spacing: 2) {
                Text("\(PetMetaStore.shared.displayName(for: e.attackerKind)) ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind))  −\(e.damage)  \(tagString(e))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                if let q = e.quip {
                    Text("«\(q)»").font(.system(size: 10)).italic().foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity).id(playbackStep).transition(.opacity)
        } else {
            Text("전투 시작…").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func resultBanner(_ w: BattleSide?) -> some View {
        let win = w == .a
        let title = w == .a ? "승리!" : (w == .b ? "패배…" : "무승부")
        let icon = w == .a ? "🏆" : (w == .b ? "💀" : "🤝")
        let color: Color = w == .a ? .green : (w == .b ? .red : .secondary)
        return TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 0.9 + 0.1 * sin(t * 3)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.5), .clear], center: .center, startRadius: 4, endRadius: 130))
                    .frame(width: 260, height: 260).scaleEffect(pulse)
                ForEach(0..<7, id: \.self) { i in
                    Image(systemName: "sparkle")
                        .font(.system(size: 10 + CGFloat(i % 3) * 5))
                        .foregroundStyle(color)
                        .opacity(0.3 + 0.6 * abs(sin(t * 2 + Double(i))))
                        .offset(x: cos(Double(i) / 7 * .pi * 2 + t * 0.6) * 82,
                                y: sin(Double(i) / 7 * .pi * 2 + t * 0.6) * 50)
                }
                VStack(spacing: 2) {
                    Text(icon).font(.system(size: 42))
                    Text(title).font(.system(size: 24, weight: .heavy)).foregroundStyle(color)
                        .shadow(color: color.opacity(0.5), radius: 6)
                }
                .scaleEffect(win ? pulse : 1)
            }
        }
        .transition(.scale(scale: 0.4).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func fullLog(_ log: [BattleEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                    let side = e.attacker == .a ? "A" : "B"
                    Text("R\(e.round) \(side) \(PetMetaStore.shared.displayName(for: e.attackerKind)) ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind)) −\(e.damage)\(e.quip != nil ? " «\(e.quip!)»" : "")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(e.attacker == .a ? Color.primary : Color.secondary)
                }
            }
        }
        .frame(height: 130).padding(6)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: 배틀 상태 재구성 + 재생

    private func maxHP(_ kind: PetKind) -> Int {
        PetBattleStats.compute(kind: kind, variant: 0, enhanceLevel: 0, progressUnits: 0).hp
    }
    private func hpDicts(step: Int) -> (a: [PetKind: Int], b: [PetKind: Int]) {
        var a = Dictionary(uniqueKeysWithValues: teamKinds.map { ($0, maxHP($0)) })
        var b = Dictionary(uniqueKeysWithValues: opponentKinds.map { ($0, maxHP($0)) })
        for e in (result?.log ?? []).prefix(step) {
            if e.attacker == .a { b[e.defenderKind] = max(0, (b[e.defenderKind] ?? 0) - e.damage) }
            else { a[e.defenderKind] = max(0, (a[e.defenderKind] ?? 0) - e.damage) }
        }
        return (a, b)
    }
    private var teamSynergy: Double { TeamSynergy.multiplier(for: teamKinds.map { BattlePetSnapshot(kind: $0) }) }

    private func fight() {
        stopPlayback()
        opponentKinds = Array(PetKind.allCases.shuffled().prefix(min(3, max(1, teamKinds.count))))
        let a = BattleTeam(teamKinds.map { BattlePetSnapshot(kind: $0) })
        let b = BattleTeam(opponentKinds.map { BattlePetSnapshot(kind: $0) })
        let r = BattleEngine.simulate(teamA: a, teamB: b, seed: UInt64.random(in: 1...UInt64.max))
        result = r
        showFullLog = false
        startPlayback(total: r.log.count)
    }

    private func startPlayback(total: Int) {
        playbackStep = 0; lungeAmount = 0; flashBrightness = 0
        playbackTask = Task { @MainActor in
            for i in 1...max(1, total) {
                try? await Task.sleep(for: .milliseconds(360))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.15)) { playbackStep = i }
                guard let log = result?.log, i - 1 < log.count else { continue }
                let e = log[i - 1]
                lungeSide = e.attacker
                withAnimation(.easeOut(duration: 0.1)) { lungeAmount = 1 }
                let defSide: BattleSide = (e.attacker == .a) ? .b : .a
                flashSide = defSide
                flashBrightness = 0.9
                withAnimation(.easeOut(duration: 0.35)) { flashBrightness = 0 }
                // 대사: 공격자 ~30% + 방어자 반응(패링/리타이어)
                speechSide = e.attacker
                speechText = Int.random(in: 0..<10) < 3 ? BattleLines.attackLine() : nil
                if e.parried { defenderSide = defSide; defenderText = BattleLines.parryLine() }
                else if e.defenderFainted { defenderSide = defSide; defenderText = BattleLines.faintLine() }
                else { defenderText = nil; defenderSide = nil }
                try? await Task.sleep(for: .milliseconds(130))
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.12)) { lungeAmount = 0 }
            }
        }
    }
    private func skipToEnd() { stopPlayback(); withAnimation { playbackStep = result?.log.count ?? 0 } }
    private func replay() { stopPlayback(); startPlayback(total: result?.log.count ?? 0) }
    private func stopPlayback() {
        playbackTask?.cancel(); playbackTask = nil
        lungeAmount = 0; flashBrightness = 0
        speechText = nil; speechSide = nil; defenderText = nil; defenderSide = nil
    }

    // MARK: 강화소 (펫 반응 이펙트)

    private var enhanceSection: some View {
        let kind = enhanceKind ?? owned.first ?? .fox
        let level = localLevels[kind] ?? 0
        let rarity = PetKind.rarityFor(kind) ?? .common
        let stats = PetBattleStats.compute(kind: kind, variant: 0, enhanceLevel: level, progressUnits: 0)
        let destroyed = enhancePhase == .result(.destroy)
        return VStack(spacing: 12) {
            // 중앙 정렬 펫 스테이지 (반응 이펙트)
            VStack(spacing: 6) {
                ZStack {
                    if enhancePhase == .charging || enhancePulse {
                        Circle().fill(RadialGradient(colors: [Color.orange.opacity(0.35), .clear],
                                                     center: .center, startRadius: 2, endRadius: 52))
                            .frame(width: 108, height: 108)
                    }
                    thumb(kind, h: 68)
                        .grayscale(destroyed ? 1 : 0)
                        .brightness(enhanceBright)
                        .scaleEffect(enhancePop * (enhancePulse ? 1.06 : 1.0))
                        .offset(x: enhanceShake)
                        .animation(.easeInOut(duration: 0.18), value: enhancePulse)
                }
                .frame(height: 108)
                HStack(spacing: 6) {
                    Text(PetMetaStore.shared.displayName(for: kind)).font(.system(size: 12, weight: .semibold))
                    typeBadge(kind.battleType)
                    Text(rarity.displayName).font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(rarity.color.opacity(0.2))).foregroundStyle(rarity.color)
                    Text("강화 +\(level)").font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3, dampingFraction: 0.5), value: level)
                }
                statRow(stats)
            }
            .frame(maxWidth: .infinity)

            targetPicker(current: kind)

            if level < EnhanceEngine.maxLevel {
                oddsBar(level: level)
                oddsLegend(level: level)   // 정확한 % 항상 표기 (#5 — 12% 등 작은 값도 보이게)
                HStack(spacing: 6) {
                    Text("이번 시도 VP \(EnhanceEngine.cost(level: level, rarity: rarity).formatted())")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text("(\(rarity.displayName) ×\(String(format: "%.1f", EnhanceEngine.rarityCostMultiplier(rarity))))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text(zoneLabel(level)).font(.system(size: 10, weight: .semibold)).foregroundStyle(zoneColor(level))
                }
                Button { attemptEnhance(kind) } label: {
                    Text(enhancePhase == .charging ? "강화 중…" : "⚒️ 강화 시도").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.orange.opacity(enhancePhase == .idle ? 1 : 0.5)))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain).disabled(enhancePhase != .idle)
            } else {
                Text("★ 만렙 (+\(EnhanceEngine.maxLevel)) 달성").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            }

            Text("로컬 미리보기 — VP 미차감·미저장. +15 도달 기대 VP ≈ \(Int(EnhanceEngine.expectedVP(toReach: 15)).formatted()) (파괴 리셋 반영, Common 기준)")
                .font(.system(size: 9)).foregroundStyle(.secondary)

            if !enhanceHistory.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(enhanceHistory.reversed()) { line in
                            Text(line.text).font(.system(size: 10, design: .monospaced)).foregroundStyle(line.color)
                        }
                    }
                }
                .frame(height: 130).padding(8)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    // HP/ATK/DEF/SPD 아이콘 행 (#4)
    private func statRow(_ s: BattleStats) -> some View {
        HStack(spacing: 14) {
            statItem("heart.fill", .red, s.hp)
            statItem("bolt.fill", .orange, s.atk)
            statItem("shield.fill", .blue, s.def)
            statItem("hare.fill", .green, s.spd)
        }
    }
    private func statItem(_ sym: String, _ color: Color, _ val: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: sym).font(.system(size: 10)).foregroundStyle(color)
            Text("\(val)").font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }

    // 강화 대상 선택 (#2) — 정렬·검색·최근 강화 + 아이콘 스크롤(각 펫의 현재 로컬 강화 레벨 표시)
    private func targetPicker(current: PetKind) -> some View {
        let list = sortedTargets()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("강화 대상").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                TextField("검색", text: $enhanceSearch)
                    .textFieldStyle(.roundedBorder).font(.system(size: 10)).frame(width: 84)
                Picker("", selection: $enhanceSort) {
                    ForEach(TargetSort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden().frame(width: 78)
            }
            if list.isEmpty {
                Text("검색 결과 없음").font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(list, id: \.self) { k in
                            Button { if enhancePhase == .idle { enhanceKind = k } } label: {
                                VStack(spacing: 1) {
                                    thumb(k, h: 26)
                                    Text("+\(localLevels[k] ?? 0)").font(.system(size: 7, design: .monospaced)).foregroundStyle(.orange)
                                }
                                .frame(width: 42, height: 46)
                                .background(RoundedRectangle(cornerRadius: 6).fill(k == current ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.06)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(k == current ? Color.orange : .clear, lineWidth: 1.5))
                            }.buttonStyle(.plain).disabled(enhancePhase != .idle)
                        }
                    }.padding(.horizontal, 1)
                }.frame(height: 52)
            }
        }
    }

    private func dexIndex(_ k: PetKind) -> Int { PetKind.allCases.firstIndex(of: k) ?? 0 }
    private func rarityRank(_ k: PetKind) -> Int {
        guard let r = PetKind.rarityFor(k) else { return -1 }
        return Rarity.allCases.firstIndex(of: r) ?? 0
    }

    private func sortedTargets() -> [PetKind] {
        let q = enhanceSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var list = owned
        if !q.isEmpty {
            list = list.filter { PetMetaStore.shared.displayName(for: $0).lowercased().contains(q) }
        }
        switch enhanceSort {
        case .recent:
            let recent = recentEnhanced.filter { list.contains($0) }
            let recentSet = Set(recent)
            let rest = list.filter { !recentSet.contains($0) }.sorted { dexIndex($0) < dexIndex($1) }
            return recent + rest
        case .dex:
            return list.sorted { dexIndex($0) < dexIndex($1) }
        case .rarity:
            return list.sorted { a, b in
                let ra = rarityRank(a), rb = rarityRank(b)
                return ra != rb ? ra > rb : dexIndex(a) < dexIndex(b)
            }
        case .name:
            return list.sorted {
                PetMetaStore.shared.displayName(for: $0)
                    .localizedCompare(PetMetaStore.shared.displayName(for: $1)) == .orderedAscending
            }
        }
    }

    // 확률 범례 — 정확한 % 항상 표기 (#5)
    private func oddsLegend(level: Int) -> some View {
        let o = EnhanceEngine.odds[level]
        let items: [(String, Double, Color)] = [("성공", o[0], .green), ("유지", o[1], .gray),
                                                 ("강등", o[2], .orange), ("파괴", o[3], .red)].filter { $0.1 > 0 }
        return HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 3) {
                    Circle().fill(it.2).frame(width: 7, height: 7)
                    Text("\(it.0) \(Int((it.1 * 100).rounded()))%")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            Spacer()
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
                            .foregroundStyle(.white).opacity(seg.0 >= 0.10 ? 1 : 0))
                }
            }
        }
        .frame(height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func attemptEnhance(_ kind: PetKind) {
        guard enhancePhase == .idle else { return }
        // 최근 강화 목록 갱신 (맨 앞으로)
        recentEnhanced.removeAll { $0 == kind }
        recentEnhanced.insert(kind, at: 0)
        if recentEnhanced.count > 12 { recentEnhanced.removeLast(recentEnhanced.count - 12) }
        let level = localLevels[kind] ?? 0
        var rng = SeededRNG(seed: enhanceSeed)
        enhanceSeed = enhanceSeed &* 6_364_136_223_846_793_005 &+ 1
        let outcome = EnhanceEngine.roll(level: level, using: &rng)
        enhanceTask?.cancel()
        enhanceTask = Task { @MainActor in
            // 차지 (기대)
            enhancePhase = .charging
            withAnimation(.easeInOut(duration: 0.2).repeatCount(4, autoreverses: true)) { enhancePulse = true }
            withAnimation(.easeIn(duration: 0.6)) { enhanceBright = 0.18 }
            try? await Task.sleep(for: .milliseconds(680))
            if Task.isCancelled { return }
            enhancePulse = false; enhanceBright = 0
            enhancePhase = .result(outcome)
            // 결과 반응
            switch outcome {
            case .success:
                withAnimation(.easeOut(duration: 0.12)) { enhanceBright = 0.9 }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.45)) { enhancePop = 1.3 }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(.easeOut(duration: 0.35)) { enhanceBright = 0 }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { enhancePop = 1 }
            case .stay:
                await shake(amp: 3)
            case .downgrade:
                await shake(amp: 6)
            case .destroy:
                await shake(amp: 11)   // 그레이스케일은 phase == .result(.destroy) 동안 유지
            }
            try? await Task.sleep(for: .milliseconds(outcome == .destroy ? 400 : 250))
            if Task.isCancelled { return }
            let newLevel = EnhanceEngine.apply(level: level, outcome: outcome)
            withAnimation { localLevels[kind] = newLevel }
            appendEnhance(level: level, newLevel: newLevel, outcome: outcome)
            try? await Task.sleep(for: .milliseconds(500))
            enhancePhase = .idle; enhancePop = 1; enhanceShake = 0; enhanceBright = 0
        }
    }

    private func shake(amp: CGFloat) async {
        for v in [amp, -amp, amp * 0.7, -amp * 0.7, amp * 0.4, -amp * 0.3, 0] {
            withAnimation(.easeInOut(duration: 0.05)) { enhanceShake = v }
            try? await Task.sleep(for: .milliseconds(52))
            if Task.isCancelled { return }
        }
    }

    private func appendEnhance(level: Int, newLevel: Int, outcome: EnhanceOutcome) {
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
        Text(t.displayName).font(.system(size: 8, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(typeColor(t).opacity(0.2))).foregroundStyle(typeColor(t))
    }
    private func typeDot(_ t: BattleType) -> some View {
        Circle().fill(typeColor(t)).frame(width: 6, height: 6)
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
