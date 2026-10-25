import SwiftUI

/// A fixed command dock keeps the battle playable at the existing 560×640 minimum.
struct ManualBattleView: View {
    @ObservedObject var session: ManualBattleSession
    let team: [BattlePetSnapshot]
    let opponent: [BattlePetSnapshot]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.windowIsVisible) private var windowIsVisible
    @State private var menu: CommandMenu = .moves
    @State private var pendingCommand: ManualCommand?
    @State private var automatic = false
    @State private var showLog = false
    @State private var showRules = false
    @State private var animating = false
    @State private var discardConfirm = false
    @State private var displayState: ManualBattleState?
    @State private var eventInFlight: ManualEvent?
    @State private var fastPlayback = false
    @State private var skipPlayback = false
    private enum CommandMenu { case moves, party }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = session.error {
                        Text(error).foregroundStyle(.red).font(.caption)
                        if session.serverEnabled && !session.isRemote {
                            Button("서버 상태 새로고침") { Task { await session.refreshServer() } }.disabled(session.busy)
                        }
                        if session.hasPendingRequest { Button("같은 요청으로 재시도") { session.retryPending() }.disabled(session.busy) }
                        else { Button("저장된 연습전 삭제") { discardConfirm = true } }
                    }
                    if session.isRemote {
                        Text(session.state?.achievementsEligible == true ? "서버 검증 대전 · 공식 업적과 레인보우 숙련 기록 적립" : "서버 대전 · 보유 정보 검증 전으로 공식 업적·훈장 미적립")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("서버 상태 새로고침") { Task { await session.refreshServer() } }.font(.caption).disabled(session.busy)
                    }
                    if let state = session.state {
                        if state.tutorial { tutorialTip(state) }
                        let visible = displayState?.id == state.id ? displayState! : state
                        battleStage(visible)
                        eventSummary(visible)
                        HStack {
                            Toggle("빠른 연출", isOn: $fastPlayback).toggleStyle(.checkbox).font(.caption2)
                            if animating { Button("이 턴 연출 건너뛰기") { skipPlayback = true }.font(.caption2) }
                        }
                        if state.finished && !animating { result(state) }
                    } else { setup }
                }.padding(14)
            }
            Divider()
            if let state = session.state, !state.finished { commands(state).padding(12) }
            else if session.state == nil { startControls.padding(12) }
        }
        .frame(minWidth: 540, idealWidth: 560, minHeight: 600, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("명령 확인", isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { pendingCommand = nil } })) {
            Button("취소", role: .cancel) { pendingCommand = nil }
            Button("실행") { if let command = pendingCommand { perform(command) }; pendingCommand = nil }
        } message: { Text(commandDescription(pendingCommand)) }
        .alert("저장된 연습전을 삭제할까요?", isPresented: $discardConfirm) {
            Button("취소", role: .cancel) {}
            Button("삭제", role: .destructive) { automatic = false; session.discard() }
        } message: { Text("진행 중인 연습전만 삭제합니다. 소유 펫과 재화는 바뀌지 않습니다.") }
        .sheet(isPresented: $showRules) { rules }
        .task { await session.refreshServer() }
        .task(id: "\(automatic)-\(session.state?.revision ?? -1)-\(windowIsVisible)-\(pendingCommand != nil)-\(showRules)-\(session.busy)-\(session.hasPendingRequest)-\(animating)") {
            guard automatic, !animating, !session.busy, !session.hasPendingRequest, windowIsVisible, pendingCommand == nil, !showRules, let state = session.state, !state.finished else { return }
            do { try await Task.sleep(for: .milliseconds(850)) } catch { return }
            guard !Task.isCancelled, let command = ManualBattleEngine.chooseAI(state, side: 0) else { return }
            perform(command)
        }
        .task(id: "\(session.state?.id.uuidString ?? "none")-\(session.state?.revision ?? -1)-\(windowIsVisible)") {
            await playTurn()
        }
        .onDisappear { automatic = false }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.isRemote ? "수동 서버 도전" : "수동 연습전").font(.headline)
                Text("상대 AI · 재화·랭크 점수 변동 없음").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showRules = true } label: { Image(systemName: "questionmark.circle") }.help("전투 규칙")
            Button("닫기") { dismiss() }
        }.padding(12)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("내 팀을 직접 지휘하세요").font(.title3.bold())
            Text("기술·교체·방어를 고르면 양측이 한 번씩 행동합니다. 교체하면 새 펫이 상대 공격을 받습니다.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(team, id: \.kind) { pet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ManualPetPortrait(pet: pet, height: 40)
                        Text(pet.kind.displayName).font(.headline)
                        Text(pet.kind.battleType.displayName).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if pet.variant >= 4 { Text("🌈 레인보우").font(.caption) }
                    }
                    if pet.variant >= 4 { branchPicker(pet) }
                    else { Text("기술 \(SkillCatalog.skills(kind: pet.kind, variant: pet.variant).count)개 · 방어·교체 가능").font(.caption).foregroundStyle(.secondary) }
                }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            if !opponent.isEmpty {
                Text("상대 선봉과 팀").font(.subheadline.bold())
                HStack { ForEach(opponent, id: \.kind) { pet in
                    VStack { ManualPetPortrait(pet: pet, height: 32); Text(pet.kind.displayName).font(.system(size: 9)).lineLimit(1) }
                        .frame(maxWidth: .infinity)
                } }
            }
            Text("25턴부터 소모전 피해 · 40턴 종료 시 무승부").font(.caption).foregroundStyle(.secondary)
            if let message = session.serverStatusMessage { Text(message).font(.caption2).foregroundStyle(.secondary) }
            masteryPreview
            OwnedManualAchievementShelf(preview: session.archive.achievementPreview)
        }
    }

    private func branchPicker(_ pet: BattlePetSnapshot) -> some View {
        let kinds = team.map(\.kind)
        let selected = session.branches(for: kinds)[pet.kind.rawValue] ?? .original
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(ManualBranch.allCases) { branch in
                let move = ManualBattleRules.ultimate(pet.kind.battleType, branch: branch)
                Button { session.setBranch(branch, kind: pet.kind, team: kinds) } label: {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: selected == branch ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(branch.label) · \(move.name)").font(.caption.bold())
                            Text("위력 \(Int(move.power)) · \(move.summary)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(6).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("궁극기 \(branch.label), \(move.name), \(selected == branch ? "선택됨" : "미선택")")
            }
            Text("전투 전 무료 변경 · 전투 중 고정 · 게이지 10").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var startControls: some View {
        VStack(spacing: 6) {
            HStack {
                Button("대여 팀으로 배우기") { startTutorial() }
                Spacer()
                Button("이 팀으로 연습") { session.start(teamA: team, teamB: opponent) }
                    .buttonStyle(.borderedProminent).disabled(team.isEmpty || team.count != opponent.count)
            }
            if session.serverEnabled {
                Button("등록 팀으로 서버 도전 · 하루 10회") { session.startRemote(team: team) }
                    .disabled(team.count != 5)
            }
        }.disabled(session.busy || session.hasPendingRequest)
    }

    private func startTutorial() {
        let kinds: [PetKind] = [.fox, .scrapBot, .warrior]
        let a = kinds.map { BattlePetSnapshot(kind: $0, variant: 4) }
        session.start(teamA: a, teamB: Array(a.reversed()), tutorial: true)
    }

    private func tutorialTip(_ state: ManualBattleState) -> some View {
        let text: String
        if state.teams[0].charge >= 10 { text = "궁극기가 준비됐습니다. 지금 쓸지 다음 상대를 위해 남길지 선택해 보세요." }
        else if state.turn <= 2 { text = "기술의 ×2 / ×0.5 상성과 PP를 비교해 보세요. 대여 펫은 실제 보유 목록에 추가되지 않습니다." }
        else { text = "교체는 공격 기회를 소비합니다. 타입기로 상태를 준비하거나, 방어로 피해를 줄일 수도 있습니다." }
        return Label(text, systemImage: "lightbulb").font(.caption)
            .padding(10).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func battleStage(_ state: ManualBattleState) -> some View {
        let a = state.teams[0], b = state.teams[1]
        return VStack(spacing: 8) {
            HStack { party(a); Spacer(); Text("턴 \(state.turn) / 40").font(.caption.monospacedDigit()); Spacer(); party(b) }
            HStack(alignment: .top) {
                status(b.fighters[b.active], team: b, turn: state.turn)
                Spacer()
                ManualPetPortrait(pet: b.fighters[b.active].pet, height: 80)
                    .opacity(b.fighters[b.active].alive ? 1 : 0.3)
                    .offset(x: eventInFlight?.side == 1 && eventInFlight?.kind == "skillUsed" ? -12 : 0)
            }
            HStack(alignment: .bottom) {
                ManualPetPortrait(pet: a.fighters[a.active].pet, height: 80,
                    celebrating: state.outcome?.winner == 0 && (session.officialRecords[a.fighters[a.active].pet.kind.rawValue]?.wins ?? 0) >= 100)
                    .opacity(a.fighters[a.active].alive ? 1 : 0.3)
                    .offset(x: eventInFlight?.side == 0 && eventInFlight?.kind == "skillUsed" ? 12 : 0)
                Spacer()
                status(a.fighters[a.active], team: a, turn: state.turn)
            }
            if state.turn >= 23 { Text(state.turn >= 25 ? "소모전: 매 턴 전원 최대 HP 5% 피해" : "25턴부터 소모전이 시작됩니다")
                .font(.caption2).foregroundStyle(.orange) }
        }.padding(12)
            .background(LinearGradient(colors: [Color.accentColor.opacity(0.06), Color.secondary.opacity(0.07)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 12))
    }

    private func party(_ team: ManualTeam) -> some View {
        HStack(spacing: 4) { ForEach(team.fighters) { f in
            Image(systemName: f.alive ? "circle.fill" : "xmark.circle")
                .font(.system(size: 10)).foregroundStyle(f.id == team.active ? Color.accentColor : .secondary)
                .help("\(f.pet.kind.displayName) · HP \(f.hp)/\(f.stats.hp)")
        } }
    }

    private func status(_ fighter: ManualFighter, team: ManualTeam, turn: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(fighter.pet.kind.displayName).font(.subheadline.bold()); Text(fighter.type.displayName).font(.caption2).foregroundStyle(.secondary) }
            ProgressView(value: Double(fighter.hp), total: Double(fighter.stats.hp))
                .tint(fighter.hp * 5 < fighter.stats.hp ? .red : .green)
                .accessibilityLabel("HP \(fighter.hp) / \(fighter.stats.hp)")
            Text("HP \(fighter.hp)/\(fighter.stats.hp)").font(.caption.monospacedDigit())
            if team.fighters.contains(where: { $0.pet.variant >= 4 }) {
                Text("🌈 \(team.charge)/10\(team.charge == 10 ? " · 궁극기 준비" : "")").font(.caption2).foregroundStyle(.purple)
            }
            if fighter.immuneUntil >= turn { Text("행동불가 면역 · \(fighter.immuneUntil - turn + 1)턴").font(.caption2).foregroundStyle(.blue) }
            ForEach(fighter.effects, id: \.sequence) { e in
                Text("\(ManualBattleRules.effectName(e.id)) · \(max(0, e.expires - turn + 1))턴\(e.shield > 0 ? " · 실드 \(e.shield)" : "")")
                    .font(.system(size: 9)).foregroundStyle(ManualBattleRules.isBuff(e.id) ? .blue : .orange)
            }
        }.frame(width: 260, alignment: .leading)
    }

    private func eventSummary(_ state: ManualBattleState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(state.events.filter { !$0.text.isEmpty }.suffix(showLog ? 100 : 3))) { event in
                Text(event.text).font(.caption).foregroundStyle(event.kind == "fainted" ? .orange : .primary)
            }
            if !state.events.isEmpty { Button(showLog ? "로그 접기" : "최근 전투 로그 보기") { showLog.toggle() }.font(.caption2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commands(_ state: ManualBattleState) -> some View {
        let legal = ManualBattleEngine.legalCommands(state, side: 0)
        let me = state.teams[0], fighter = me.fighters[me.active]
        return VStack(spacing: 8) {
            HStack {
                if me.needsReplacement { Text("다음 출전 펫을 선택하세요").font(.subheadline.bold()) }
                else {
                    Button("기술 선택") { automatic = false; menu = .moves }
                    Button("펫 교체") { automatic = false; menu = .party }
                    Button("방어") { request(.guardMove) }.disabled(!legal.contains(.guardMove)).keyboardShortcut("g", modifiers: [])
                }
                Spacer()
                Toggle("AI에게 맡기기", isOn: $automatic).toggleStyle(.checkbox).font(.caption)
            }
            if menu == .party || me.needsReplacement { partyCommands(state, legal: legal) }
            else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Array(fighter.moves.enumerated()), id: \.element.id) { index, move in
                        moveButton(move, index: index, state: state, enabled: legal.contains(.move(move.id)))
                    }
                }
            }
            HStack {
                Text(me.needsReplacement ? "강제 교체는 행동을 소모하지 않습니다" : "명령 확정 후에는 되돌릴 수 없습니다")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("항복") { request(.surrender) }.font(.caption2)
            }
        }.disabled(animating || session.busy || session.hasPendingRequest)
    }

    private func moveButton(_ move: ManualMove, index: Int, state: ManualBattleState, enabled: Bool) -> some View {
        let fighter = state.teams[0].fighters[state.teams[0].active]
        let target = state.teams[1].fighters[state.teams[1].active]
        let effect = SkillCatalog.skillEffectiveness(BattleType(rawValue: move.type) ?? fighter.type, vs: target.type)
        let pp = move.ultimate ? "게이지 10" : (move.maxPP.map { "PP \(fighter.pp[move.id, default: 0])/\($0)" } ?? "PP ∞")
        return Button { request(.move(move.id)) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack { Text(move.name).font(.caption.bold()).lineLimit(1); Spacer(minLength: 0); Text(pp).font(.system(size: 9, design: .monospaced)) }
                Text("\(move.type.capitalized) · 위력 \(Int(move.power))\(move.power > 0 ? " · 상성 ×\(effect == 0.5 ? "0.5" : String(Int(effect)))" : "")")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        }.buttonStyle(.bordered).tint(move.ultimate ? .purple : .accentColor).disabled(!enabled)
            .keyboardShortcut(move.ultimate ? "u" : KeyEquivalent(Character(String(index + 1))), modifiers: [])
            .help("\(move.summary)\n예상 피해 \(ManualBattleRules.damage(move, from: fighter, to: target, factor: 0.9))~\(ManualBattleRules.damage(move, from: fighter, to: target, factor: 0.999999)). 상대가 교체·방어하지 않고 실드가 없을 때.")
    }

    private func partyCommands(_ state: ManualBattleState, legal: [ManualCommand]) -> some View {
        let me = state.teams[0]
        return HStack(alignment: .top, spacing: 6) {
            ForEach(me.fighters) { fighter in
                let command: ManualCommand = me.needsReplacement ? .replacement(fighter.id) : .swap(fighter.id)
                Button { request(command) } label: {
                    VStack(spacing: 4) {
                        ManualPetPortrait(pet: fighter.pet, height: 30)
                        Text(fighter.pet.kind.displayName).font(.system(size: 9)).lineLimit(1)
                        Text("\(fighter.hp)/\(fighter.stats.hp)").font(.system(size: 9, design: .monospaced))
                        Text(fighter.type.displayName).font(.system(size: 8))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(!legal.contains(command))
                    .help(fighter.moves.map { "\($0.name): \($0.maxPP == nil ? "∞" : String(fighter.pp[$0.id, default: 0]))" }.joined(separator: "\n"))
            }
        }
    }

    private func result(_ state: ManualBattleState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.outcome?.winner == 0 ? "승리!" : (state.outcome?.winner == 1 ? "다음에는 다른 작전으로" : "무승부"))
                .font(.title2.bold())
            Text("\(state.turn)턴 · 생존 \(state.teams[0].fighters.filter(\.alive).count)마리 · 교체 \(state.events.filter { $0.side == 0 && $0.kind == "switched" }.count)회")
                .font(.caption).foregroundStyle(.secondary)
            Text(session.isRemote ? (session.eligibleKinds.isEmpty ? "보유 검증 전 · 공식 훈장 미적립" : "공식 숙련 기록은 서버에서 확정됩니다") : "연습 기록 · 공식 숙련 훈장 미적립")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if !session.isRemote { Button("같은 조건 재도전") { automatic = false; session.replaySameConditions() } }
                Button("편성으로 돌아가기") { automatic = false; session.discard() }
            }
            if !session.newAchievements.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.isRemote ? "새 전투 업적 달성!" : "연습 업적 달성 · 공식 칭호 미적립").font(.subheadline.bold())
                    ForEach(session.newAchievements) { achievement in
                        Label("\(achievement.name) · \(achievement.rewardName)", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            masteryPreview
            OwnedManualAchievementShelf(preview: session.isRemote ? nil : session.archive.achievementPreview)
        }
    }

    private var masteryPreview: some View {
        DisclosureGroup("레인보우 숙련 훈장") {
            VStack(alignment: .leading, spacing: 8) {
                Text("공식 훈장은 서버 검증 대전에서 적립됩니다. 아래는 연습용 미리보기이며 능력치를 올리지 않습니다.").font(.caption2).foregroundStyle(.secondary)
                ForEach((session.state?.teams[0].fighters.map(\.pet) ?? team).filter { $0.variant >= 4 }, id: \.kind) { pet in
                    let record = session.archive.records[pet.kind.rawValue] ?? ManualMasteryRecord()
                    let official = session.officialRecords[pet.kind.rawValue] ?? ManualMasteryRecord()
                    HStack {
                        Text("🏅 \(pet.kind.displayName)")
                        Spacer()
                        Text("공식 \(official.title) · \(official.wins)승").monospacedDigit()
                    }.font(.caption)
                    Text("연습 기록 \(record.wins)승 · 공식 A \(official.originalWins)/5 · B \(official.alternateWins)/5").font(.caption2)
                    Text("A 문양 \(record.originalWins)/5 · B 문양 \(record.alternateWins)/5\(record.originalEmblem && record.alternateEmblem ? " · 쌍문양 달성" : "")").font(.caption2)
                }
                Text("1승 첫 발자국 → 10승 숙련 → 30승 베테랑 → 100승 마스터").font(.caption2)
            }.padding(.top, 6)
        }
    }

    private func request(_ command: ManualCommand) { automatic = false; pendingCommand = command }

    @MainActor
    private func playTurn() async {
        guard windowIsVisible else { return }
        guard let final = session.state else { displayState = nil; animating = false; return }
        guard var visible = displayState, visible.id == final.id,
              visible.events.count < final.events.count else {
            displayState = final; eventInFlight = nil; animating = false; return
        }
        animating = true; skipPlayback = false
        for event in final.events.dropFirst(visible.events.count) {
            if Task.isCancelled { return }
            if skipPlayback { break }
            visible.turn = event.turn
            if let hp = event.hp { visible.teams[event.side].fighters[event.slot].hp = hp }
            if event.kind == "switched" { visible.teams[event.side].active = event.slot }
            if event.kind == "fainted" { visible.teams[event.side].fighters[event.slot].hp = 0 }
            visible.events.append(event)
            if event.text.isEmpty { displayState = visible; continue }
            withAnimation(.easeInOut(duration: 0.15)) { displayState = visible; eventInFlight = event }
            do { try await Task.sleep(for: .milliseconds(fastPlayback ? 70 : 190)) } catch { return }
        }
        withAnimation(.easeInOut(duration: 0.15)) { displayState = final; eventInFlight = nil }
        animating = false; skipPlayback = false
    }
    private func perform(_ command: ManualCommand) {
        withAnimation(.easeInOut(duration: 0.25)) { session.submit(command) }
        menu = .moves
    }
    private func commandDescription(_ command: ManualCommand?) -> String {
        guard let command, let state = session.state else { return "" }
        switch command {
        case .move(let id):
            let move = state.teams[0].fighters[state.teams[0].active].moves.first { $0.id == id }
            return "\(move?.name ?? id)\n\(move?.summary ?? "")"
        case .swap(let slot): return "\(state.teams[0].fighters[slot].pet.kind.displayName)에게 교체합니다. 이번 턴 공격을 포기하고 상대 공격을 받습니다. 버프·실드는 사라지고 디버프는 남습니다."
        case .replacement(let slot): return "\(state.teams[0].fighters[slot].pet.kind.displayName)을 출전시킵니다. 행동을 소모하지 않습니다."
        case .guardMove: return "이번 턴 직접 피해를 50% 줄입니다. 지속 피해와 상태효과는 막지 않습니다. 연속 턴에는 사용할 수 없습니다."
        case .surrender: return "이 연습전을 패배로 종료합니다. 재화와 랭크 점수는 바뀌지 않습니다."
        }
    }
    private var rules: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("직접 지휘하기").font(.title2.bold())
            Text("교체 → 방어 → 기술 순으로 처리하고 같은 순서에서는 스피드가 높은 펫이 먼저 움직입니다.")
            Text("Machine → Beast → Chaos → Arcane → Mascot → Warrior → Machine\n화살표 방향 ×2, 반대 ×0.5, 자기 타입 기술 ×1.5")
            Text("타입기는 낮은 피해와 확정 상태효과, 고유기는 제한된 횟수의 강한 공격입니다. PP는 새 경기에서 복원됩니다.")
            Text("레인보우는 전투 전에 궁극기 A·B 중 하나를 고릅니다. 게이지 10은 팀이 공유하며 출전한 레인보우만 사용할 수 있습니다.")
            Text("25턴부터 전원 소모전 피해를 받으며 40턴 종료에도 결판이 나지 않으면 무승부입니다.")
            Button("알겠습니다") { showRules = false }.buttonStyle(.borderedProminent)
        }.font(.callout).padding(24).frame(width: 470, height: 400)
    }
}

struct ManualPetPortrait: View {
    let pet: BattlePetSnapshot
    let height: CGFloat
    var celebrating = false
    @Environment(\.windowIsVisible) private var visible
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.125, paused: !visible)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let frames = PetSprite.frames(for: pet.kind, action: celebrating ? .special1 : .sit)
            let frame = frames.isEmpty ? PetSprite.frames(for: pet.kind, action: .walk).first : frames[Int(time * 8) % frames.count]
            ZStack {
                if celebrating {
                    Circle().strokeBorder(AngularGradient(colors: [.purple, .pink, .orange, .cyan, .purple], center: .center), lineWidth: 2)
                        .scaleEffect(0.9 + 0.08 * sin(time * 3))
                    Image(systemName: "sparkles").foregroundStyle(.yellow).offset(x: height * 0.35, y: -height * 0.35)
                }
                if let frame {
                    Image(nsImage: frame).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                        .colorMultiply(pet.variant >= 4 ? WalkingCat.prestigeTint(at: time) : .white)
                } else { Image(systemName: "pawprint.fill").resizable().aspectRatio(contentMode: .fit) }
            }
        }.frame(width: height, height: height).accessibilityLabel(pet.kind.displayName)
    }
}
