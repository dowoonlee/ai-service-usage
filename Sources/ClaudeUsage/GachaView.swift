import AppKit
import SwiftUI

/// 펫 상점과 트레이너 메뉴.
struct GachaView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var settings = Settings.shared
    @State private var phase: ResultPhase = .idle
    @State private var errorMessage: String?
    @State private var confirmation: DrawConfirmation?
    @State private var hatchStep = 0
    @ObservedObject var navigation = TrainerNavigation()
    @State private var dexSelection: PetSelection?
    @State private var dexPreviewRequest = 0
    @State private var resultIndex = 0
    @State private var enhanceTarget: PetKind?
    /// 도감 이름 검색어 (부분일치, 대소문자 무시). 비어있으면 필터 안 함.
    @State private var dexSearch: String = ""
    /// 도감 보유 상태 필터.
    @State private var dexFilter: DexFilter = .all

    /// 도감 보유 상태 필터. 195종 규모에서 "미보유"만 보면 뭘 더 뽑을지 바로 파악된다.
    enum DexFilter: String, CaseIterable, Identifiable {
        case all, owned, missing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:     return "전체"
            case .owned:   return "보유"
            case .missing: return "미보유"
            }
        }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case home = "트레이너 메뉴"
        case dex = "펫 도감", party = "차트 파티", shop = "펫 뽑기", enhance = "펫 강화"
        case gym = "도장", arena = "아레나", team = "배틀 팀", history = "랭크전 전적"
        case ranking = "사용량 랭킹", guild = "길드"
        case guestbook = "길드 방명록"
        case report = "트레이너 카드 · 리포트", achievements = "훈장", recap = "연간 리캡"
        var id: Self { self }
        @MainActor static var groups: [(title: String, icon: String, tabs: [Self])] {
            let battles: [Self] = [.gym, .arena, .team, .history]
            return [
                ("내 펫", "pawprint", [.dex, .party, .shop, .enhance]),
                ("전투", "shield", battles),
                ("커뮤니티", "bubble.left.and.bubble.right", [.ranking, .guild]),
                ("내 기록", "book.closed", [.report, .achievements, .recap])
            ]
        }
    }

    enum ResultPhase {
        case idle
        case tray(id: UUID, premium: Bool, results: [MultiPullResult])
    }

    private struct DrawConfirmation: Identifiable {
        let premium: Bool
        let multiple: Bool
        let cost: String
        let id = UUID()
    }

    private var isOpening: Bool {
        if case .tray(_, _, let results) = phase {
            return hatchStep < HatchTray.finalStep(count: results.count)
        }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760
            HStack(spacing: 0) {
                if navigation.tab == .home {
                    TrainerMenu(selected: .home, sidebar: false, status: menuStatus, open: open)
                } else {
                    if wide {
                        TrainerMenu(selected: navigation.tab, sidebar: true, status: menuStatus, open: open)
                            .frame(width: 188)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            if !wide {
                                Button { navigation.tab = .home } label: { Label("메뉴", systemImage: "sidebar.left") }
                            }
                            Text(navigation.tab.rawValue).font(.headline)
                            Spacer()
                        }.padding(10)
                        Divider()
                        destinationContent
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    private func menuStatus(_ tab: Tab) -> String? {
        if tab == .guild && settings.hasUnseenGuestbook { return "새 방명록" }
        return nil
    }

    private func open(_ tab: Tab) {
        switch tab {
        case .recap: RecapWindowController.shared.present()
        default:
            if tab == .enhance { enhanceTarget = nil }
            navigation.tab = tab
        }
    }

    @ViewBuilder private var destinationContent: some View {
        switch navigation.tab {
        case .home, .dex:
            ScrollViewReader { reader in
                ScrollView {
                    VStack {
                        if let pet = dexSelection {
                            PetPreviewView(kind: pet.kind, variant: pet.variant, settings: settings)
                                .id(pet).frame(minHeight: 180)
                            HStack {
                                PetPlacementMenu(pet: pet, open: open)
                                Button("이 펫 강화") {
                                    enhanceTarget = pet.kind
                                    navigation.tab = .enhance
                                }
                            }
                        }
                        inventorySection
                    }.padding(16).id("dexStart")
                }.onChange(of: dexPreviewRequest) { _, _ in reader.scrollTo("dexStart", anchor: .top) }
            }
        case .shop: shopTab
        case .party: PartyView()
        case .gym: GymView()
        case .arena: ArenaView()
        case .enhance: ArenaView(destination: .enhance, initialPet: enhanceTarget)
        case .team: ArenaView(destination: .team)
        case .history: ArenaView(destination: .history)
        case .report: ReportView()
        case .ranking: RankingView()
        case .guild: GuildView()
        case .guestbook: GuildView(guestbookFirst: true)
        case .achievements: TrainerHonorsView()
        case .recap: EmptyView()
        }
    }

    private var shopTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                Divider()
                resultArea
            }
            .padding(20)
        }
        .alert(item: $confirmation) { request in
            let name = request.premium ? "프리미엄" : "일반"
            let count = request.multiple ? Gacha.multiPullCount : 1
            return Alert(title: Text("\(name) \(count)회 뽑기"),
                         message: Text("사용할 재화  ·  \(request.cost)"),
                         primaryButton: .default(Text("\(count)회 뽑기")) { draw(request) },
                         secondaryButton: .cancel(Text("취소")))
        }
    }

    // MARK: - Header (잔액 + 뽑기 버튼)

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 잔액 묶음 — fixedSize로 묶어 가로 공간이 부족해도 숫자가 글자별 세로 줄바꿈되지 않게.
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    CoinIcon(size: 18)
                    Text("\(settings.coins)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.cyan)
                    Text("\(settings.rp)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Image(systemName: "ticket.fill")
                        .foregroundStyle(.blue)
                    Text("\(settings.gachaTickets)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                // 프리미엄 가챠권(sudo pull). 상점 헤더에선 코인/RP/일반 가챠권처럼 항상 노출 (0이어도)
                // — 사용자가 자기 잔액을 늘 확인할 수 있도록.
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(Rarity.mythic.color)
                    Text("\(settings.premiumTickets)")
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                }
                .help("프리미엄 가챠권 — RP로 구매, Mythic·Legendary 전용 풀 (sudo pull)")
                // 이로치 조각 — 만렙 펫 오버플로우로만 적립. 보유 시에만 노출(엔드게임 재화).
                if settings.shinyShards > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "hexagon.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.pink)
                        Text("\(settings.shinyShards)")
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                    }
                    .help("이로치 조각 — 만렙 펫의 오버플로우로 적립, 레인보우 레어 해금 시도(\(PetOwnership.prestigeAttemptCost)조각/회, 성공 \(Int(PetOwnership.prestigeSuccessChance * 100))%, \(PetOwnership.prestigePityCeiling)회 천장)에 사용")
                }
            }
            .fixedSize()
            HStack(spacing: 12) {
                drawTicket(premium: false)
                drawTicket(premium: true)
            }
        }
    }

    private func price(premium: Bool, multiple: Bool) -> (label: String, affordable: Bool) {
        let tickets: Int
        let amount: Int
        if premium && multiple {
            (tickets, amount) = Gacha.premiumMultiCost(tickets: settings.premiumTickets)
        } else if multiple {
            (tickets, amount) = Gacha.multiPullCost(tickets: settings.gachaTickets)
        } else {
            tickets = min(1, max(0, premium ? settings.premiumTickets : settings.gachaTickets))
            amount = tickets == 1 ? 0 : (premium ? RankPointLedger.premiumTicketCostRP : Gacha.pullCost)
        }
        var parts: [String] = []
        if tickets > 0 { parts.append("\(premium ? "프리미엄권" : "일반권") \(tickets)장") }
        if amount > 0 { parts.append("\(amount.formatted()) \(premium ? "RP" : "코인")") }
        return (parts.joined(separator: " + "), amount <= (premium ? settings.rp : settings.coins))
    }

    private func drawTicket(premium: Bool) -> some View {
        let title = premium ? "프리미엄 뽑기권" : "일반 뽑기권"
        let single = price(premium: premium, multiple: false)
        let multi = price(premium: premium, multiple: true)
        let ink = HatchTray.ink(premium)
        return ZStack(alignment: .topTrailing) {
            Button {
                let request = DrawConfirmation(premium: premium, multiple: false, cost: single.label)
                if premium { confirmation = request } else { draw(request) }
            } label: {
                HStack(spacing: 12) {
                    HatchEgg(premium: premium, step: 0, pixel: 2)
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { _ in
                            Rectangle().fill(HatchTray.accent(premium).opacity(0.55)).frame(width: 2, height: 3)
                        }
                    }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.caption.bold())
                        Text("1회 뽑기").font(.headline)
                        Text(single.label).font(.caption.monospacedDigit())
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .foregroundStyle(.white)
                .background(ink, in: DrawTicketShape())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) 1회 뽑기, \(single.label)")
            .disabled(isOpening || !single.affordable)
            .padding(.top, 11)
            Button {
                confirmation = DrawConfirmation(premium: premium, multiple: true, cost: multi.label)
            } label: {
                Text("10회 뽑기").font(.caption.bold())
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .foregroundStyle(ink)
                    .background(HatchTray.accent(premium), in: RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .disabled(isOpening || !multi.affordable)
            .accessibilityLabel("\(title) 10회 뽑기, \(multi.label)")
            .help(multi.label)
            .padding(.trailing, 7)
        }
    }

    private func draw(_ request: DrawConfirmation) {
        guard !isOpening else { return }
        do {
            let current = price(premium: request.premium, multiple: request.multiple)
            guard current.label == request.cost else {
                errorMessage = "보유 재화가 바뀌었습니다. 비용을 다시 확인해 주세요."
                phase = .idle
                return
            }
            let pulls: [GachaPull]
            if request.multiple {
                pulls = try request.premium ? Gacha.rollPremiumMulti() : Gacha.rollMulti()
            } else if request.premium {
                if settings.premiumTickets == 0 && !RankPointLedger.shared.purchasePremiumTicket() {
                    throw GachaError.insufficientRP
                }
                pulls = [try Gacha.rollPremium()]
            } else {
                pulls = [try Gacha.roll(useTicket: settings.gachaTickets > 0)]
            }
            // Resolve each paid draw once. Playback and window lifecycle only affect presentation.
            let results = Gacha.commitMulti(pulls)
            errorMessage = nil
            hatchStep = reduceMotion ? HatchTray.finalStep(count: results.count) : 0
            resultIndex = 0
            phase = .tray(id: UUID(), premium: request.premium, results: results)
        } catch {
            errorMessage = error.friendlyDescription
            phase = .idle
        }
    }

    @ViewBuilder private var resultArea: some View {
        switch phase {
        case .idle:
            Text(errorMessage ?? "뽑기권을 선택해 펫을 만나보세요")
                .foregroundStyle(errorMessage == nil ? Color.secondary : .red)
                .frame(maxWidth: .infinity, minHeight: 90)
        case .tray(let id, let premium, let results):
            HatchTray(premium: premium, results: results, step: $hatchStep) { phase = .idle }
                .id(id)
            if !isOpening, results.indices.contains(resultIndex) {
                if results.count > 1 {
                    Picker("배치할 펫", selection: $resultIndex) {
                        ForEach(results.indices, id: \.self) { index in
                            Text("\(index + 1). \(PetMetaStore.shared.displayName(for: results[index].pull.kind))").tag(index)
                        }
                    }
                }
                let pull = results[resultIndex].pull
                PetPlacementMenu(pet: PetSelection(kind: pull.kind, variant: pull.variantUnlocked ?? 0), open: open)
            }
            if !isOpening, let raw = settings.pendingCollectionCelebration,
               let collection = PetCollection(rawValue: raw) {
                CollectionCompleteBanner(collection: collection) {
                    settings.pendingCollectionCelebration = nil
                }
            }
        }
    }

    // MARK: - Inventory

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("도감")
                    .font(.headline)
                Spacer()
                Text("\(settings.ownedPets.count)/\(PetKind.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // 검색 + 보유 필터 — 195종 규모에서 특정 펫/미보유를 빠르게 찾기 위한 도구.
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("이름 검색", text: $dexSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                    if !dexSearch.isEmpty {
                        Button { dexSearch = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.secondary.opacity(0.1)))
                Picker("", selection: $dexFilter) {
                    ForEach(DexFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 168)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 희귀한 등급 먼저 (위 → 아래).
                    ForEach([Rarity.mythic, .legendary, .epic, .rare, .common], id: \.self) { r in
                        raritySection(r)
                    }
                    // 검색/필터 결과가 전무하면 안내 (빈 화면 방지).
                    if dexVisibleTotal == 0 {
                        Text("조건에 맞는 펫이 없어요")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                }
            }
        }
    }

    /// 검색어 또는 보유 필터가 활성인지 — 활성이면 섹션을 강제 펼치고 빈 섹션은 숨긴다.
    private var dexFilterActive: Bool {
        !dexSearch.trimmingCharacters(in: .whitespaces).isEmpty || dexFilter != .all
    }

    /// 현재 검색/필터를 통과한 전체 종 수 (0이면 "결과 없음" 안내용).
    private var dexVisibleTotal: Int {
        [Rarity.mythic, .legendary, .epic, .rare, .common]
            .reduce(0) { $0 + (Gacha.pool[$1] ?? []).filter(dexMatches).count }
    }

    /// 한 종이 현재 검색어/보유 필터를 통과하는지.
    private func dexMatches(_ kind: PetKind) -> Bool {
        let owned = settings.ownedPets[kind] != nil
        if dexFilter == .owned && !owned { return false }
        if dexFilter == .missing && owned { return false }
        let q = dexSearch.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let name = PetMetaStore.shared.displayName(for: kind)
            let hit = name.range(of: q, options: .caseInsensitive) != nil
                || kind.rawValue.range(of: q, options: .caseInsensitive) != nil
            if !hit { return false }
        }
        return true
    }

    // MARK: - 도감 등급별 목록

    /// 도감 섹션 접기/펼치기 토글 (SettingsView.CreditsView 패턴). id = Rarity.rawValue.
    private func toggleInventoryCollapsed(_ id: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if settings.gachaInventoryCollapsed.contains(id) {
                settings.gachaInventoryCollapsed.remove(id)
            } else {
                settings.gachaInventoryCollapsed.insert(id)
            }
        }
    }

    @ViewBuilder
    private func raritySection(_ rarity: Rarity) -> some View {
        let kinds = Gacha.pool[rarity] ?? []
        let visible = kinds.filter(dexMatches)
        let ownedCount = kinds.filter { settings.ownedPets[$0] != nil }.count
        // 검색/필터 중엔 강제 펼침(토글 무시)하고, 결과 없는 등급 섹션은 통째로 숨긴다.
        let collapsed = !dexFilterActive && settings.gachaInventoryCollapsed.contains(rarity.rawValue)
        if !(dexFilterActive && visible.isEmpty) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    toggleInventoryCollapsed(rarity.rawValue)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(rarity.color)
                            .frame(width: 8, height: 8)
                        Text(rarity.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(rarity.color)
                        Spacer()
                        Text(dexFilterActive ? "\(visible.count)" : "\(ownedCount)/\(kinds.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if !dexFilterActive {
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(dexFilterActive)
                if !collapsed {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)], spacing: 12) {
                        ForEach(visible) { kind in
                            InventorySlot(
                            kind: kind,
                            ownership: settings.ownedPets[kind],
                            isHighlighted: settings.pendingHighlights.contains(kind),
                            onTap: {
                                guard let o = settings.ownedPets[kind] else { return }
                                let activeVariant = settings.petClaudeKind == kind
                                    ? settings.petClaudeVariant
                                    : (settings.petCursorKind == kind ? settings.petCursorVariant : 0)
                                let v = o.unlockedVariants.contains(activeVariant)
                                    ? activeVariant
                                    : (o.unlockedVariants.sorted().first ?? 0)
                                // 직접 클릭 → 강조 해제. 영속화는 settings 안에서 처리.
                                settings.acknowledgeHighlight(kind)
                                dexSelection = PetSelection(kind: kind, variant: v)
                                dexPreviewRequest += 1
                                errorMessage = nil
                            }
                        )
                    }
                }
            }
            }
        }
    }

}

private struct InventorySlot: View {
    let kind: PetKind
    let ownership: PetOwnership?
    let isHighlighted: Bool
    let onTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .fill(Color.secondary.opacity(0.1))
                if let img = PetSprite.image(for: kind, action: .sit, frameIndex: 0) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                        .colorMultiply(ownership == nil ? .black : .white)
                        .opacity(ownership == nil ? 0.45 : 1.0)
                }
                if isHighlighted {
                    // 새 펫 / variant 해금 알림. 직접 클릭해 확인하기 전까지 영속.
                    Text("!")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.yellow))
                        .overlay(Circle().stroke(Color.orange, lineWidth: 1))
                        .shadow(color: Color.yellow.opacity(0.7), radius: 3)
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: 60, height: 60)
            .overlay(
                // 슬롯 외곽 강조 — NEW 뱃지와 동일한 노란 톤. ownership != nil 조건은 isHighlighted
                // 트리거 시점에 항상 만족하지만 방어적으로 유지.
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(isHighlighted ? Color.yellow : Color.clear, lineWidth: 2)
            )
            .overlay(alignment: .bottomLeading) {
                // 배틀 타입 배지(보유 펫만) — 아레나 타입 아이콘 재활용.
                if ownership != nil, let img = PetSprite.icon(named: Self.typeIconName(kind.battleType)) {
                    Image(nsImage: img).resizable().interpolation(.none)
                        .frame(width: 14, height: 14).padding(2)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                        .padding(2)
                        .help(kind.battleType.displayName)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if ownership != nil { onTap?() }
            }
            .help(ownership == nil ? "잠김" : (isHighlighted ? "새로 해금 — 클릭하여 확인" : "클릭하여 미리보기"))

            Text(ownership == nil ? "?" : PetMetaStore.shared.displayName(for: kind))
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(ownership == nil ? .secondary : .primary)

            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(ownership?.unlockedVariants.contains(i) == true
                              ? variantDot(i) : Color.secondary.opacity(0.2))
                        .frame(width: 5, height: 5)
                }
                // Prestige(홀로) 보유 시 무지개 도트 추가.
                if ownership?.unlockedVariants.contains(PetOwnership.prestigeVariant) == true {
                    Circle()
                        .fill(AngularGradient(
                            gradient: Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red]),
                            center: .center))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    private func variantDot(_ i: Int) -> Color { WalkingCat.variantDotColor(i) }

    // 배틀 타입 → Tuxemon element 아이콘 리소스명 (아레나와 동일 매핑).
    static func typeIconName(_ t: BattleType) -> String {
        switch t {
        case .beast:   return "syn_beast"
        case .warrior: return "syn_warrior"
        case .chaos:   return "syn_chaos"
        case .arcane:  return "syn_arcane"
        case .machine: return "syn_machine"
        case .mascot:  return "syn_mascot"
        }
    }
}

/// 컬렉션 컴플리트 배너 — `.hatched` 진입 시 그 가챠로 셋이 완성됐으면 상단에 노출.
/// 2.5s 후 자동 dismiss + 클릭 시 즉시 dismiss. 둘 다 `pendingCollectionCelebration = nil`로
/// 소비해서 같은 컴플리트가 다음 가챠에서 또 뜨지 않도록 한다.
private struct CollectionCompleteBanner: View {
    let collection: PetCollection
    let onDismiss: () -> Void

    @State private var pulse: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.yellow)
                .scaleEffect(pulse ? 1.15 : 1.0)
                .shadow(color: .yellow.opacity(0.6), radius: pulse ? 8 : 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(collection.displayName.uppercased()) COMPLETE!")
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                Text("+\(collection.bonusCoins) coin · \(collection.subtitle)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(collection.accentColor)
                .shadow(color: collection.accentColor.opacity(0.6), radius: pulse ? 12 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .stroke(.white.opacity(0.3), lineWidth: 1)
        )
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
            // 2.5s 후 자동 소비.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                onDismiss()
            }
        }
    }
}

/// Stepped corners and thumb notches keep the ticket outline on the pixel grid.
private struct DrawTicketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, mid = floor(h / 2)
        let vertices: [CGPoint] = [
            .init(x: 4, y: 0), .init(x: w-4, y: 0), .init(x: w-4, y: 3), .init(x: w, y: 3),
            .init(x: w, y: mid-4), .init(x: w-4, y: mid-4), .init(x: w-4, y: mid+4), .init(x: w, y: mid+4),
            .init(x: w, y: h-3), .init(x: w-4, y: h-3), .init(x: w-4, y: h), .init(x: 4, y: h),
            .init(x: 4, y: h-3), .init(x: 0, y: h-3), .init(x: 0, y: mid+4), .init(x: 4, y: mid+4),
            .init(x: 4, y: mid-4), .init(x: 0, y: mid-4), .init(x: 0, y: 3), .init(x: 4, y: 3)
        ]
        var path = Path()
        path.addLines(vertices)
        path.closeSubpath()
        return path
    }
}

/// 헤더/설정 화면에서 사용하는 정적 코인 아이콘 (sprite 첫 프레임).
/// 자산 누락 시 SF Symbol fallback.
struct CoinIcon: View {
    var size: CGFloat = 16
    var body: some View {
        if let img = PetSprite.frames(named: "Coin", cellSize: (18, 20)).first {
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: size))
                .foregroundStyle(.yellow)
        }
    }
}

/// 도감에서 인벤토리 슬롯을 클릭했을 때 띄우는 펫 미리보기.
///
/// 진입 직후 0.55s 동안 좌우 swing 하던 sprite 그룹이 스무스하게 좌측으로 슬라이드되고,
/// 그 동안 우측에 캐릭터 설명 카드가 페이드인된다. kind/variant가 바뀌면 부모(GachaView)의 .id()가
/// 이 view를 재마운트 → @State `enteredAt`이 .onAppear에서 새로 잡혀 슬라이드가 다시 재생된다.
private struct PetPreviewView: View {
    let kind: PetKind
    @ObservedObject var settings: Settings

    /// 진입 슬라이드 재생 여부. onAppear에서 true로 넘기면 SwiftUI가 보간한다.
    ///
    /// 예전엔 `enteredAt` 기준 elapsed를 TimelineView 안에서 매 프레임 계산했는데, 그러면 연출이
    /// 끝난 뒤에도 같은 값을 초당 60~120회 다시 구하면서 클로저 안의 카드 전체가 재레이아웃됐다.
    /// 상태 전환은 Core Animation이 처리하므로 뷰 그래프를 매 프레임 건드리지 않는다.
    @State private var entered = false

    /// 사용자가 dot selector로 토글하는 현재 variant. init 시점의 variant로 시드.
    /// 외부에서 variant 변경은 .id() 재마운트로 처리 (다른 펫 → 새 PetPreviewView 인스턴스).
    /// 같은 펫 안에서 이로치 토글은 internal state라 슬라이드 애니메이션 재생 X — 즉시 hue 변경.
    @State private var selectedVariant: Int
    /// hover 중인 칩의 이펙트 — 구매/장착 전 미리보기 펫에 임시 적용. nil이면 없음. (PetEffectShelf가 콜백으로 갱신.)
    @State private var previewEffect: EffectKind? = nil
    /// 창이 안 보이면 스프라이트 프레임 루프를 멈춘다 (WindowVisibility.swift).
    @Environment(\.windowIsVisible) private var windowIsVisible
    /// Prestige 해금 시도 확인 alert.
    @State private var showPrestigeConfirm = false
    /// Prestige 시도 결과 메시지(성공/실패) — 있으면 결과 alert 표시.
    @State private var prestigeResultMessage: String? = nil

    init(kind: PetKind, variant: Int, settings: Settings) {
        self.kind = kind
        self._selectedVariant = State(initialValue: variant)
        self.settings = settings
    }

    /// 스프라이트 걷기 + 좌우 swing + 말풍선 순환 — 시간에 의존하는 부분만 모았다.
    ///
    /// 프레임률을 30fps로 묶는다. 스프라이트는 8fps로 넘어가고 swing은 4초 주기 사인이라
    /// 디스플레이 주사율(60~120Hz)로 돌 이유가 없다. 창이 보이지 않으면 아예 멈춘다.
    @ViewBuilder
    private var animatedPet: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate

            // walk strip 우선, 없으면 idle (Bee/Plant/Skull 등)
            let walkFrames = PetSprite.frames(for: kind, action: .walk)
            let frames = walkFrames.isEmpty ? PetSprite.frames(for: kind, action: .sit) : walkFrames
            let frameCycleSec: Double = 1.0
            let framePhase = t.truncatingRemainder(dividingBy: frameCycleSec) / frameCycleSec
            let frameIdx = frames.isEmpty ? 0 : Int(framePhase * 8) % frames.count
            // 좌우로 천천히 swing
            let swingPeriod: Double = 4.0
            let phase = (t.truncatingRemainder(dividingBy: swingPeriod)) / swingPeriod
            let swingX = sin(phase * 2 * .pi) * 60
            let movingRight = cos(phase * 2 * .pi) > 0
            let flip = (kind.defaultFacingLeft && movingRight) || (!kind.defaultFacingLeft && !movingRight)

            // 종 전용 대사 풀에서 5초마다 다음 라인으로 순환.
            let quotes = Quotes.perPet[kind] ?? ["..."]
            let quoteCycleSec: Double = 5.0
            let quoteIdx = Int(t / quoteCycleSec) % max(1, quotes.count)

            ZStack {
                if !frames.isEmpty {
                    // 장착 이펙트 + hover 프리뷰를 펫과 같은 고정 프레임에서 함께 렌더.
                    let fx = (settings.equippedEffects[kind] ?? [])
                        .union(previewEffect.map { [$0] } ?? [])
                    ZStack {
                        PetEffectOverlay(effects: fx, placement: .backdrop,
                                         center: CGPoint(x: 55, y: 55), footY: 95,
                                         petHeight: 70, facingRight: movingRight, isMoving: true,
                                         guildFlag: GuildLogo.myFlagImage)
                        Image(nsImage: frames[frameIdx])
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 84)
                            .scaleEffect(x: flip ? -1 : 1, y: 1)
                            .hueRotation(.degrees(selectedVariant == PetOwnership.prestigeVariant
                                ? WalkingCat.prestigeHueDegrees(at: t) : WalkingCat.hueDegrees(for: selectedVariant)))
                            .saturation(selectedVariant > 0 ? 1.15 : 1.0)
                            // Prestige는 무채색 펫에도 색이 입도록 순환 색조 곱셈(비-Prestige는 .white=무영향).
                            .colorMultiply(selectedVariant == PetOwnership.prestigeVariant
                                ? WalkingCat.prestigeTint(at: t) : .white)
                        PetEffectOverlay(effects: fx, placement: .particles,
                                         center: CGPoint(x: 55, y: 55), footY: 95,
                                         petHeight: 70, facingRight: movingRight, isMoving: true)
                    }
                    .frame(width: 110, height: 110)
                    .offset(x: swingX, y: Self.spriteRestY)
                }

                Self.bubble(quotes[quoteIdx])
                    .fixedSize()
                    .offset(y: Self.spriteRestY - 56)
                    .id(quoteIdx)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: quoteIdx)
            }
        }
    }

    /// sprite 그룹이 슬라이드 후 멈추는 x offset (center 기준).
    /// description 카드 폭(160) 대비 펫 sprite + ±60 swing 가동 범위가 겹치지 않도록 좌측으로 충분히 이동.
    private static let slideEndX: CGFloat = -120
    /// description 카드의 최종 x offset (center 기준). 슬라이드 시작 직후엔 이보다 +30 더 우측.
    private static let descEndX: CGFloat = 100
    /// description 카드 폭. 좁힐수록 펫 가동 범위와의 간격이 늘어남.
    private static let descCardWidth: CGFloat = 160
    /// 슬라이드 + 페이드인이 끝나는 시간.
    private static let slideDuration: TimeInterval = 0.55
    /// hatched/revealing 단계 sprite의 y offset (영역 center 기준).
    private static let spriteRestY: CGFloat = -38

    var body: some View {
        VStack(spacing: 4) {
        ZStack {
            // ─── 펫 그룹 (sprite + 말풍선 + 이름 + 게이지) — 좌측으로 슬라이드 ───
            ZStack {
                // 시간에 따라 실제로 바뀌는 것만 TimelineView 안에 둔다. 아래 이름/게이지/설명 카드까지
                // 감싸면 정적 콘텐츠가 매 프레임 재레이아웃돼 CPU를 통째로 태운다(실측 50%).
                animatedPet

                VStack(spacing: 4) {
                    Text(PetMetaStore.shared.displayName(for: kind))
                        .font(.title3.weight(.medium))
                    if selectedVariant == PetOwnership.prestigeVariant {
                        Text("✦ 레인보우 레어 ✦")
                            .font(.caption.weight(.semibold))
                    } else if selectedVariant > 0 {
                        Text(String(repeating: "✨", count: selectedVariant))
                            .font(.caption)
                    } else {
                        Text("기본")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    variantSelector
                    usageProgressView()
                    prestigePurchaseView()
                }
                .offset(y: 50)
            }
            .offset(x: entered ? Self.slideEndX : 0)

            // ─── 우측 캐릭터 설명 카드 — 페이드인 + slide-in ───
            descriptionCard
                .opacity(entered ? 1 : 0)
                .offset(x: entered ? Self.descEndX : Self.descEndX + 30)
        }
        .animation(.easeInOut(duration: Self.slideDuration), value: entered)
        .onAppear { entered = true }
        // 미리보기 영역 고정 높이 — 말풍선(offset -94)·이름/게이지(+50)가 ZStack frame 밖으로 삐져
        // 헤더/도감과 겹치지 않도록 충분히 확보(maxHeight .infinity는 ScrollView와 충돌해 제거).
        .frame(maxWidth: .infinity, minHeight: 230)
        // 칩 바는 미리보기 영역 밖(아래 독립 행) — 펫 슬라이드(slideX)·variant와 분리되어 잘리지 않는다.
        // 공용 PetEffectShelf 재활용. hover 프리뷰는 previewEffect로 받아 미리보기 펫에 임시 반영.
        PetEffectShelf(kind: kind, settings: settings, onPreview: { previewEffect = $0 })
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .alert("레인보우 레어 해금 시도", isPresented: $showPrestigeConfirm) {
            Button("\(PetOwnership.prestigeAttemptCost)조각으로 시도") {
                switch ShardLedger.shared.attemptPrestige(kind) {
                case .success:
                    selectedVariant = PetOwnership.prestigeVariant
                    prestigeResultMessage = "🌈 레인보우 레어 해금 성공!\n아레나 수동 연습전에서 궁극기 A·B를 선택할 수 있습니다."
                case .failure(let pity):
                    let left = PetOwnership.prestigePityCeiling - pity
                    prestigeResultMessage = left <= 1
                        ? "아쉽게 실패… 다음 시도는 천장(확정 성공)!"
                        : "아쉽게 실패… (\(pity)/\(PetOwnership.prestigePityCeiling))"
                case .notReady:
                    break
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            let pity = settings.ownedPets[kind]?.prestigeAttempts ?? 0
            Text("\(PetMetaStore.shared.displayName(for: kind))에게 레인보우 레어(무지개 홀로)를 시도합니다.\n"
                 + "비용 \(PetOwnership.prestigeAttemptCost)조각 · 성공 \(Int(PetOwnership.prestigeSuccessChance * 100))% · \(PetOwnership.prestigePityCeiling)회 천장(현재 \(pity)/\(PetOwnership.prestigePityCeiling))\n"
                 + "보유 조각: \(settings.shinyShards)")
        }
        .alert("레인보우 레어 시도 결과", isPresented: Binding(
            get: { prestigeResultMessage != nil },
            set: { if !$0 { prestigeResultMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(prestigeResultMessage ?? "")
        }
    }

    /// 우측 도감 카드 — 포켓몬 도감 톤. 컬러 헤더 (ID + 이름 + rarity 태그) + 어두운 본문 패널.
    /// 폭(160)은 펫의 ±60 swing 가동 범위와 겹치지 않게 좁게 유지.
    private var descriptionCard: some View {
        let dexNum = Self.dexNumber(for: kind)
        let r = Self.rarity(of: kind)
        let headerColor = r?.color ?? .gray

        return VStack(alignment: .leading, spacing: 0) {
            // 헤더 — rarity 색상의 띠. ID + 이름 + 등급.
            HStack(spacing: 5) {
                Text(String(format: "#%03d", dexNum))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(PetMetaStore.shared.displayName(for: kind))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                if let r {
                    Text(Self.rarityStars(r))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(headerColor)

            // 본문 — 도감 화면처럼 살짝 들어간 inset 패널 느낌. 설명 + (보유 시) 해금 스킬.
            VStack(alignment: .leading, spacing: 0) {
                Text(PetMetaStore.shared.description(for: kind))
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                skillSection   // 보유 펫이면 해금 스킬, 아니면 아무것도 안 그림.
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.10))
        }
        .frame(width: Self.descCardWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg)
                .strokeBorder(headerColor.opacity(0.55), lineWidth: 1.2)
        )
    }

    /// 이 펫이 지금까지 해금한 스킬 — **보유 펫만**, 해금한 이로치(variant) 단계까지의 스킬.
    /// 배틀과 동일하게 `max(unlockedVariants)`를 쓰고, 레인보우(4)면 궁극기까지 포함.
    private var unlockedSkills: [Skill] {
        guard let o = settings.ownedPets[kind] else { return [] }   // 미보유 펫은 빈 목록 → 섹션 미표시
        let v = o.unlockedVariants.max() ?? 0
        var out = SkillCatalog.skills(kind: kind, variant: v)
        if v >= BattleEngine.rainbowVariant { out.append(SkillCatalog.ultimate(for: kind.battleType)) }
        return out
    }

    /// 해금 스킬 섹션 — 도감 카드 본문 하단. 보유 펫이 아니면 아무것도 안 그린다("해금한 펫만").
    @ViewBuilder
    private var skillSection: some View {
        let skills = unlockedSkills
        if !skills.isEmpty {
            Divider().padding(.horizontal, 9)
            VStack(alignment: .leading, spacing: 4) {
                Text("해금 스킬").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                ForEach(skills, id: \.id) { skillDexRow($0) }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // 스킬 한 줄 — 타입 색 점 · 이름 / (타입 · 티어) · 위력. 좁은 카드(160)라 컴팩트.
    private func skillDexRow(_ s: Skill) -> some View {
        HStack(spacing: 5) {
            Circle().fill(Self.typeColor(s.type)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(s.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1)
                Text("\(s.type.displayName) · \(Self.tierLabel(s.tier))")
                    .font(.system(size: 7)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 2)
            Text("\(Int(s.power))").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
        }
    }

    /// 스킬 티어 → 한글 라벨(해금 경로 감각). ArenaView.typeColor 와 동일 매핑을 로컬로 둔다(뷰 분리).
    private static func tierLabel(_ t: SkillTier) -> String {
        switch t {
        case .generic:          return "기본"
        case .typeShared:       return "타입 · 이로치1"
        case .collectionShared: return "오프타입 · 이로치2"
        case .unique:           return "고유기 · 이로치3"
        case .ultimate:         return "궁극기 · 충전"
        }
    }
    private static func typeColor(_ t: BattleType) -> Color {
        switch t {
        case .beast:   return .green
        case .warrior: return .red
        case .arcane:  return .purple
        case .chaos:   return .indigo
        case .machine: return .cyan
        case .mascot:  return .pink
        }
    }

    /// 도감 ID — `PetKind.allCases` 순서를 그대로 dex 번호로 사용. 새 펫이 enum 끝에 추가되면
    /// 자연스럽게 다음 번호를 받음 (포켓몬 도감처럼 #001부터 1-based).
    private static func dexNumber(for kind: PetKind) -> Int {
        (PetKind.allCases.firstIndex(of: kind) ?? 0) + 1
    }

    /// 펫이 속한 rarity 조회. `Gacha.pool`에서 역방향 검색.
    private static func rarity(of kind: PetKind) -> Rarity? {
        for tier in [Rarity.mythic, .legendary, .epic, .rare, .common] {
            if (Gacha.pool[tier] ?? []).contains(kind) { return tier }
        }
        return nil
    }

    /// rarity → 별 카운트. 헤더 우측에 컴팩트한 등급 표시로 사용 (LEGENDARY 줄바꿈 회피).
    private static func rarityStars(_ r: Rarity) -> String {
        switch r {
        case .common:    return "★"
        case .rare:      return "★★"
        case .epic:      return "★★★"
        case .legendary: return "★★★★"
        case .mythic:    return "★★★★★"
        }
    }

    /// 해금된 variant들 사이 토글 selector — dot 4개. 잠긴 dot은 회색 + 클릭 X.
    /// 현재 선택된 dot은 외곽 stroke로 강조.
    @ViewBuilder
    private var variantSelector: some View {
        let unlocked = settings.ownedPets[kind]?.unlockedVariants ?? []
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                let isUnlocked = unlocked.contains(i)
                let isSelected = selectedVariant == i
                Circle()
                    .fill(isUnlocked ? Self.variantDotColor(i) : Color.secondary.opacity(0.2))
                    .frame(width: 12, height: 12)
                    .overlay(
                        Circle().strokeBorder(
                            isSelected ? Color.primary : Color.clear,
                            lineWidth: 1.5
                        )
                    )
                    .contentShape(Circle())
                    .onTapGesture {
                        if isUnlocked { selectedVariant = i }
                    }
                    .help(isUnlocked
                          ? (i == 0 ? "기본" : "이로치 \(i)")
                          : "잠김 — 가챠 중복 또는 사용 시간으로 해금")
            }
            // Prestige 도트 — 보유 시에만. 무지개 링(정적)으로 홀로 티어 표시.
            if unlocked.contains(PetOwnership.prestigeVariant) {
                let isSelected = selectedVariant == PetOwnership.prestigeVariant
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red]),
                        center: .center))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(isSelected ? Color.primary : Color.clear, lineWidth: 1.5))
                    .contentShape(Circle())
                    .onTapGesture { selectedVariant = PetOwnership.prestigeVariant }
                    .help("레인보우 레어 — 무지개 홀로")
            }
        }
        .padding(.top, 2)
    }

    /// variant dot 색 — WalkingCat.variantDotColor 단일 정의에 위임 (시각적 일관성).
    private static func variantDotColor(_ i: Int) -> Color { WalkingCat.variantDotColor(i) }

    /// 합산 진행도(가챠 중복 + 사용 시간) 기반 "다음 이로치까지" 게이지. 모든 variant 해금되면 표시 안 함.
    /// 잔여 표기는 "사용 시간 단독"으로 채울 경우 남는 일수 — 가챠로 더 빨리 해금 가능.
    @ViewBuilder
    private func usageProgressView() -> some View {
        let owned = settings.ownedPets[kind]
        let usageSec = settings.petUsageSeconds[kind] ?? 0
        let count = owned?.count ?? 0
        let unlocked = owned?.unlockedVariants ?? []
        if let next = PetOwnership.variantUnitThresholds.first(where: { !unlocked.contains($0.1) }) {
            let prevUnits: Double = {
                guard let idx = PetOwnership.variantUnitThresholds.firstIndex(where: { $0.1 == next.1 }),
                      idx > 0
                else { return 0 }
                return PetOwnership.variantUnitThresholds[idx - 1].0
            }()
            let units = PetOwnership.progressUnits(count: count, usageSeconds: usageSec)
            let span = max(0.001, next.0 - prevUnits)
            let progress = max(0, min(1, (units - prevUnits) / span))
            // 잔여 unit을 사용 시간(초)으로 환산 — 가챠 안 돌리고 시간만 쌓을 때 기준 잔여시간.
            let remainingUnits = max(0, next.0 - units)
            let remainingSeconds = remainingUnits / PetOwnership.secondUnit
            VStack(spacing: 3) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 160)
                    .tint(.purple)
                Text("다음 이로치까지 \(Self.formatRemaining(remainingSeconds))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }

    /// 만렙(variant 3) + 레인보우 레어 미보유일 때만 노출되는 해금 시도 버튼(가챠식).
    /// 버튼 배경이 천장 진행도(pity)만큼 좌→우로 차오른다.
    @ViewBuilder
    private func prestigePurchaseView() -> some View {
        let owned = settings.ownedPets[kind]
        let maxed = owned?.unlockedVariants.contains(3) == true
        let hasPrestige = owned?.unlockedVariants.contains(PetOwnership.prestigeVariant) == true
        if maxed && !hasPrestige {
            let cost = PetOwnership.prestigeAttemptCost
            let affordable = settings.shinyShards >= cost
            let pity = owned?.prestigeAttempts ?? 0
            let atPity = pity + 1 >= PetOwnership.prestigePityCeiling   // 이번 시도가 천장(확정)
            // 천장 진행도 0…1 — pity 9면 다음 시도가 확정이라 가득 참.
            let fill = min(1.0, Double(pity) / Double(max(1, PetOwnership.prestigePityCeiling - 1)))
            Button {
                showPrestigeConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hexagon.fill").font(.system(size: 9))
                    Text("레인보우 레어 · \(cost)")
                        .font(.caption.weight(.semibold))
                    Text("(\(pity)/\(PetOwnership.prestigePityCeiling))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(affordable ? (atPity ? .orange : .pink) : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.secondary.opacity(0.12)
                            (atPity ? Color.orange : Color.pink).opacity(0.28)
                                .frame(width: geo.size.width * fill)
                        }
                    }
                    .clipShape(Capsule())
                )
            }
            .buttonStyle(.plain)
            .disabled(!affordable)
            .help(affordable
                  ? "조각 \(cost)로 레인보우 레어 해금 시도 (성공 \(Int(PetOwnership.prestigeSuccessChance * 100))%\(atPity ? " · 이번 시도 확정!" : " · \(PetOwnership.prestigePityCeiling)회 천장"))"
                  : "이로치 조각 부족 (보유 \(settings.shinyShards) / \(cost))")
            .padding(.top, 3)
        }
    }

    /// 말풍선 외형 — WalkingCat의 quote bubble과 동일하게 매칭.
    private static func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.md)
                    .stroke(Color.black.opacity(0.7), lineWidth: 0.6)
            )
    }

    private static func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(max(1, m))m"
    }

    /// 표준 easeInOut 곡선 — slideX 와 description fade 모두 동일 곡선을 공유해 같은 페이싱을 갖는다.
    private static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}

@MainActor
final class GachaWindowController: NSWindowController, SingleWindowPresenting {
    static let shared = GachaWindowController()

    private var navigation: TrainerNavigation!

    private convenience init() {
        let navigation = TrainerNavigation()
        // 닫아도 창·hosting controller가 살아남는 구조(isReleasedWhenClosed = false + 싱글턴)라,
        // 감싸주지 않으면 닫힌 창의 TimelineView가 계속 프레임을 돈다. WindowVisibility.swift 참조.
        let host = NSHostingController(rootView: GachaView(navigation: navigation).pauseAnimationsWhenHidden())
        let window = NSWindow(contentViewController: host)
        window.title = "트레이너 메뉴"
        // resizable — 고정 560×640이던 시절엔 콘텐츠가 창보다 길어져도 사용자가 늘릴 방법이
        // 없어 그대로 잘렸다(도장 vibe 지역의 3번째 카테고리, 대련 시트 하단이 그랬다).
        // 각 탭은 최상위 ScrollView라 잘림 자체는 막혀 있지만, 넓게 쓰고 싶은 사용자에게
        // 선택지를 준다.
        // 게시판·쪽지·퀴즈 창과 같은 조합(board/dm/quiz 컨트롤러 참조).
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 640))
        // 아래로는 줄이지 못하게 — 640 미만에선 도장·레포트가 스크롤에 갇혀 쓰기 나빠진다.
        // 다른 창들이 쓰는 `minSize`(타이틀바 포함 프레임 기준) 대신 `contentMinSize`를 쓰는 건
        // 위 SwiftUI `.frame(minHeight: 640)`과 같은 축으로 맞추기 위해서다.
        window.contentMinSize = NSSize(width: 560, height: 640)
        window.center()
        self.init(window: window)
        self.navigation = navigation
        // 사용자가 늘린 크기·위치를 다음 실행에도 유지. center() 뒤에 걸어야 저장값이 우선한다.
        window.setFrameAutosaveName("GachaWindow")
    }

    /// 윈도우를 띄우면서 특정 탭으로 전환. `tab=nil`이면 마지막 선택 상태 유지.
    func present(tab: GachaView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        bringToFront()
    }
}

final class TrainerNavigation: ObservableObject {
    @Published var tab: GachaView.Tab = .shop
}
