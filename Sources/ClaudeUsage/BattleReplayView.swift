import SwiftUI

// 배틀 재생 공유 컴포넌트 — 아레나(연습·랭크전)와 도장 관장 배틀이 **동일 코드**로 사용한다.
// `BattleResult`(확정 로그) + 양 팀 스냅샷을 받아 ①상단 파티 아이콘 ②공유 스테이지(펫·HP박스·lunge/flash·
// 궁극기 컷인/VFX·대사) ③현재 액션 라인 ④컨트롤(속도/건너뛰기/다시재생/전체로그)을 자체 재생한다.
// 재생 진행·애니메이션 상태는 전부 내부 @State — 호스트는 result/teams만 주입하고, 결과 배너 아래에
// 붙일 추가 콘텐츠(랭크전 카드·관장 보상 카드 등)만 `resultExtra`로 넘긴다.
//
// 이 파일은 ArenaView.swift에서 배틀 관전 로직을 추출한 것 — 연출 규칙(포켓몬 골드 UI 관례 참고,
// docs/research/pokemon-gold-battle-ui.md)은 그대로 보존한다.
@MainActor
struct BattleReplayView<Extra: View>: View {
    let aSnaps: [BattlePetSnapshot]
    let bSnaps: [BattlePetSnapshot]
    let result: BattleResult
    let serverMaxHpA: [PetKind: Int]?
    let serverMaxHpB: [PetKind: Int]?
    let resultExtra: () -> Extra

    init(aSnaps: [BattlePetSnapshot], bSnaps: [BattlePetSnapshot], result: BattleResult,
         serverMaxHpA: [PetKind: Int]? = nil, serverMaxHpB: [PetKind: Int]? = nil,
         @ViewBuilder resultExtra: @escaping () -> Extra) {
        self.aSnaps = aSnaps
        self.bSnaps = bSnaps
        self.result = result
        self.serverMaxHpA = serverMaxHpA
        self.serverMaxHpB = serverMaxHpB
        self.resultExtra = resultExtra
    }

    // 재생 상태
    @State private var playbackStep = 0
    @State private var playbackTask: Task<Void, Never>?
    @State private var showFullLog = false
    @State private var speed: Double = 1                  // 재생 속도 1×/2×/4×
    // 배틀 연출 상태
    @State private var lungeSide: BattleSide?
    @State private var lungeAmount: CGFloat = 0
    @State private var flashSide: BattleSide?
    @State private var flashBrightness: Double = 0
    // 궁극기 연출 — 컷인 배너(스킬명) + 스테이지 셰이크.
    @State private var ultBannerText: String?
    @State private var ultBannerColor: Color = .yellow
    @State private var stageShake: CGFloat = 0
    // 궁극기 도트 VFX (BenHickling CC0, Resources/vfx-benhickling).
    @State private var ultBurst: (side: BattleSide, at: Date)?
    @State private var ultImpact: (side: BattleSide, at: Date)?
    // 대사 말풍선
    @State private var speechText: String?
    @State private var speechSide: BattleSide?
    @State private var defenderText: String?
    @State private var defenderSide: BattleSide?

    var body: some View {
        battleArena
            .onAppear { startPlayback(total: result.log.count) }
            .onChange(of: result) { _, r in startPlayback(total: r.log.count) }
            .onDisappear { stopPlayback() }
    }

    // MARK: 배틀 관전 (공유 스테이지 + 파티 아이콘 + lunge/flash)

    private var battleArena: some View {
        let log = result.log
        let done = playbackStep >= log.count
        let dicts = battleDicts(step: playbackStep)
        let hp = dicts.hp
        let charge = dicts.charge
        let fx = dicts.fx
        let current: BattleEvent? = (playbackStep > 0 && playbackStep <= log.count) ? log[playbackStep - 1] : nil
        // 배틀 표시는 시뮬에 쓰인 스냅샷 기준(편성 편집과 무관하게 고정).
        let aKinds = aSnaps.map(\.kind), bKinds = bSnaps.map(\.kind)
        let aActive = aKinds.first { (hp.a[$0] ?? 0) > 0 }
        let bActive = bKinds.first { (hp.b[$0] ?? 0) > 0 }
        return VStack(spacing: 8) {
            partyRow(hp: hp, aKinds: aKinds, bKinds: bKinds, aActive: aActive, bActive: bActive)
            battleStage(hp: hp, charge: charge, fx: fx, aActive: aActive, bActive: bActive, current: current)
                .overlay { if done { resultBanner(result.winner) } }
            currentActionLine(current)
            controls(total: log.count)
            if showFullLog { fullLog(log) }
            if done { resultExtra() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.secondary.opacity(0.06)))
    }

    private func partyRow(hp: (a: [PetKind: Int], b: [PetKind: Int]), aKinds: [PetKind], bKinds: [PetKind], aActive: PetKind?, bActive: PetKind?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(aKinds, id: \.self) { partyIcon($0, fainted: (hp.a[$0] ?? 0) <= 0, active: $0 == aActive) }
            }
            Spacer()
            Text("VS").font(.system(size: 10, weight: .heavy)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 3) {
                ForEach(bKinds, id: \.self) { partyIcon($0, fainted: (hp.b[$0] ?? 0) <= 0, active: $0 == bActive) }
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

    private func battleStage(hp: (a: [PetKind: Int], b: [PetKind: Int]), charge: (a: [PetKind: Int], b: [PetKind: Int]), fx: (a: [PetKind: [ActiveFx]], b: [PetKind: [ActiveFx]]), aActive: PetKind?, bActive: PetKind?, current: BattleEvent?) -> some View {
        // 스킵 연출 — 현재 스텝의 액션이 스킵(공격 없음)이면 그 라운드의 skip 이벤트를 잡아 "💤" 표시.
        let skipEvent = currentSkip()
        return GeometryReader { geo in
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
                // 스킵(Control) 연출 — 그 펫 머리 위 💤 말풍선
                if let sk = skipEvent {
                    let x = bubbleX(sk.side, w), y = petY(sk.side, h) - 40
                    Text("💤 \(EffectCatalog.displayName(sk.effectId ?? "") ?? "행동불가")")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.purple.opacity(0.9)))
                        .foregroundStyle(.white)
                        .position(x: x, y: y).transition(.scale.combined(with: .opacity))
                }
                // 대사 말풍선 (공격자 / 방어자 반응)
                if let t = speechText, let s = speechSide {
                    speechBubble(t, faint: false).position(x: bubbleX(s, w), y: bubbleY(s, h))
                }
                if let t = defenderText, let s = defenderSide {
                    speechBubble(t, faint: true).position(x: bubbleX(s, w), y: bubbleY(s, h))
                }
                // 궁극기 도트 VFX — 발동 버스트(공격자 위 링) → 피격 폭발(방어자 위). 펫 레이어 위.
                if let v = ultBurst {
                    vfxSprite("vfx_ring", start: v.at, size: 96).position(x: bubbleX(v.side, w), y: petY(v.side, h))
                }
                if let v = ultImpact {
                    vfxSprite("vfx_explosion", start: v.at, size: 88).position(x: bubbleX(v.side, w), y: petY(v.side, h))
                }
                // 궁극기 컷인 — 발동 순간 스테이지 중앙 스킬명 배너 (히트스톱 동안 노출)
                if let t = ultBannerText {
                    ultCutIn(t).position(x: w * 0.5, y: h * 0.5)
                }
            }
            .modifier(ShakeEffect(animatableData: stageShake))   // 궁극기 임팩트 셰이크(평시 정수값 = 무변위)
            .overlay(alignment: .topLeading) {
                if let k = bActive {
                    hpBox(k, cur: hp.b[k] ?? 0, showNumbers: false, snaps: bSnaps, server: serverMaxHpB,
                          charge: charge.b[k] ?? 0, fx: fx.b[k] ?? []).padding(6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let k = aActive {
                    hpBox(k, cur: hp.a[k] ?? 0, showNumbers: true, snaps: aSnaps, server: serverMaxHpA,
                          charge: charge.a[k] ?? 0, fx: fx.a[k] ?? []).padding(6)
                }
            }
        }
        .frame(height: 176)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md))
    }

    /// 궁극기 컷인 배너 — 타입색 캡슐 + 스킬명. transition의 큰 스케일이 "펀치 인" 임팩트를 만든다.
    private func ultCutIn(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.6)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Capsule().fill(ultBannerColor.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
            .shadow(color: ultBannerColor.opacity(0.8), radius: 10)
            .rotationEffect(.degrees(-2))
            .frame(maxWidth: 280)
            .transition(.scale(scale: 1.9).combined(with: .opacity))
            .allowsHitTesting(false)
    }

    private func bubbleX(_ s: BattleSide, _ w: CGFloat) -> CGFloat { s == .a ? w * 0.27 : w * 0.73 }
    private func bubbleY(_ s: BattleSide, _ h: CGFloat) -> CGFloat { (s == .a ? h * 0.68 : h * 0.36) - 46 }
    private func petY(_ s: BattleSide, _ h: CGFloat) -> CGFloat { s == .a ? h * 0.68 : h * 0.36 }

    /// 도트 VFX 스프라이트 1회 재생 — start부터 32fps(재생 배속 연동)로 프레임 진행, 끝나면 빈 뷰.
    private func vfxSprite(_ name: String, start: Date, size: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
            let frames = PetSprite.frames(named: name, cellSize: (100, 100))
            let idx = Int(ctx.date.timeIntervalSince(start) * 32 * max(1, speed))
            if idx >= 0, idx < frames.count {
                Image(nsImage: frames[idx]).resizable().interpolation(.none)
                    .frame(width: size, height: size)
            }
        }
        .allowsHitTesting(false)
    }

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

    private func hpBox(_ kind: PetKind, cur: Int, showNumbers: Bool, snaps: [BattlePetSnapshot], server: [PetKind: Int]?, charge: Int = 0, fx: [ActiveFx] = []) -> some View {
        let maxv = maxHP(kind, in: snaps, server: server)
        let frac = maxv > 0 ? Double(max(0, cur)) / Double(maxv) : 0
        // 궁극기 게이지 — 레인보우(variant4) 펫만. 로그 재생으로 접은 charge를 ultChargeCost 대비로 표시.
        let rainbow = (snaps.first(where: { $0.kind == kind })?.variant ?? 0) >= BattleEngine.rainbowVariant
        let chargeFrac = min(1.0, Double(charge) / Double(BattleEngine.ultChargeCost))
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
            if rainbow {
                HStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.black.opacity(0.15))
                            Capsule()
                                .fill(LinearGradient(colors: chargeFrac >= 1 ? [.orange, .yellow] : [.purple.opacity(0.7), .orange.opacity(0.8)],
                                                     startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(0, g.size.width * chargeFrac))
                                .animation(.easeOut(duration: 0.3), value: charge)
                        }
                    }.frame(width: 84, height: 3)
                    Text("⚡️").font(.system(size: 7)).opacity(chargeFrac >= 1 ? 1 : 0.25)
                        .animation(.easeOut(duration: 0.3), value: chargeFrac >= 1)
                }
            }
            if showNumbers {
                Text("\(max(0, cur))/\(maxv)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
            }
            if !fx.isEmpty {
                HStack(spacing: 2) {
                    ForEach(fx.prefix(4), id: \.id) { effectChip($0) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
    }

    /// 상태 효과 칩 — 이모지 + 남은 턴. 색은 디버프(빨강)/버프(초록). 툴팁은 효과명.
    private func effectChip(_ a: ActiveFx) -> some View {
        let def = EffectCatalog.effect(a.id)
        let debuff = def.map { BattleEngine.isDebuff($0) } ?? false
        let color: Color = debuff ? .red : .green
        return HStack(spacing: 1) {
            Text(effectIcon(a.id)).font(.system(size: 8))
            if a.remaining > 1 { Text("\(a.remaining)").font(.system(size: 7, weight: .bold, design: .monospaced)) }
        }
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.20)))
        .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 0.5))
        .help(EffectCatalog.displayName(a.id) ?? a.id)
    }

    /// 효과 id → 이모지. kind 기반 폴백으로 미래 효과도 안전하게 커버.
    private func effectIcon(_ id: String) -> String {
        switch id {
        case "mem_leak", "infinite_loop": return "🔥"       // DoT
        case "deadlock", "outage_stun", "rate_limited": return "💤"   // control
        case "tech_debt", "legacy", "bsod_lag": return "⬇️"  // statMod 디버프
        case "optimization", "firewall", "caching": return "⬆️"      // statMod 버프
        case "load_balancer": return "🛡️"                   // shield
        case "autoscaling": return "💚"                      // regen
        default:
            guard let def = EffectCatalog.effect(id) else { return "✨" }
            switch def.kind {
            case .dot: return "🔥"; case .regen: return "💚"; case .shield: return "🛡️"
            case .controlFixed, .controlChance: return "💤"
            case .statMod: return def.magnitude < 1 ? "⬇️" : "⬆️"
            case .cleanse: return "🧹"
            }
        }
    }

    /// 스킵 연출 — 스킵 라운드는 공격 로그가 없어 자체 재생 스텝이 없다. 대신 "직전 공격 스텝의 라운드와
    /// 현재 스텝의 라운드 사이"에 낀 스킵 이벤트를 현재 스텝에 얹어 보여준다(그 사이에 실제 발생했으므로).
    private func currentSkip() -> EffectEvent? {
        let log = result.log
        guard playbackStep > 0, playbackStep <= log.count else { return nil }
        let curRound = log[playbackStep - 1].round
        let prevRound = playbackStep >= 2 ? log[playbackStep - 2].round : 0
        return (result.effectEvents ?? []).first { $0.kind == "skip" && $0.at > prevRound && $0.at < curRound }
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
            // 재생 속도 — 진행 중 변경 시 남은 로그를 새 속도로 이어 재생.
            Picker("", selection: $speed) {
                Text("1×").tag(1.0); Text("2×").tag(2.0); Text("4×").tag(4.0)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 108)
            .onChange(of: speed) { _, _ in
                if playbackStep < total { resumePlayback(from: playbackStep, total: total) }
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
        if SkillCatalog.isUltimate(e.move) { tags.append("⚡️ 궁극기!") }
        if e.crit == true { tags.append("🌈 크리!") }
        if e.effectiveness > 1 { tags.append("타입▲") } else if e.effectiveness < 1 { tags.append("타입▼") }
        if e.collectionMult > 1.01 { tags.append("상성▲") } else if e.collectionMult < 0.99 { tags.append("상성▼") }
        if e.parried { tags.append("🛡️ 가드") }
        if e.defenderFainted { tags.append("💀 KO") }
        return tags.joined(separator: " ")
    }

    @ViewBuilder
    private func currentActionLine(_ e: BattleEvent?) -> some View {
        if let e {
            let move = SkillCatalog.displayName(id: e.move)
                ?? BattleLines.moveName(collection: e.attackerKind.collection, signature: e.move == "signature")
            VStack(spacing: 2) {
                Text("\(PetMetaStore.shared.displayName(for: e.attackerKind)) «\(move)» ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind))  −\(e.damage)  \(tagString(e))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                if e.effectiveness > 1.0 {
                    Text("효과가 굉장했다!").font(.system(size: 11, weight: .heavy)).foregroundStyle(.green)
                } else if e.effectiveness < 1.0 {
                    Text("효과가 별로였다…").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                if let q = e.quip {
                    Text("«\(q)»").font(.system(size: 10)).italic().foregroundStyle(.tint)
                }
                if let fxLine = effectLine(for: e.round) {
                    Text(fxLine).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity).id(playbackStep).transition(.opacity)
        } else {
            Text("전투 시작…").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// 이 액션에 연관된 효과 이벤트(E2) 한 줄 요약 — 부여/자힐/광역/지속피해.
    private func effectLine(for round: Int) -> String? {
        let fx = (result.effectEvents ?? []).filter { $0.at == round }
        guard !fx.isEmpty else { return nil }
        var parts: [String] = []
        for e in fx where e.kind == "grant" {
            let name = e.effectId.flatMap { EffectCatalog.displayName($0) } ?? "효과"
            parts.append("🧪 \(name) 부여")
        }
        let healSum = fx.filter { $0.kind == "heal" || ($0.kind == "tick" && ($0.hpDelta ?? 0) > 0) }
            .compactMap(\.hpDelta).reduce(0, +)
        if healSum > 0 { parts.append("💚 +\(healSum)") }
        let dotSum = fx.filter { $0.kind == "tick" && ($0.hpDelta ?? 0) < 0 }.compactMap(\.hpDelta).reduce(0, +)
        if dotSum < 0 { parts.append("🔥 지속피해 \(dotSum)") }
        let splashes = fx.filter { $0.kind == "splash" }
        if !splashes.isEmpty {
            let sum = splashes.compactMap(\.hpDelta).reduce(0, +)
            parts.append("🌊 광역 \(splashes.count)명 \(sum)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func resultBanner(_ w: BattleSide?) -> some View {
        let win = w == .a
        let title = w == .a ? "승리!" : (w == .b ? "패배…" : "무승부")
        let icon = w == .a ? "🏆" : (w == .b ? "💀" : "🤝")
        let color: Color = w == .a ? .green : (w == .b ? .red : .secondary)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in   // 30fps로 제한(방치 시 상시 리렌더 완화)
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

    /// 전체 로그 한 줄 — 공격 이벤트 또는 효과 이벤트(스킵/틱). id는 렌더 순서용.
    private struct LogRow: Identifiable { let id: Int; let text: String; let color: Color }

    /// 공격 로그 + 효과 이벤트(스킵/틱)를 라운드 순서로 병합.
    private func fullLogRows(_ log: [BattleEvent]) -> [LogRow] {
        var rows: [(round: Int, order: Int, text: String, color: Color)] = []
        for (i, e) in log.enumerated() {
            let side = e.attacker == .a ? "A" : "B"
            let move = SkillCatalog.displayName(id: e.move)
                ?? BattleLines.moveName(collection: e.attackerKind.collection, signature: e.move == "signature")
            let quip = e.quip != nil ? " «\(e.quip!)»" : ""
            let ult = SkillCatalog.isUltimate(e.move) ? "⚡️" : ""
            rows.append((e.round, 1, "R\(e.round) \(side) \(PetMetaStore.shared.displayName(for: e.attackerKind)) «\(ult)\(move)» ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind)) −\(e.damage)\(quip)",
                         e.attacker == .a ? .primary : .secondary))
            _ = i
        }
        for e in (result.effectEvents ?? []) {
            let name = e.effectId.flatMap { EffectCatalog.displayName($0) } ?? "효과"
            let who = PetMetaStore.shared.displayName(for: e.petKind)
            if e.kind == "skip" {
                rows.append((e.at, 0, "R\(e.at) 💤 \(who) — \(name)로 행동불가", .purple))
            } else if e.kind == "tick", let d = e.hpDelta {
                let icon = d < 0 ? "🔥" : "💚"
                rows.append((e.at, 0, "R\(e.at) \(icon) \(who) \(name) \(d > 0 ? "+" : "")\(d)", d < 0 ? .orange : .green))
            }
        }
        rows.sort { $0.round != $1.round ? $0.round < $1.round : $0.order < $1.order }
        return rows.enumerated().map { LogRow(id: $0.offset, text: $0.element.text, color: $0.element.color) }
    }

    private func fullLog(_ log: [BattleEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(fullLogRows(log)) { row in
                    Text(row.text).font(.system(size: 9, design: .monospaced)).foregroundStyle(row.color)
                }
            }
        }
        .frame(height: 130).padding(6)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: 배틀 상태 재구성 + 재생

    /// HP 바 상한 — 서버가 실링(server[kind])을 줬으면 그걸 우선 사용(엔진 버전 스큐에도 desync 방지),
    /// 없으면 로컬 `BattleEngine.finalStats`로 폴백(엔진 makeCombatants 동일 소스).
    private func maxHP(_ kind: PetKind, in snaps: [BattlePetSnapshot], server: [PetKind: Int]?) -> Int {
        if let v = server?[kind] { return v }
        guard let m = snaps.first(where: { $0.kind == kind }) else { return 1 }
        return BattleEngine.finalStats(for: m, in: BattleTeam(snaps)).hp
    }

    /// 재생 시점 한 펫의 활성 효과 한 칸(표시용).
    struct ActiveFx: Equatable { let id: String; let remaining: Int }
    typealias BattleState = (hp: (a: [PetKind: Int], b: [PetKind: Int]),
                             charge: (a: [PetKind: Int], b: [PetKind: Int]),
                             fx: (a: [PetKind: [ActiveFx]], b: [PetKind: [ActiveFx]]))

    /// 배틀 상태 재구성(HP + 궁극기 게이지 + 활성 효과) — 공격 로그와 효과 이벤트를 엔진 순서로 접는다.
    private func battleDicts(step: Int) -> BattleState {
        // 유니크 kind 전제지만 방어적으로 uniquing(미래에 동일 kind 편성 허용돼도 크래시 없게).
        var hpA = Dictionary(aSnaps.map { ($0.kind, maxHP($0.kind, in: aSnaps, server: serverMaxHpA)) }, uniquingKeysWith: { x, _ in x })
        var hpB = Dictionary(bSnaps.map { ($0.kind, maxHP($0.kind, in: bSnaps, server: serverMaxHpB)) }, uniquingKeysWith: { x, _ in x })
        var ca: [PetKind: Int] = [:], cb: [PetKind: Int] = [:]
        var fa: [PetKind: [ActiveFx]] = [:], fb: [PetKind: [ActiveFx]] = [:]
        let log = Array(result.log.prefix(step))
        guard let curRound = log.last?.round else { return ((hpA, hpB), (ca, cb), (fa, fb)) }

        var fxByAt: [Int: [EffectEvent]] = [:]
        for e in (result.effectEvents ?? []) where e.at <= curRound { fxByAt[e.at, default: []].append(e) }
        var atkByRound: [Int: BattleEvent] = [:]
        for e in log { atkByRound[e.round] = e }

        func applyFx(_ e: EffectEvent) {
            if let d = e.hpDelta {
                if e.side == .a { hpA[e.petKind] = max(0, (hpA[e.petKind] ?? 0) + d) }
                else { hpB[e.petKind] = max(0, (hpB[e.petKind] ?? 0) + d) }
            }
            if e.kind == "splash" {   // 스플래시 피격 충전 + 기절 시 승계(엔진 규칙 미러)
                if e.side == .a {
                    ca[e.petKind] = (ca[e.petKind] ?? 0) + 1
                    if e.fainted == true, let next = aSnaps.first(where: { (hpA[$0.kind] ?? 0) > 0 })?.kind {
                        ca[next] = (ca[next] ?? 0) + (ca[e.petKind] ?? 0)
                    }
                } else {
                    cb[e.petKind] = (cb[e.petKind] ?? 0) + 1
                    if e.fainted == true, let next = bSnaps.first(where: { (hpB[$0.kind] ?? 0) > 0 })?.kind {
                        cb[next] = (cb[next] ?? 0) + (cb[e.petKind] ?? 0)
                    }
                }
            }
            // 효과 부여 — grant 이벤트만(heal/splash는 지속 효과 아님). cleanse(hot_reload)는 디버프 제거.
            if e.kind == "grant", let id = e.effectId, let def = EffectCatalog.effect(id) {
                if def.kind == .cleanse {
                    if e.side == .a { fa[e.petKind]?.removeAll { EffectCatalog.effect($0.id).map { BattleEngine.isDebuff($0) } ?? false } }
                    else { fb[e.petKind]?.removeAll { EffectCatalog.effect($0.id).map { BattleEngine.isDebuff($0) } ?? false } }
                } else {
                    let fx = ActiveFx(id: id, remaining: def.duration)
                    if e.side == .a { setFx(&fa, e.petKind, fx) } else { setFx(&fb, e.petKind, fx) }
                }
            }
        }
        func setFx(_ dict: inout [PetKind: [ActiveFx]], _ k: PetKind, _ fx: ActiveFx) {
            var arr = dict[k] ?? []
            if let i = arr.firstIndex(where: { $0.id == fx.id }) { arr[i] = fx } else { arr.append(fx) }   // refresh
            dict[k] = arr
        }
        func tickActor(_ side: BattleSide, _ k: PetKind) {   // 자기 턴 시작 — remaining-- 후 만료 제거
            if side == .a { fa[k] = (fa[k] ?? []).map { ActiveFx(id: $0.id, remaining: $0.remaining - 1) }.filter { $0.remaining > 0 } }
            else { fb[k] = (fb[k] ?? []).map { ActiveFx(id: $0.id, remaining: $0.remaining - 1) }.filter { $0.remaining > 0 } }
        }
        func applyAttack(_ e: BattleEvent) {
            let ult = SkillCatalog.isUltimate(e.move)
            if e.attacker == .a {
                ca[e.attackerKind] = ult ? 0 : (ca[e.attackerKind] ?? 0) + 1
                hpB[e.defenderKind] = max(0, (hpB[e.defenderKind] ?? 0) - e.damage)
                cb[e.defenderKind] = (cb[e.defenderKind] ?? 0) + 1
                if e.defenderFainted, let next = bSnaps.first(where: { (hpB[$0.kind] ?? 0) > 0 })?.kind {
                    cb[next] = (cb[next] ?? 0) + (cb[e.defenderKind] ?? 0)
                }
            } else {
                cb[e.attackerKind] = ult ? 0 : (cb[e.attackerKind] ?? 0) + 1
                hpA[e.defenderKind] = max(0, (hpA[e.defenderKind] ?? 0) - e.damage)
                ca[e.defenderKind] = (ca[e.defenderKind] ?? 0) + 1
                if e.defenderFainted, let next = aSnaps.first(where: { (hpA[$0.kind] ?? 0) > 0 })?.kind {
                    ca[next] = (ca[next] ?? 0) + (ca[e.defenderKind] ?? 0)
                }
            }
        }
        for r in 1...curRound {
            let fx = fxByAt[r] ?? []
            // 자기 턴 주체(엔진 tick 대상) — 공격자 > 스킵 > 틱(DoT 자멸) 순으로 그 라운드 행동 시도자.
            if let a = atkByRound[r] { tickActor(a.attacker, a.attackerKind) }
            else if let sk = fx.first(where: { $0.kind == "skip" }) { tickActor(sk.side, sk.petKind) }
            else if let tk = fx.first(where: { $0.kind == "tick" }) { tickActor(tk.side, tk.petKind) }
            for e in fx where e.kind == "tick" || e.kind == "skip" { applyFx(e) }
            if let a = atkByRound[r] { applyAttack(a) }
            for e in fx where e.kind != "tick" && e.kind != "skip" { applyFx(e) }
        }
        return ((hpA, hpB), (ca, cb), (fa, fb))
    }

    private func startPlayback(total: Int, from start: Int = 0) {
        playbackTask?.cancel()
        playbackStep = start
        if start == 0 { lungeAmount = 0; flashBrightness = 0 }
        let sp = max(1, speed)
        func ms(_ base: Double) -> Duration { .milliseconds(Int(base / sp)) }
        playbackTask = Task { @MainActor in
            for i in (start + 1)...max(1, total) {
                try? await Task.sleep(for: ms(360))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.15)) { playbackStep = i }
                let log = result.log
                guard i - 1 < log.count else { continue }
                let e = log[i - 1]
                let superEff = e.effectiveness > 1.0, weakEff = e.effectiveness < 1.0
                let isUlt = SkillCatalog.isUltimate(e.move)
                ultBurst = nil; ultImpact = nil   // 직전 이벤트 VFX 정리(재생 완료분 — TimelineView idle 비용 제거)
                if isUlt {
                    // 궁극기 컷인 — 스킬명 배너 펀치 인 + 발동 버스트(링) + 셰이크 + 히트스톱(배너 감상 시간).
                    ultBannerColor = typeColor(e.attackerKind.battleType)
                    withAnimation(.spring(duration: 0.25, bounce: 0.4)) {
                        ultBannerText = "⚡️ \(SkillCatalog.displayName(id: e.move) ?? e.move)"
                    }
                    ultBurst = (e.attacker, Date())
                    withAnimation(.linear(duration: 0.5)) { stageShake += 1 }
                    try? await Task.sleep(for: ms(450))
                    if Task.isCancelled { return }
                }
                lungeSide = e.attacker
                withAnimation(.easeOut(duration: 0.1)) { lungeAmount = isUlt ? 1.7 : (superEff ? 1.3 : 1) }   // 궁극기 > 효과 굉장 > 평타 순으로 파고듦
                let defSide: BattleSide = (e.attacker == .a) ? .b : .a
                if isUlt { ultImpact = (defSide, Date()) }   // 피격 폭발 — 히트 순간 방어자 위
                flashSide = defSide
                flashBrightness = isUlt ? 1.5 : (superEff ? 1.25 : (weakEff ? 0.45 : 0.9))     // 상성별 피격 섬광 강약
                withAnimation(.easeOut(duration: 0.35)) { flashBrightness = 0 }
                // 대사: 공격자 ~30% + 방어자 반응(패링/리타이어)
                speechSide = e.attacker
                speechText = Int.random(in: 0..<10) < 3 ? BattleLines.attackLine() : nil
                if e.parried { defenderSide = defSide; defenderText = BattleLines.parryLine() }
                else if e.defenderFainted { defenderSide = defSide; defenderText = BattleLines.faintLine() }
                else { defenderText = nil; defenderSide = nil }
                try? await Task.sleep(for: ms(130))
                if Task.isCancelled { return }
                withAnimation(.easeIn(duration: 0.12)) { lungeAmount = 0 }
                if isUlt {
                    try? await Task.sleep(for: ms(250))   // 임팩트 여운 후 배너 해제
                    if Task.isCancelled { return }
                    withAnimation(.easeOut(duration: 0.2)) { ultBannerText = nil }
                }
                if e.defenderFainted { try? await Task.sleep(for: ms(300)) }   // KO 순간 잠깐 멈춤(강조)
                if Task.isCancelled { return }
            }
            // 자연 종료 — 잔여 VFX 상태 정리(안 하면 TimelineView가 빈 뷰를 계속 tick).
            ultBurst = nil; ultImpact = nil
        }
    }
    private func skipToEnd() { stopPlayback(); withAnimation { playbackStep = result.log.count } }
    private func replay() { stopPlayback(); startPlayback(total: result.log.count) }
    /// 속도 변경 시 현재 스텝부터 새 속도로 이어 재생(리셋하지 않음).
    private func resumePlayback(from step: Int, total: Int) {
        playbackTask?.cancel()
        guard step < total else { return }
        startPlayback(total: total, from: step)
    }
    private func stopPlayback() {
        playbackTask?.cancel(); playbackTask = nil
        lungeAmount = 0; flashBrightness = 0
        speechText = nil; speechSide = nil; defenderText = nil; defenderSide = nil
        ultBannerText = nil; ultBurst = nil; ultImpact = nil
    }

    // MARK: 공용 (아레나와 동일 — 렌더 헬퍼)

    @ViewBuilder private func thumb(_ kind: PetKind, h: CGFloat) -> some View {
        if let img = PetSprite.frames(for: kind, action: .walk).first ?? PetSprite.frames(for: kind, action: .sit).first {
            Image(nsImage: img).resizable().interpolation(.none).aspectRatio(contentMode: .fit).frame(height: h)
        } else {
            Image(systemName: "pawprint").font(.system(size: h * 0.7)).foregroundStyle(.secondary)
        }
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

// 편의 init — resultExtra 없는 호출(도장 관장 배틀 등)용.
extension BattleReplayView where Extra == EmptyView {
    init(aSnaps: [BattlePetSnapshot], bSnaps: [BattlePetSnapshot], result: BattleResult,
         serverMaxHpA: [PetKind: Int]? = nil, serverMaxHpB: [PetKind: Int]? = nil) {
        self.init(aSnaps: aSnaps, bSnaps: bSnaps, result: result,
                  serverMaxHpA: serverMaxHpA, serverMaxHpB: serverMaxHpB,
                  resultExtra: { EmptyView() })
    }
}

/// 궁극기 임팩트 셰이크 — animatableData(트리거 카운터)가 +1 진행하는 동안 sin 6π = 3회 좌우 진동.
/// 정지 상태(정수값)에선 sin(k·6π)=0이라 변위가 없다. withAnimation으로 stageShake += 1 하면 발동.
private struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 5
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 6), y: 0))
    }
}
