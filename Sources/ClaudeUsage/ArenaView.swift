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
// 강화소는 서버(pet-enhance) authoritative — VP 실차감·레벨 영속. 레이팅·랭크전·시즌 보상은 후속(T3+).
// 설계: docs/plans/pet-battle.md §2-2 / §2-9 / §5-1.
@MainActor
struct ArenaView: View {
    @ObservedObject private var settings = Settings.shared
    @State private var mode: Mode = .practice
    @State private var showTypeHelp = false        // 6타입 상성 도움말 시트
    @State private var showChallengeConfirm = false // 랭크전 도전 확인 alert(일일 판수 소모)

    // 연습전
    @State private var teamKinds: [PetKind] = []          // 편성 가능한 내 팀(전투 전 편집)
    @State private var aSnaps: [BattlePetSnapshot] = []   // 실제 시뮬에 쓰인 내 팀 스냅샷(강화 반영)
    @State private var bSnaps: [BattlePetSnapshot] = []   // 상대 팀 스냅샷(매치메이킹 결과)
    // 서버가 계산해 준 HP 실링(kind→maxHP). 있으면 HP 바 상한으로 우선 사용 → 엔진 버전 스큐에도 desync 없음.
    // nil(로컬 대전·구서버·구 로그)이면 로컬 finalStats로 폴백. slot→kind 매핑(유니크 kind 전제, 방어적 uniquing).
    @State private var serverMaxHpA: [PetKind: Int]?
    @State private var serverMaxHpB: [PetKind: Int]?
    @State private var result: BattleResult?
    @State private var playbackStep = 0
    @State private var playbackTask: Task<Void, Never>?
    @State private var showFullLog = false
    @State private var speed: Double = 1                  // 재생 속도 1×/2×/4×
    @State private var editingSlot: SlotSel?              // 팀 슬롯 편성 팝오버
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

    // 강화소 — 서버 authoritative(pet-enhance). 레벨·가용 VP는 서버 SSOT, 클라는 연출·표시만.
    @State private var enhanceKind: PetKind?
    @State private var serverLevels: [PetKind: Int] = [:]   // 서버에서 받은 강화 레벨(SSOT 미러)
    @State private var availableVp: Int?                    // 서버 가용 VP (nil = 미로딩)
    @State private var safeMode = false                     // 안전 강화 모드(파괴 없음 + soft-pity)
    // 완화 아이템(보호권·확정권) + 강화 이벤트
    @State private var protectCount = 0
    @State private var guaranteeCount = 0
    @State private var protectPrice = 0
    @State private var guaranteePrice = 0
    @State private var eventLabel: String?                  // nil = 이벤트 없음
    @State private var eventDiscount: Double = 0
    @State private var useProtect = false
    @State private var useGuarantee = false
    @State private var buyBusy = false
    @State private var enhanceStateError: String?           // state/enhance 실패 메시지
    @State private var enhanceHistory: [EnhanceLine] = []
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

    // 랭크전 (서버 authoritative)
    @State private var pvpRating: Int?
    @State private var pvpWins = 0
    @State private var pvpLosses = 0
    @State private var pvpDailyUsed = 0
    @State private var pvpDailyLimit = 10
    @State private var rankedError: String?
    @State private var rankedResult: RankedResult?     // 마지막 랭크전 결과(배틀 재생 아래 카드)
    @State private var rankedBusy = false              // 등록+매칭+시뮬 요청 진행 중
    @State private var rankedTask: Task<Void, Never>?
    @State private var leaderboard: [RankingAPI.PvpLeaderboardEntry] = []
    @State private var history: [RankingAPI.PvpMatch] = []
    @State private var lastSeason: RankingAPI.PvpLastSeason?     // 지난 시즌 시상대
    // 시너지 아이콘 호버(툴팁 팝오버)
    @State private var collTipShown = false
    @State private var typeTipShown = false
    @State private var noneTipShown = false

    struct RankedResult { let winner: String; let ratingDelta: Int; let coinReward: Int; let opponentNickname: String }

    enum Mode: String, CaseIterable, Identifiable {
        case practice = "연습전", ranked = "랭크전", enhance = "강화소"
        var id: String { rawValue }
    }
    enum EnhancePhase: Equatable { case idle, charging, result(EnhanceOutcome) }
    struct EnhanceLine: Identifiable { let id = UUID(); let text: String; let color: Color }
    enum TargetSort: String, CaseIterable, Identifiable {
        case recent = "최근", dex = "도감", rarity = "희귀도", name = "이름"
        var id: String { rawValue }
    }
    /// 팀 슬롯 편성 팝오버 대상 (id = 슬롯 인덱스; teamKinds.count면 새 슬롯 추가).
    struct SlotSel: Identifiable { let id: Int }

    private var owned: [PetKind] { PetKind.allCases.filter { settings.ownedPets[$0] != nil } }

    // 배틀에 반영할 이로치 단계 — 보유한 최고 해금 variant(0=기본 … 4=레인보우). 미보유 시 0.
    private func battleVariant(_ kind: PetKind) -> Int {
        settings.ownedPets[kind]?.unlockedVariants.max() ?? 0
    }

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
                    .onChange(of: mode) { _, _ in stopPlayback(); result = nil; rankedResult = nil; rankedError = nil }
                    switch mode {
                    case .practice: practiceSection
                    case .ranked:   rankedSection
                    case .enhance:  enhanceSection
                    }
                }
            }
            .padding(16)
        }
        .onAppear {
            if teamKinds.isEmpty {
                // 저장된 배틀 팀(순서 유지) 복원 — 소유 중인 kind만, 최대 5. 5칸 미만(미설정·레거시 3마리
                // 팀)이면 소유 펫 중 미포함분을 랜덤으로 채워 5마리로(부족하면 전부). 최초 1회만 —
                // onChange가 즉시 저장해 이후 고정(매번 랜덤 아님).
                var seed = Array(settings.battleTeam.filter { settings.ownedPets[$0] != nil }.prefix(5))
                if seed.count < 5 {
                    seed.append(contentsOf: owned.filter { !seed.contains($0) }.shuffled().prefix(5 - seed.count))
                }
                teamKinds = seed
            }
            if enhanceKind == nil { enhanceKind = owned.first }
        }
        .onChange(of: teamKinds) { _, new in settings.battleTeam = new }  // 편성 변경 즉시 영속
        .sheet(isPresented: $showTypeHelp) { typeHelpSheet }
        .task { await loadEnhanceState() }   // 서버에서 강화 레벨·가용 VP 로드(등록 사용자)
        .task(id: mode) { if mode == .ranked { await loadRankedState() } }   // 랭크전 진입 시 랭킹·전적
        .onDisappear { playbackTask?.cancel(); enhanceTask?.cancel(); rankedTask?.cancel() }
    }

    // MARK: 헤더 / 게이트

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("⚔️ 아레나").font(.system(size: 15, weight: .bold))
                Spacer()
                Button { showTypeHelp = true } label: {
                    Label("타입 상성", systemImage: "hexagon").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundStyle(.tint)
            }
            Text("강화·레이팅·시즌 보상 모두 서버 반영 — 승패는 조작 방지를 위해 서버가 확정합니다. 도트 임팩트는 에셋 확보 후.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    // 6타입 상성 도움말 시트 (포켓몬 타입표 감성).
    private var typeHelpSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("타입 상성").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("닫기") { showTypeHelp = false }.font(.system(size: 12))
            }
            Text("화살표가 가리키는 쪽이 지는 상대 (스킬 상성 ×2.0 우위 / 역방향 ×0.5, 자기 타입 스킬은 ×1.5). 나머지는 중립인 6타입 순환.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            typeWheel.frame(maxWidth: .infinity).frame(height: 258)
            Text("같은 타입·컬렉션을 많이 모을수록 시너지가 점점 강해집니다(최대 5마리).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(16).frame(width: 320, height: 430)
    }

    // 6타입 상성 순환 — 각 타입이 이기는 상대로 .beats 6회(단일 6-순환). 원형 배치 순서.
    private var typeCycle: [BattleType] {
        var out: [BattleType] = []
        var t = BattleType.machine
        for _ in 0..<6 { out.append(t); t = t.beats }
        return out
    }

    // 원형 상성표 노드(컴팩트) — 컬러 아이콘 원 + 이름.
    private func typeWheelNode(_ t: BattleType) -> some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().fill(typeColor(t).opacity(0.18))
                Circle().strokeBorder(typeColor(t), lineWidth: 1.5)
                if let img = PetSprite.icon(named: typeSynergyResource(t)) {
                    Image(nsImage: img).resizable().interpolation(.none).frame(width: 18, height: 18)
                }
            }
            .frame(width: 34, height: 34)
            Text(t.displayName).font(.system(size: 8, weight: .semibold)).foregroundStyle(typeColor(t))
        }
        .frame(width: 52)
    }

    // 원형(육각) 상성 다이어그램 — 화살표 A▶B = A가 B를 이김(×1.6). 6-순환이라 링 형태로 흐른다.
    private var typeWheel: some View {
        let cycle = typeCycle
        return GeometryReader { geo in
            let cx = geo.size.width / 2, cy = geo.size.height / 2
            let r = min(geo.size.width, geo.size.height) / 2 - 30
            let pts: [CGPoint] = (0..<6).map { i in
                let a = -Double.pi / 2 + Double(i) * (Double.pi / 3)   // 상단 시작, 시계방향 60°
                return CGPoint(x: cx + r * CGFloat(cos(a)), y: cy + r * CGFloat(sin(a)))
            }
            let cols = cycle.map { typeColor($0) }
            ZStack {
                Canvas { ctx, _ in
                    for i in 0..<6 {
                        let p0 = pts[i], p1 = pts[(i + 1) % 6]
                        let dx = p1.x - p0.x, dy = p1.y - p0.y
                        let len = max(1, (dx * dx + dy * dy).squareRoot())
                        let ux = dx / len, uy = dy / len
                        let inset: CGFloat = 26
                        let s = CGPoint(x: p0.x + ux * inset, y: p0.y + uy * inset)
                        let e = CGPoint(x: p1.x - ux * inset, y: p1.y - uy * inset)
                        var line = Path(); line.move(to: s); line.addLine(to: e)
                        ctx.stroke(line, with: .color(cols[i].opacity(0.75)), lineWidth: 1.8)
                        // 화살촉(끝점 e에서 뒤로 barb 2개).
                        let ah: CGFloat = 7, side: CGFloat = 4
                        let back = CGPoint(x: e.x - ux * ah, y: e.y - uy * ah)
                        let left = CGPoint(x: back.x - uy * side, y: back.y + ux * side)
                        let right = CGPoint(x: back.x + uy * side, y: back.y - ux * side)
                        var head = Path(); head.move(to: left); head.addLine(to: e); head.addLine(to: right)
                        ctx.stroke(head, with: .color(cols[i].opacity(0.9)), lineWidth: 1.8)
                    }
                }
                ForEach(0..<6, id: \.self) { i in
                    typeWheelNode(cycle[i]).position(pts[i])
                }
            }
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

    // 팀 편성 UI — 연습전·랭크전 공유.
    @ViewBuilder private var teamEditor: some View {
        HStack {
            Text("내 배틀 팀").font(.system(size: 12, weight: .semibold))
            Text("(탭해서 편성)").font(.system(size: 9)).foregroundStyle(.tertiary)
            Spacer()
            // 팀 시너지 — 종류별 픽셀 아이콘(Tuxemon). 호버하면 효과 툴팁(팝오버).
            HStack(spacing: 5) {
                if let c = collectionSynergy {
                    synergyBadge("syn_bond", collTip(c), $collTipShown)
                }
                if let t = typeSynergy {
                    synergyBadge(typeSynergyResource(t.type), typeTip(t), $typeTipShown)
                }
                if collectionSynergy == nil && typeSynergy == nil {
                    synergyBadge("syn_bond", noneSynergyTip, $noneTipShown, grayed: true)
                }
            }
            if !settings.partyPresets.isEmpty {
                Menu {
                    ForEach(settings.partyPresets) { preset in
                        Button(preset.name.isEmpty ? "파티" : preset.name) { importParty(preset) }
                    }
                } label: {
                    Label("파티에서", systemImage: "square.and.arrow.down").font(.system(size: 10))
                }.menuStyle(.borderlessButton).fixedSize().foregroundStyle(.tint)
            }
            Button { teamKinds = Array(owned.shuffled().prefix(5)); stopPlayback(); result = nil } label: {
                Label("팀 새로 뽑기", systemImage: "shuffle").font(.system(size: 10))
            }.buttonStyle(.plain).foregroundStyle(.tint)
        }
        HStack(spacing: 8) {
            ForEach(Array(teamKinds.enumerated()), id: \.offset) { idx, kind in petCard(kind, slot: idx) }
            if teamKinds.count < 5 && teamKinds.count < owned.count { addSlotCard }
            if teamKinds.isEmpty { Text("펫 없음").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            teamEditor
            Button { fight() } label: {
                Text("⚔️ 연습전 시작").font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }.buttonStyle(.plain).disabled(teamKinds.isEmpty)

            if result != nil { battleArena }
        }
        .popover(item: $editingSlot, arrowEdge: .bottom) { sel in teamSlotPicker(slot: sel.id) }
    }

    // MARK: 랭크전 (서버 시뮬·Elo)

    @ViewBuilder private var rankedSection: some View {
        if canServerEnhance { rankedBody }
        else if needsKeyRecovery { keyRecoveryGate }
        else { rankedGate }
    }

    private var rankedGate: some View {
        VStack(spacing: 8) {
            Image(systemName: "trophy.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("랭크전은 랭킹 참여자 전용입니다.").font(.system(size: 12))
            Text("승패는 서버가 확정(조작 방지)하고 레이팅이 오릅니다. 설정에서 랭킹을 켜세요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var rankedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 레이팅 · 전적 · 오늘 판수
            HStack(spacing: 10) {
                if let r = pvpRating {
                    Text("레이팅 \(r)").font(.system(size: 13, weight: .bold)).foregroundStyle(.tint)
                } else {
                    Text("첫 도전으로 배치").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("\(pvpWins)승 \(pvpLosses)패").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("오늘 \(pvpDailyUsed)/\(pvpDailyLimit)판").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(pvpDailyUsed >= pvpDailyLimit ? .red : .secondary)
            }
            if let ls = lastSeason {
                HStack(spacing: 6) {
                    Text("🏆 지난 시즌(\(ls.period))").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange)
                    if let champ = ls.championNickname {
                        Text("챔피언 \(champ)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ls.myRp > 0 { Text("내 보상 +\(ls.myRp) RP").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tint) }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            }
            teamEditor
            Button { showChallengeConfirm = true } label: {
                Text(rankedBusy ? "매칭 중…" : "⚔️ 랭크전 도전")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.accentColor.opacity(rankedReady ? 1 : 0.5)))
                    .foregroundStyle(.white)
            }.buttonStyle(.plain).disabled(!rankedReady)
                .alert("랭크전 도전", isPresented: $showChallengeConfirm) {
                    Button("취소", role: .cancel) {}
                    Button("도전") { doRankedChallenge() }
                } message: {
                    Text("도전하면 오늘 랭크전 1판이 소모되고(현재 \(pvpDailyUsed)/\(pvpDailyLimit)판), 승패에 따라 레이팅이 변동됩니다.")
                }
            if teamKinds.count < 5 {
                Text("랭크전은 5마리 풀팀이 필요합니다 (현재 \(teamKinds.count)/5). 팀을 채워주세요.")
                    .font(.system(size: 9)).foregroundStyle(.orange)
            }
            Text("현재 팀이 등록되어 다른 유저의 상대(고스트)가 됩니다. 강화한 상태로 다시 도전하면 재등록됩니다.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if let e = rankedError {
                Text(e).font(.system(size: 10)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            if result != nil { battleArena }
            if !leaderboard.isEmpty { rankedLeaderboardView }
            if !history.isEmpty { rankedHistoryView }
        }
        .popover(item: $editingSlot, arrowEdge: .bottom) { sel in teamSlotPicker(slot: sel.id) }
    }

    private var rankedLeaderboardView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🏆 아레나 랭킹").font(.system(size: 12, weight: .semibold))
            VStack(spacing: 1) {
                ForEach(Array(leaderboard.prefix(20).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 8) {
                        Text("\(e.rank)").font(.system(size: 10, weight: .bold, design: .monospaced))
                            .frame(width: 22, alignment: .trailing).foregroundStyle(e.rank <= 3 ? .orange : .secondary)
                        Text(e.nickname).font(.system(size: 11, weight: e.isMe ? .bold : .regular)).lineLimit(1)
                        Spacer()
                        Text("\(e.wins)승 \(e.losses)패").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                        Text("\(e.rating)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.tint)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(e.isMe ? Color.accentColor.opacity(0.15) : Color.clear))
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
        }
    }

    private var rankedHistoryView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("최근 전적").font(.system(size: 12, weight: .semibold))
            VStack(spacing: 1) {
                ForEach(Array(history.prefix(10).enumerated()), id: \.offset) { _, m in
                    let icon = m.result == "me" ? "✅" : (m.result == "opp" ? "❌" : "🤝")
                    let dcolor: Color = m.ratingDelta > 0 ? .green : (m.ratingDelta < 0 ? .red : .secondary)
                    Button { replayHistory(m) } label: {
                        HStack(spacing: 8) {
                            Text(icon).font(.system(size: 11))
                            Text("vs \(m.opponentNickname)").font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text("\(m.ratingDelta > 0 ? "+" : "")\(m.ratingDelta)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(dcolor)
                            Image(systemName: "play.circle").font(.system(size: 11)).foregroundStyle(.tint)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
        }
    }

    // 도전 가능: 5마리 풀팀 + 진행 중 아님 + 일일 여유. (미달 팀의 비대칭 5v5 방지)
    private var rankedReady: Bool {
        teamKinds.count == 5 && !rankedBusy && pvpDailyUsed < pvpDailyLimit
    }

    /// 랭킹 + 전적 로드(진입·도전 후). 미등록이면 no-op.
    private func loadRankedState() async {
        guard canServerEnhance, let hmac = Keychain.loadRankingHmacKey() else { return }
        let dev = settings.rankingDeviceID
        async let lbCall = RankingAPI.shared.fetchPvpLeaderboard(deviceId: dev, hmacKeyBase64: hmac)
        async let histCall = RankingAPI.shared.fetchPvpHistory(deviceId: dev, hmacKeyBase64: hmac)
        let lb = try? await lbCall
        let hist = try? await histCall
        if let lb {
            leaderboard = lb.entries
            pvpRating = lb.myRating; pvpWins = lb.myWins; pvpLosses = lb.myLosses
            pvpDailyUsed = lb.dailyUsed; pvpDailyLimit = lb.dailyLimit
            // 아레나 칭호 언락용 캐시 갱신(최고 기록).
            settings.pvpWinsCache = max(settings.pvpWinsCache, lb.myWins)
            if let r = lb.myRating { settings.pvpBestRating = max(settings.pvpBestRating, r) }
            if let rank = lb.myRank { settings.pvpBestRank = min(settings.pvpBestRank, rank) }
            lastSeason = lb.lastSeason
        }
        if let hist { history = hist.matches }
    }

    /// 전적 항목 재생 — teamA=도전자(a), teamB=방어자(b). 승자 side는 내 관점(result)에서 역산.
    private func replayHistory(_ m: RankingAPI.PvpMatch) {
        stopPlayback(); rankedResult = nil; rankedError = nil
        aSnaps = m.teamA; bSnaps = m.teamB
        serverMaxHpA = Self.serverMaxHpDict(m.teamA, m.maxHpA)   // 저장된 실링(신규 로그) 우선, 구 로그면 nil→로컬 폴백
        serverMaxHpB = Self.serverMaxHpDict(m.teamB, m.maxHpB)
        let w: BattleSide? = m.result == "draw" ? nil : ((m.result == "me") == m.iAmChallenger ? .a : .b)
        result = BattleResult(winner: w, rounds: m.events.count, log: m.events)
        showFullLog = false
        startPlayback(total: m.events.count)
    }

    private func doRankedChallenge() {
        guard rankedReady, canServerEnhance, let hmac = Keychain.loadRankingHmacKey() else { return }
        rankedError = nil; rankedResult = nil; stopPlayback(); result = nil
        let dev = settings.rankingDeviceID
        let team = teamKinds.map { (kind: $0.rawValue, variant: battleVariant($0), progressUnits: 0.0) }
        rankedTask?.cancel()
        rankedBusy = true
        rankedTask = Task { @MainActor in
            defer { rankedBusy = false }
            do {
                // 현재 팀을 등록(강화 레벨은 서버 SSOT에서 동결) 후 도전.
                _ = try await RankingAPI.shared.registerBattleTeam(deviceId: dev, hmacKeyBase64: hmac, team: team)
                let resp = try await RankingAPI.shared.challengeRanked(deviceId: dev, hmacKeyBase64: hmac)
                if Task.isCancelled { return }
                // 서버 팀·로그를 기존 배틀 재생에 먹인다.
                aSnaps = resp.myTeam
                bSnaps = resp.oppTeam
                serverMaxHpA = Self.serverMaxHpDict(resp.myTeam, resp.maxHpA)   // 서버 실링 우선(버전 스큐 방지)
                serverMaxHpB = Self.serverMaxHpDict(resp.oppTeam, resp.maxHpB)
                let w: BattleSide? = resp.winner == "me" ? .a : (resp.winner == "opp" ? .b : nil)
                result = BattleResult(winner: w, rounds: resp.rounds, log: resp.log)
                rankedResult = RankedResult(winner: resp.winner, ratingDelta: resp.ratingDelta,
                                            coinReward: resp.coinReward, opponentNickname: resp.opponentNickname)
                pvpRating = resp.newRating
                pvpDailyUsed = resp.dailyUsed
                pvpDailyLimit = resp.dailyLimit
                if resp.winner == "me" { pvpWins += 1 } else if resp.winner == "opp" { pvpLosses += 1 }
                // 승리 코인(로컬 경제) — 서버 금액을 로컬 원장에 크레딧.
                if resp.coinReward > 0 { CoinLedger.shared.creditBonus(resp.coinReward, reason: "pvp-\(resp.winner)") }
                showFullLog = false
                startPlayback(total: resp.log.count)
                await loadRankedState()   // 랭킹·전적 갱신(새 매치 반영)
            } catch {
                if Task.isCancelled { return }
                rankedError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func petCard(_ kind: PetKind, slot: Int) -> some View {
        // 강화소에서 올린 강화 레벨(서버 SSOT)+보유 이로치를 반영해 배틀에 실제로 쓰일 스탯을 미리 보여준다.
        let level = serverLevels[kind] ?? 0
        let s = PetBattleStats.compute(kind: kind, variant: battleVariant(kind), enhanceLevel: level, progressUnits: 0)
        return Button { editingSlot = SlotSel(id: slot) } label: {
            VStack(spacing: 3) {
                thumb(kind, h: 30)
                Text(PetMetaStore.shared.displayName(for: kind)).font(.system(size: 8)).lineLimit(1)
                typeBadge(kind.battleType)
                HStack(spacing: 3) {
                    Text("Σ\(s.total)").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                    if level > 0 { Text("+\(level)").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(.orange) }
                }
            }
            .frame(width: 74).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.08)))
            .overlay(alignment: .topLeading) {
                if slot == 0 && teamKinds.count > 1 {
                    Text("선봉").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: -2, y: -4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if teamKinds.count > 1 {
                    Button { removeSlot(slot) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                            .foregroundStyle(.secondary).background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                    }.buttonStyle(.plain).offset(x: 4, y: -4)
                }
            }
        }.buttonStyle(.plain)
    }

    private var addSlotCard: some View {
        Button { editingSlot = SlotSel(id: teamKinds.count) } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("추가").font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .frame(width: 74, height: 68)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3])))
        }.buttonStyle(.plain)
    }

    // 파티 프리셋 → 배틀 팀 가져오기 (소유·유니크·최대 5마리).
    private func importParty(_ preset: PartyPreset) {
        var seen = Set<PetKind>(); var picked: [PetKind] = []
        for m in preset.members where settings.ownedPets[m.kind] != nil && !seen.contains(m.kind) {
            seen.insert(m.kind); picked.append(m.kind)
            if picked.count >= 5 { break }
        }
        if !picked.isEmpty { teamKinds = picked; stopPlayback(); result = nil }
    }

    private func removeSlot(_ slot: Int) {
        guard teamKinds.count > 1, slot < teamKinds.count else { return }
        teamKinds.remove(at: slot); stopPlayback(); result = nil
    }

    // 순서 재정렬 — teamKinds 순서 = 선봉 순서(slot 0 = 선봉). 인접 스왑 / 선봉으로 이동.
    private func moveSlot(_ slot: Int, by delta: Int) {
        let dst = slot + delta
        guard teamKinds.indices.contains(slot), teamKinds.indices.contains(dst) else { return }
        teamKinds.swapAt(slot, dst); stopPlayback(); result = nil
    }
    private func moveToLead(_ slot: Int) {
        guard teamKinds.indices.contains(slot), slot != 0 else { return }
        let k = teamKinds.remove(at: slot); teamKinds.insert(k, at: 0); stopPlayback(); result = nil
    }

    // 슬롯 편성 팝오버 상단 순서 재정렬 바 (선봉 = slot 0).
    @ViewBuilder private func reorderBar(slot: Int) -> some View {
        if slot < teamKinds.count, teamKinds.count > 1 {
            HStack(spacing: 6) {
                Text("순서").font(.system(size: 9)).foregroundStyle(.secondary)
                Button { moveSlot(slot, by: -1); editingSlot = nil } label: { Image(systemName: "chevron.left") }
                    .disabled(slot == 0)
                Button { moveToLead(slot); editingSlot = nil } label: { Text("선봉으로").font(.system(size: 9)) }
                    .disabled(slot == 0)
                Button { moveSlot(slot, by: 1); editingSlot = nil } label: { Image(systemName: "chevron.right") }
                    .disabled(slot >= teamKinds.count - 1)
                Spacer()
                Text("선봉이 먼저 싸웁니다").font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .padding(.horizontal, 8).padding(.top, 8)
            Divider().padding(.top, 6)
        }
    }

    // 슬롯 편성 팝오버 — 소유 펫 그리드에서 골라 교체/추가. 중복 kind 방지(HP 딕셔너리 유니크 불변식).
    private func teamSlotPicker(slot: Int) -> some View {
        let currentKind = slot < teamKinds.count ? teamKinds[slot] : nil
        let inTeam = Set(teamKinds.enumerated().filter { $0.offset != slot }.map(\.element))
        let choices = owned.filter { !inTeam.contains($0) }
        return VStack(spacing: 0) {
            reorderBar(slot: slot)
            ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
                ForEach(choices, id: \.self) { k in
                    Button {
                        if slot < teamKinds.count { teamKinds[slot] = k }
                        else if teamKinds.count < 5 { teamKinds.append(k) }   // 5마리 상한 방어
                        stopPlayback(); result = nil; editingSlot = nil
                    } label: {
                        VStack(spacing: 2) {
                            thumb(k, h: 26)
                            Text(PetMetaStore.shared.displayName(for: k)).font(.system(size: 7)).lineLimit(1)
                            typeBadge(k.battleType)
                        }
                        .frame(width: 62).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(k == currentKind ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(k == currentKind ? Color.accentColor : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }.padding(8)
            }
        }
        .frame(width: 264, height: 288)
    }

    // MARK: 배틀 관전 (공유 스테이지 + 파티 아이콘 + lunge/flash)

    private var battleArena: some View {
        let log = result?.log ?? []
        let done = playbackStep >= log.count
        let hp = hpDicts(step: playbackStep)
        let current: BattleEvent? = (playbackStep > 0 && playbackStep <= log.count) ? log[playbackStep - 1] : nil
        // 배틀 표시는 시뮬에 쓰인 스냅샷 기준(편성 편집과 무관하게 고정).
        let aKinds = aSnaps.map(\.kind), bKinds = bSnaps.map(\.kind)
        let aActive = aKinds.first { (hp.a[$0] ?? 0) > 0 }
        let bActive = bKinds.first { (hp.b[$0] ?? 0) > 0 }
        return VStack(spacing: 8) {
            partyRow(hp: hp, aKinds: aKinds, bKinds: bKinds, aActive: aActive, bActive: bActive)
            battleStage(hp: hp, aActive: aActive, bActive: bActive, current: current)
                .overlay { if done { resultBanner(result?.winner) } }
            currentActionLine(current)
            controls(total: log.count)
            if showFullLog { fullLog(log) }
            if done, let rr = rankedResult { rankedResultCard(rr) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(Color.secondary.opacity(0.06)))
    }

    // 랭크전 결과 요약 — 레이팅 변화 + 획득 코인 + 상대.
    private func rankedResultCard(_ rr: RankedResult) -> some View {
        let color: Color = rr.winner == "me" ? .green : (rr.winner == "opp" ? .red : .secondary)
        let sign = rr.ratingDelta > 0 ? "+" : ""
        return VStack(spacing: 3) {
            Text("vs \(rr.opponentNickname)").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("레이팅 \(sign)\(rr.ratingDelta)").font(.system(size: 12, weight: .bold)).foregroundStyle(color)
                if let r = pvpRating { Text("→ \(r)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                Text("🪙 +\(rr.coinReward)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(color.opacity(0.1)))
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
                if let k = bActive { hpBox(k, cur: hp.b[k] ?? 0, showNumbers: false, snaps: bSnaps, server: serverMaxHpB).padding(6) }
            }
            .overlay(alignment: .bottomTrailing) {
                if let k = aActive { hpBox(k, cur: hp.a[k] ?? 0, showNumbers: true, snaps: aSnaps, server: serverMaxHpA).padding(6) }
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

    private func hpBox(_ kind: PetKind, cur: Int, showNumbers: Bool, snaps: [BattlePetSnapshot], server: [PetKind: Int]?) -> some View {
        let maxv = maxHP(kind, in: snaps, server: server)
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

    private func fullLog(_ log: [BattleEvent]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(log.enumerated()), id: \.offset) { _, e in
                    let side = e.attacker == .a ? "A" : "B"
                    let move = SkillCatalog.displayName(id: e.move)
                        ?? BattleLines.moveName(collection: e.attackerKind.collection, signature: e.move == "signature")
                    Text("R\(e.round) \(side) \(PetMetaStore.shared.displayName(for: e.attackerKind)) «\(move)» ▶ \(PetMetaStore.shared.displayName(for: e.defenderKind)) −\(e.damage)\(e.quip != nil ? " «\(e.quip!)»" : "")")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(e.attacker == .a ? Color.primary : Color.secondary)
                }
            }
        }
        .frame(height: 130).padding(6)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.06)))
    }

    // MARK: 배틀 상태 재구성 + 재생

    /// HP 바 상한 — **서버가 실링(server[kind])을 줬으면 그걸 우선** 사용해 엔진 버전 스큐에도 desync가 없게
    /// 한다. 없으면(로컬 대전·구서버·구 로그) 로컬 `BattleEngine.finalStats`로 폴백(엔진 makeCombatants 동일 소스).
    private func maxHP(_ kind: PetKind, in snaps: [BattlePetSnapshot], server: [PetKind: Int]?) -> Int {
        if let v = server?[kind] { return v }
        guard let m = snaps.first(where: { $0.kind == kind }) else { return 1 }
        return BattleEngine.finalStats(for: m, in: BattleTeam(snaps)).hp
    }
    /// 서버 maxHP 배열(팀 순서)을 kind→maxHP 딕셔너리로. 배열 없거나 길이 불일치면 nil(로컬 폴백).
    /// (internal — 하위호환 폴백 회귀 테스트용. ArenaMaxHpPayloadTests 참조.)
    static func serverMaxHpDict(_ snaps: [BattlePetSnapshot], _ arr: [Int]?) -> [PetKind: Int]? {
        guard let arr, arr.count == snaps.count else { return nil }
        return Dictionary(zip(snaps.map(\.kind), arr), uniquingKeysWith: { x, _ in x })
    }
    private func hpDicts(step: Int) -> (a: [PetKind: Int], b: [PetKind: Int]) {
        // 유니크 kind 전제지만 방어적으로 uniquing(미래에 동일 kind 편성 허용돼도 크래시 없게).
        var a = Dictionary(aSnaps.map { ($0.kind, maxHP($0.kind, in: aSnaps, server: serverMaxHpA)) }, uniquingKeysWith: { x, _ in x })
        var b = Dictionary(bSnaps.map { ($0.kind, maxHP($0.kind, in: bSnaps, server: serverMaxHpB)) }, uniquingKeysWith: { x, _ in x })
        for e in (result?.log ?? []).prefix(step) {
            if e.attacker == .a { b[e.defenderKind] = max(0, (b[e.defenderKind] ?? 0) - e.damage) }
            else { a[e.defenderKind] = max(0, (a[e.defenderKind] ?? 0) - e.damage) }
        }
        return (a, b)
    }
    // 활성 시너지 감지 — 동족(컬렉션) / 동타입. tie-break는 TeamSynergy.bonus 와 동일한 팀 순서
    // first-max(strict >)로 결정 — 뱃지가 가리키는 타입/스탯이 실제 전투 엔진과 항상 일치(Dictionary
    // 비결정 순서로 5마리 동수에서 엔진과 어긋나던 것 수정).
    private var collectionSynergy: (name: String, count: Int)? {
        guard teamKinds.count >= 2 else { return nil }
        var counts: [PetCollection: Int] = [:]
        for k in teamKinds { counts[k.collection, default: 0] += 1 }
        var top: PetCollection? = nil, topCount = 0
        for k in teamKinds where (counts[k.collection] ?? 0) > topCount {
            topCount = counts[k.collection] ?? 0; top = k.collection
        }
        guard let top, (TeamSynergy.collectionBonus[topCount] ?? 0) > 0 else { return nil }
        return (top.displayName, topCount)
    }
    private var typeSynergy: (type: BattleType, count: Int)? {
        guard teamKinds.count >= 2 else { return nil }
        var counts: [BattleType: Int] = [:]
        for k in teamKinds { counts[k.battleType, default: 0] += 1 }
        var top: BattleType? = nil, topCount = 0
        for k in teamKinds where (counts[k.battleType] ?? 0) > topCount {
            topCount = counts[k.battleType] ?? 0; top = k.battleType
        }
        guard let top, (TeamSynergy.typeBonus[topCount] ?? 0) > 0 else { return nil }
        return (top, topCount)
    }

    // 툴팁 문구 — 효과만 서술(버프 수치·배수 미표기).
    private func collTip(_ c: (name: String, count: Int)) -> String {
        "같은 컬렉션 ‘\(c.name)’ \(c.count)마리 동족\n강한 유대 — 팀 전원 스탯이 오릅니다."
    }
    private func typeTip(_ t: (type: BattleType, count: Int)) -> String {
        let stat = statName(TeamSynergy.signatureStat(of: t.type))
        return "같은 타입 ‘\(t.type.displayName)’ \(t.count)마리\n느슨한 유대 — 팀 전원 \(stat)이(가) 오릅니다."
    }
    private func statName(_ s: StatKind) -> String {
        switch s { case .hp: return "체력"; case .atk: return "공격"; case .def: return "방어"; case .spd: return "속도" }
    }
    private var noneSynergyTip: String {
        "팀 시너지 없음\n같은 컬렉션이나 타입을 2마리 이상 모으면\n팀 전원 스탯이 오릅니다."
    }

    // 배틀 타입 → Tuxemon element 아이콘 리소스명.
    private func typeSynergyResource(_ t: BattleType) -> String {
        switch t {
        case .beast:   return "syn_beast"     // wood(잎)
        case .warrior: return "syn_warrior"   // heroic(별)
        case .chaos:   return "syn_chaos"     // fire(불꽃)
        case .arcane:  return "syn_arcane"    // cosmic(크리스탈)
        case .machine: return "syn_machine"   // metal(금속별)
        case .mascot:  return "syn_mascot"    // sky(깃털)
        }
    }

    // 시너지 배지 — Tuxemon 픽셀 아이콘. 호버 시 팝오버 툴팁(.help가 이 창에선 안 떠서 onHover+popover).
    private func synergyBadge(_ resource: String, _ tip: String, _ shown: Binding<Bool>, grayed: Bool = false) -> some View {
        Group {
            if let img = PetSprite.icon(named: resource) {
                Image(nsImage: img).resizable().interpolation(.none)
                    .frame(width: 20, height: 20)
                    .grayscale(grayed ? 1 : 0).opacity(grayed ? 0.55 : 1)
            } else {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .onHover { shown.wrappedValue = $0 }
        .popover(isPresented: shown, arrowEdge: .bottom) {
            Text(tip)
                .font(.system(size: 11)).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220).padding(10)
        }
    }

    private func fight() {
        stopPlayback()
        // 내 팀 — 강화소 로컬 레벨 + 보유 이로치 반영.
        let aS = teamKinds.map { BattlePetSnapshot(kind: $0, variant: battleVariant($0), enhanceLevel: serverLevels[$0] ?? 0) }
        let bS = matchmakeOpponent(against: aS)   // Σ스탯 근접 상대 샘플링(#4)
        aSnaps = aS; bSnaps = bS
        serverMaxHpA = nil; serverMaxHpB = nil    // 로컬 대전 — 같은 엔진이 시뮬하니 로컬 finalStats로 렌더(스큐 없음)
        let r = BattleEngine.simulate(teamA: BattleTeam(aS), teamB: BattleTeam(bS), seed: .random(in: 1...UInt64.max))
        result = r
        showFullLog = false
        startPlayback(total: r.log.count)
    }

    /// 팀 총 전투력(시너지·강화 반영).
    private func teamPower(_ snaps: [BattlePetSnapshot]) -> Int {
        let team = BattleTeam(snaps)
        return snaps.reduce(0) { $0 + BattleEngine.finalStats(for: $1, in: team).total }
    }
    /// 내 팀 전투력에 가장 근접한 상대 팀을 무작위 후보 중에서 고른다(일방적 매치 방지).
    private func matchmakeOpponent(against aS: [BattlePetSnapshot]) -> [BattlePetSnapshot] {
        let size = max(1, min(5, aS.count))
        let target = teamPower(aS)
        var best: [BattlePetSnapshot] = []
        var bestDiff = Int.max
        for _ in 0..<48 {
            let snaps = Array(PetKind.allCases.shuffled().prefix(size)).map { BattlePetSnapshot(kind: $0) }
            let diff = abs(teamPower(snaps) - target)
            if diff < bestDiff { bestDiff = diff; best = snaps }
        }
        return best
    }

    private func startPlayback(total: Int, from start: Int = 0) {
        playbackStep = start
        if start == 0 { lungeAmount = 0; flashBrightness = 0 }
        let sp = max(1, speed)
        func ms(_ base: Double) -> Duration { .milliseconds(Int(base / sp)) }
        playbackTask = Task { @MainActor in
            for i in (start + 1)...max(1, total) {
                try? await Task.sleep(for: ms(360))
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.15)) { playbackStep = i }
                guard let log = result?.log, i - 1 < log.count else { continue }
                let e = log[i - 1]
                let superEff = e.effectiveness > 1.0, weakEff = e.effectiveness < 1.0
                lungeSide = e.attacker
                withAnimation(.easeOut(duration: 0.1)) { lungeAmount = superEff ? 1.3 : 1 }   // 효과 굉장 → 크게 파고듦
                let defSide: BattleSide = (e.attacker == .a) ? .b : .a
                flashSide = defSide
                flashBrightness = superEff ? 1.25 : (weakEff ? 0.45 : 0.9)                     // 상성별 피격 섬광 강약
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
                if e.defenderFainted { try? await Task.sleep(for: ms(300)) }   // KO 순간 잠깐 멈춤(강조)
                if Task.isCancelled { return }
            }
        }
    }
    private func skipToEnd() { stopPlayback(); withAnimation { playbackStep = result?.log.count ?? 0 } }
    private func replay() { stopPlayback(); startPlayback(total: result?.log.count ?? 0) }
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
    }

    // MARK: 강화소 (펫 반응 이펙트)

    @ViewBuilder private var enhanceSection: some View {
        if canServerEnhance { enhanceBody }
        else if needsKeyRecovery { keyRecoveryGate }
        else { enhanceGate }
    }

    // VP 강화는 서버 authoritative라 랭킹 참여자 전용. 미등록이면 안내.
    private var enhanceGate: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("VP 강화는 랭킹 참여자 전용입니다.").font(.system(size: 12))
            Text("강화 레벨·VP는 서버가 관리(조작 방지)합니다. 설정에서 랭킹을 켜세요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var enhanceBody: some View {
        let kind = enhanceKind ?? owned.first ?? .fox
        let level = serverLevels[kind] ?? 0
        let rarity = PetKind.rarityFor(kind) ?? .common
        let stats = PetBattleStats.compute(kind: kind, variant: 0, enhanceLevel: level, progressUnits: 0)
        let destroyed = enhancePhase == .result(.destroy)
        let safeAllowed = EnhanceEngine.canSafeEnhance(level: level)
        let useSafe = safeMode && safeAllowed
        let oddsRow = useSafe ? EnhanceEngine.safeOdds(level: level, failStreak: 0) : EnhanceEngine.odds[level]
        let baseCost = useSafe ? EnhanceEngine.safeCost(level: level, rarity: rarity)
                               : EnhanceEngine.cost(level: level, rarity: rarity)
        let attemptCost = Int((Double(baseCost) * (1 - eventDiscount)).rounded())   // 이벤트 VP 할인
        let effGuarantee = useGuarantee && guaranteeCount > 0
        let effProtect = useProtect && protectCount > 0 && !effGuarantee
        let inDestroyZone = EnhanceEngine.zone(level: level) == .destroy && !useSafe
        let insufficient = availableVp.map { $0 < attemptCost } ?? false
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

            if let ev = eventLabel {
                HStack(spacing: 4) {
                    Text("🎉").font(.system(size: 11))
                    Text(ev).font(.system(size: 10, weight: .semibold)).foregroundStyle(.pink)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.pink.opacity(0.12)))
            }

            if level < EnhanceEngine.maxLevel {
                // 안전 강화 토글 — 파괴 없음 + soft-pity(연속 실패 시 성공률↑), VP 1.5배. +12부터는 불가.
                if safeAllowed {
                    Toggle(isOn: $safeMode) {
                        HStack(spacing: 4) {
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 10))
                            Text("안전 강화 (파괴 없음 · 연속 실패 시 성공률↑ · VP 1.5배)").font(.system(size: 10))
                        }
                    }
                    .toggleStyle(.switch).controlSize(.mini).tint(.green)
                    .disabled(enhancePhase != .idle || effGuarantee)
                }
                enhanceItemBar(effProtect: effProtect, effGuarantee: effGuarantee, inDestroyZone: inDestroyZone)
                oddsBar(oddsRow)
                oddsLegend(oddsRow)   // 안전 모드면 파괴 없는 확률행 표시
                HStack(spacing: 6) {
                    Text("이번 시도 VP \(attemptCost.formatted())")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text(useSafe ? "(안전 ×1.5)" : "(\(rarity.displayName) ×\(String(format: "%.1f", EnhanceEngine.rarityCostMultiplier(rarity))))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    if let vp = availableVp {
                        Text("가용 \(vp.formatted()) VP")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(insufficient ? Color.red : Color.accentColor)
                    }
                    Text(useSafe ? "안전 구간" : zoneLabel(level))
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(useSafe ? .green : zoneColor(level))
                }
                let btnLabel = enhancePhase == .charging ? "강화 중…"
                    : (insufficient ? "VP 부족"
                    : (effGuarantee ? "🎫 확정 강화" : (useSafe ? "🛡️ 안전 강화" : "⚒️ 강화 시도")))
                let btnColor: Color = effGuarantee ? .blue : (useSafe ? .green : .orange)
                Button { attemptEnhance(kind, safe: useSafe, useProtect: effProtect, useGuarantee: effGuarantee) } label: {
                    Text(btnLabel).font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: AppRadius.md)
                            .fill(btnColor.opacity(enhancePhase == .idle && !insufficient ? 1 : 0.5)))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain).disabled(enhancePhase != .idle || insufficient)
            } else {
                Text("★ 만렙 (+\(EnhanceEngine.maxLevel)) 달성").font(.system(size: 12, weight: .bold)).foregroundStyle(.orange)
            }

            if let err = enhanceStateError {
                Text(err).font(.system(size: 10)).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Text("서버 반영 — VP 실차감·영속. +15 도달 기대 VP ≈ \(Int(EnhanceEngine.expectedVP(toReach: 15) * EnhanceEngine.rarityCostMultiplier(rarity)).formatted()) (파괴 리셋 반영, \(rarity.displayName) 기준)")
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
                                    Text("+\(serverLevels[k] ?? 0)").font(.system(size: 7, design: .monospaced)).foregroundStyle(.orange)
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
    private func oddsLegend(_ o: [Double]) -> some View {
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

    private func oddsBar(_ o: [Double]) -> some View {
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

    /// 서버 강화 가능 조건 — 랭킹 등록 + 빌드 구성 + hmac 키 존재.
    private var canServerEnhance: Bool {
        RankingAPI.isConfigured && settings.rankingRegistered
            && !settings.rankingDeviceID.isEmpty && Keychain.loadRankingHmacKey() != nil
    }

    /// 랭킹엔 등록·참여 중이지만 keychain 인증 키(HMAC)만 유실된 상태.
    /// vault 마이그레이션이 항목을 못 읽거나(ad-hoc ACL 재승인 거부), 재설치로 서버 발급 키가
    /// 로컬에 없을 때 발생. 이 경우 서버 인증 랭킹 쓰기(제출·강화·랭크전)가 모두 no-op 되므로
    /// "참여자 전용"이 아니라 "계정 복구 필요"로 정확히 안내하고 self-heal 경로를 준다.
    private var needsKeyRecovery: Bool {
        RankingAPI.isConfigured && settings.rankingRegistered
            && !settings.rankingDeviceID.isEmpty && Keychain.loadRankingHmacKey() == nil
    }

    /// 키 유실 시 안내 + 복구 유도 게이트(랭크전·강화 공용). 설정→랭킹으로 라우팅한다.
    private var keyRecoveryGate: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash").font(.system(size: 34)).foregroundStyle(.orange)
            Text("계정 인증 키를 복구해야 합니다.").font(.system(size: 12, weight: .medium))
            Text("랭킹엔 참여 중이지만 이 기기의 인증 키가 유실됐습니다. 서버의 레이팅·강화 기록은 그대로이며, 계정 복구로 키를 다시 받으면 아레나가 열립니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("설정에서 계정 복구…") {
                NotificationCenter.default.post(name: .openRankingSettings, object: nil)
            }.controlSize(.small).padding(.top, 2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 20)
    }

    /// 서버에서 강화 레벨 + 가용 VP 로드. 미등록/미구성이면 no-op.
    private func loadEnhanceState() async {
        guard canServerEnhance, let hmac = Keychain.loadRankingHmacKey() else { return }
        do {
            let st = try await RankingAPI.shared.fetchEnhanceState(
                deviceId: settings.rankingDeviceID, hmacKeyBase64: hmac)
            var lv: [PetKind: Int] = [:]
            for (k, v) in st.levels { if let pk = PetKind(rawValue: k) { lv[pk] = v } }
            serverLevels = lv
            availableVp = st.availableVp
            protectCount = st.protectCount; guaranteeCount = st.guaranteeCount
            protectPrice = st.protectPrice; guaranteePrice = st.guaranteePrice
            eventLabel = st.eventActive ? st.eventLabel : nil
            eventDiscount = st.eventActive ? st.eventDiscount : 0
            enhanceStateError = nil
        } catch {
            enhanceStateError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // 완화 아이템 바 — 보유 수·구매·사용 토글.
    private func enhanceItemBar(effProtect: Bool, effGuarantee: Bool, inDestroyZone: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                itemBuy("🛡️ 보호권", protectCount, protectPrice, "protect")
                itemBuy("🎫 확정권", guaranteeCount, guaranteePrice, "guarantee")
                Spacer()
            }
            HStack(spacing: 14) {
                if guaranteeCount > 0 {
                    Toggle(isOn: $useGuarantee) { Text("확정권 사용 (무조건 성공)").font(.system(size: 9)) }
                        .toggleStyle(.switch).controlSize(.mini).tint(.blue).disabled(enhancePhase != .idle)
                }
                if protectCount > 0 && inDestroyZone && !effGuarantee {
                    Toggle(isOn: $useProtect) { Text("보호권 사용 (파괴 방지)").font(.system(size: 9)) }
                        .toggleStyle(.switch).controlSize(.mini).tint(.green).disabled(enhancePhase != .idle)
                }
                Spacer()
            }
        }
    }

    private func itemBuy(_ label: String, _ count: Int, _ price: Int, _ item: String) -> some View {
        HStack(spacing: 3) {
            Text("\(label) \(count)").font(.system(size: 10))
            Button { buyItem(item) } label: {
                Text("＋\(price.formatted())VP").font(.system(size: 9))
            }.buttonStyle(.plain).foregroundStyle(.tint).disabled(buyBusy || enhancePhase != .idle)
        }
    }

    private func buyItem(_ item: String) {
        guard canServerEnhance, !buyBusy, enhancePhase == .idle,
              let hmac = Keychain.loadRankingHmacKey() else { return }
        buyBusy = true; enhanceStateError = nil
        Task { @MainActor in
            defer { buyBusy = false }
            do {
                let r = try await RankingAPI.shared.buyEnhanceItem(
                    deviceId: settings.rankingDeviceID, hmacKeyBase64: hmac, item: item)
                protectCount = r.protectCount; guaranteeCount = r.guaranteeCount; availableVp = r.availableVp
            } catch {
                enhanceStateError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    private func attemptEnhance(_ kind: PetKind, safe: Bool, useProtect: Bool, useGuarantee: Bool) {
        guard enhancePhase == .idle, canServerEnhance,
              let hmac = Keychain.loadRankingHmacKey() else { return }
        // 최근 강화 목록 갱신 (맨 앞으로)
        recentEnhanced.removeAll { $0 == kind }
        recentEnhanced.insert(kind, at: 0)
        if recentEnhanced.count > 12 { recentEnhanced.removeLast(recentEnhanced.count - 12) }
        enhanceStateError = nil
        enhanceTask?.cancel()
        enhanceTask = Task { @MainActor in
            // 차지 시작 + 서버 롤 요청(동시).
            enhancePhase = .charging
            withAnimation(.easeInOut(duration: 0.2).repeatCount(4, autoreverses: true)) { enhancePulse = true }
            withAnimation(.easeIn(duration: 0.6)) { enhanceBright = 0.18 }
            let res: RankingAPI.EnhanceResultResponse
            do {
                res = try await RankingAPI.shared.enhancePet(
                    deviceId: settings.rankingDeviceID, hmacKeyBase64: hmac, kind: kind.rawValue,
                    safe: safe, useProtect: useProtect, useGuarantee: useGuarantee)
            } catch {
                if Task.isCancelled { return }
                enhancePulse = false; enhanceBright = 0; enhancePhase = .idle
                enhanceStateError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return
            }
            guard let outcome = EnhanceOutcome(rawValue: res.outcome) else { enhancePhase = .idle; return }
            try? await Task.sleep(for: .milliseconds(350))   // 최소 차지 연출 유지
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
            // 서버 SSOT 반영.
            withAnimation { serverLevels[kind] = res.newLevel }
            availableVp = res.availableVp
            protectCount = res.protectCount; guaranteeCount = res.guaranteeCount
            appendEnhance(level: res.beforeLevel, newLevel: res.newLevel, outcome: outcome,
                          protectUsed: res.protectUsed, guaranteeUsed: res.guaranteeUsed)
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

    private func appendEnhance(level: Int, newLevel: Int, outcome: EnhanceOutcome,
                               protectUsed: Bool = false, guaranteeUsed: Bool = false) {
        var text: String, color: Color
        switch outcome {
        case .success:   text = "+\(level) → +\(newLevel)  ✅ 성공"; color = .green
        case .stay:      text = "+\(level)  · 유지";               color = .secondary
        case .downgrade: text = "+\(level) → +\(newLevel)  🔻 강등"; color = .orange
        case .destroy:   text = "+\(level) → +0  💥 파괴!";         color = .red
        }
        if guaranteeUsed { text += "  🎫 확정권"; color = .green }
        if protectUsed { text += "  🛡️ 보호권(파괴 방지)"; color = .blue }
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
