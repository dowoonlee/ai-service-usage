import SwiftUI

// 펫 종합 관리 페이지 (가챠 "파티" 탭). 멀티 산책 편성 + 코스메틱 관리 + 기존 펫 설정 통합.
// cf. docs/DESIGN_PET_PARTY.md
//
// 구성:
//   - Claude/Cursor 파티 섹션: 표시 토글 + 테마 + 슬롯(최대 3, 서로 다른 종) + 선택 슬롯 이펙트/이로치
//   - 공통: 펫 반응 강도 + 메뉴바 펫
@MainActor
struct PartyView: View {
    @ObservedObject var settings = Settings.shared
    /// 이펙트/이로치 관리 대상으로 펼친 슬롯의 종. nil = 미선택.
    @State private var selected: PetKind? = nil
    /// 펫 추가 시트 대상 (true=Claude, false=Cursor, nil=닫힘).
    @State private var addingClaude: Bool? = nil
    /// 추가 시트 펫 정렬 기준.
    @State private var sortOrder: PetSortOrder = .dex
    /// 맵 상점 구매 확인 alert 대상. nil = 닫힘.
    @State private var pendingThemePurchase: PetTheme? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                partySection(claude: true)
                Divider()
                partySection(claude: false)
                Divider()
                mapShopSection
                Divider()
                commonSettings
            }
            .padding(16)
        }
        .sheet(isPresented: Binding(
            get: { addingClaude != nil },
            set: { if !$0 { addingClaude = nil } }
        )) {
            if let claude = addingClaude { addSheet(claude: claude) }
        }
        .alert(
            pendingThemePurchase.map { "\($0.displayName) 맵 구매" } ?? "",
            isPresented: Binding(
                get: { pendingThemePurchase != nil },
                set: { if !$0 { pendingThemePurchase = nil } }
            ),
            presenting: pendingThemePurchase
        ) { theme in
            Button("\(theme.price) coin 으로 구매") {
                _ = CoinLedger.shared.purchaseTheme(theme)
            }
            Button("취소", role: .cancel) {}
        } message: { theme in
            Text("'\(theme.displayName)' 맵을 구매하시겠습니까?\n현재 잔액: \(settings.coins.formatted()) coin → 구매 후 \((settings.coins - theme.price).formatted()) coin")
        }
    }

    // MARK: - 맵 상점

    // 동적 맵(테마) 구매 섹션. ownedThemes는 글로벌 — 한 번 사면 Claude·Cursor 양쪽 적용 가능.
    private var mapShopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("맵 상점")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(settings.coins.formatted()) coin")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text("동적 맵은 사용량에 따라 색이 차오릅니다. 구매하면 위 테마 선택에 추가됩니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(PetTheme.allCases.filter { $0.isDynamic }) { theme in
                    mapCard(theme)
                }
            }
        }
    }

    @ViewBuilder
    private func mapCard(_ theme: PetTheme) -> some View {
        let owned = settings.isThemeUnlocked(theme)
        let canBuy = !owned && settings.coins >= theme.price
        Button {
            if canBuy { pendingThemePurchase = theme }
        } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 6)
                    // 동적 맵 미리보기 — 적당히 차오른 상태(pct 75, 임계값 30%).
                    .fill(theme.gradient(pct: 75, threshold: 0.30))
                    .frame(height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(theme.lineColor.opacity(0.6), lineWidth: 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        Image(systemName: owned ? "checkmark.seal.fill" : "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(owned ? .green : .white.opacity(0.85))
                            .padding(3)
                    }
                Text(theme.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                if owned {
                    Text("보유")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                } else {
                    Text("\(theme.price) coin")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(canBuy ? .orange : .secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canBuy)
        .opacity(owned || canBuy ? 1.0 : 0.5)
    }

    // MARK: - 파티 섹션

    @ViewBuilder
    private func partySection(claude: Bool) -> some View {
        let party = claude ? settings.petClaudeParty : settings.petCursorParty
        let enabledBinding: Binding<Bool> = claude ? $settings.petClaudeEnabled : $settings.petCursorEnabled

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(claude ? "Claude 차트에 펫 표시" : "Cursor 차트에 펫 표시", isOn: enabledBinding)
                    .font(.system(size: 12, weight: .semibold))
                    .toggleStyle(.switch)
                Spacer()
                themePicker(claude: claude)
            }

            if settings.ownedPets.isEmpty {
                Text("아직 보유한 펫이 없습니다. 가챠를 돌려 펫을 모으세요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(party.enumerated()), id: \.element.kind) { idx, sel in
                        slotView(sel: sel, idx: idx, claude: claude)
                    }
                    if party.count < Settings.maxPartySize {
                        addButton(claude: claude)
                    }
                }
                // 선택된 슬롯이 이 파티 멤버면 이펙트/이로치 패널.
                if let kind = selected, let sel = party.first(where: { $0.kind == kind }) {
                    effectPanel(sel: sel, claude: claude)
                }
            }
        }
    }

    /// 파티 슬롯 — 펫 썸네일 + 이름 + 제거/이동 버튼. 클릭 시 이펙트 패널 토글.
    private func slotView(sel: PetSelection, idx: Int, claude: Bool) -> some View {
        let isSelected = selected == sel.kind
        let party = claude ? settings.petClaudeParty : settings.petCursorParty
        return VStack(spacing: 2) {
            thumbnail(sel, height: 30)
            Text(PetMetaStore.shared.displayName(for: sel.kind))
                .font(.system(size: 8)).lineLimit(1)
            // 순서 이동(◀▶) — 리더(idx 0)는 메뉴바/wellness 대표.
            HStack(spacing: 6) {
                Button { settings.movePartyMember(claude: claude, from: idx, to: idx - 1) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 8))
                }.buttonStyle(.plain).disabled(idx == 0).opacity(idx == 0 ? 0.25 : 1)
                Button { settings.movePartyMember(claude: claude, from: idx, to: idx + 1) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }.buttonStyle(.plain).disabled(idx == party.count - 1).opacity(idx == party.count - 1 ? 0.25 : 1)
            }
        }
        .frame(width: 60, height: 66)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor : (idx == 0 ? Color.yellow.opacity(0.5) : .clear), lineWidth: 1.2))
        .overlay(alignment: .topTrailing) {
            Button { remove(sel.kind, claude: claude) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).offset(x: 4, y: -4)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = isSelected ? nil : sel.kind }
        .help(idx == 0 ? "리더 (메뉴바·wellness 대표)" : "")
    }

    private func addButton(claude: Bool) -> some View {
        Button { addingClaude = claude } label: {
            VStack(spacing: 3) {
                Image(systemName: "plus").font(.system(size: 16))
                Text("추가").font(.system(size: 8))
            }
            .foregroundStyle(.secondary)
            .frame(width: 60, height: 66)
            .background(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3]))
                .foregroundStyle(.secondary.opacity(0.4)))
        }.buttonStyle(.plain)
    }

    /// 선택 슬롯의 이펙트(PetEffectShelf 공용) + 해금 이로치 토글.
    private func effectPanel(sel: PetSelection, claude: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(PetMetaStore.shared.displayName(for: sel.kind)) 코스메틱")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                variantToggle(sel: sel, claude: claude)
            }
            PetEffectShelf(kind: sel.kind, settings: settings)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    /// 해금된 이로치(variant) dot 토글. 잠긴 건 미표시.
    private func variantToggle(sel: PetSelection, claude: Bool) -> some View {
        let unlocked = settings.ownedPets[sel.kind]?.unlockedVariants ?? [0]
        return HStack(spacing: 5) {
            ForEach([0, 1, 2, 3].filter { unlocked.contains($0) }, id: \.self) { v in
                Circle()
                    .fill(variantColor(v))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(sel.variant == v ? Color.primary : .clear, lineWidth: 1.5))
                    .onTapGesture { settings.setPartyVariant(claude: claude, kind: sel.kind, variant: v) }
            }
        }
    }

    // MARK: - 추가 시트

    private func addSheet(claude: Bool) -> some View {
        let party = claude ? settings.petClaudeParty : settings.petCursorParty
        let partyKinds = Set(party.map { $0.kind })
        let available = sortedAvailable(Array(settings.ownedPets.keys).filter { !partyKinds.contains($0) })
        return VStack(spacing: 10) {
            Text(claude ? "Claude 파티에 추가" : "Cursor 파티에 추가").font(.headline)
            Picker("정렬", selection: $sortOrder) {
                ForEach(PetSortOrder.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if available.isEmpty {
                Text("추가할 수 있는 펫이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
                        ForEach(available, id: \.self) { kind in
                            Button {
                                settings.addToParty(claude: claude, PetSelection(kind: kind, variant: 0))
                                addingClaude = nil
                            } label: {
                                VStack(spacing: 2) {
                                    thumbnail(PetSelection(kind: kind, variant: 0), height: 30)
                                    Text(PetMetaStore.shared.displayName(for: kind))
                                        .font(.system(size: 8)).lineLimit(1)
                                }
                                .frame(width: 60, height: 56)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
            }
            Button("닫기") { addingClaude = nil }
        }
        .frame(width: 380, height: 420)
        .padding(16)
    }

    // MARK: - 공통 설정

    private var commonSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("펫 반응 강도").font(.system(size: 12))
                    Slider(value: $settings.bigDropThreshold, in: 0.10...0.80, step: 0.05)
                }
                Text("차트가 크게 움직일 때 펫이 얼마나 자주 반응할지.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if settings.showMenuBar {
                Picker("메뉴바에 표시할 펫", selection: $settings.menuBarPetSource) {
                    ForEach(MenuBarPetSource.allCases) { src in
                        Text(src.displayName).tag(src)
                    }
                }
            }
        }
    }

    // MARK: - 헬퍼

    @ViewBuilder
    private func thumbnail(_ sel: PetSelection, height: CGFloat) -> some View {
        if let img = PetSprite.frames(for: sel.kind, action: .walk).first
            ?? PetSprite.frames(for: sel.kind, action: .sit).first {
            Image(nsImage: img)
                .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                .frame(height: height)
                .hueRotation(.degrees(WalkingCat.hueDegrees(for: sel.variant)))
                .saturation(sel.variant > 0 ? 1.15 : 1.0)
        } else {
            Image(systemName: "pawprint").font(.system(size: height * 0.7)).foregroundStyle(.secondary)
        }
    }

    private func remove(_ kind: PetKind, claude: Bool) {
        if selected == kind { selected = nil }
        settings.removeFromParty(claude: claude, kind: kind)
    }

    /// 추가 시트 펫 목록을 `sortOrder` 기준으로 정렬.
    private func sortedAvailable(_ kinds: [PetKind]) -> [PetKind] {
        switch sortOrder {
        case .dex:
            return kinds.sorted { $0.dexIndex < $1.dexIndex }
        case .name:
            return kinds.sorted {
                PetMetaStore.shared.displayName(for: $0)
                    .localizedCompare(PetMetaStore.shared.displayName(for: $1)) == .orderedAscending
            }
        case .rarity:
            // 희귀도 내림차순(Legendary 먼저), 동률은 도감순.
            func rank(_ k: PetKind) -> Int {
                guard let r = PetKind.rarityFor(k) else { return -1 }
                return Rarity.allCases.firstIndex(of: r) ?? 0
            }
            return kinds.sorted {
                let a = rank($0), b = rank($1)
                return a != b ? a > b : $0.dexIndex < $1.dexIndex
            }
        }
    }

    private func themePicker(claude: Bool) -> some View {
        let binding: Binding<PetTheme?> = claude ? $settings.themeClaudeOverride : $settings.themeCursorOverride
        let leaderKind = claude ? settings.petClaudeKind : settings.petCursorKind
        return Picker("테마", selection: binding) {
            Text("기본 (\(PetTheme.defaultFor(leaderKind).displayName))").tag(PetTheme?.none)
            // 보유한 테마만 적용 가능 — 미보유 동적 맵은 아래 "맵 상점"에서 구매.
            ForEach(PetTheme.allCases.filter { settings.isThemeUnlocked($0) }) { t in
                Text(t.displayName).tag(PetTheme?.some(t))
            }
        }
        .labelsHidden()
        .frame(width: 130)
    }

    private func variantColor(_ v: Int) -> Color {
        switch v {
        case 1:  return .yellow
        case 2:  return .orange
        case 3:  return .purple
        default: return .gray
        }
    }
}

private extension PetKind {
    /// 도감 순서 — `allCases` 인덱스. 추가 시트 정렬용.
    var dexIndex: Int { PetKind.allCases.firstIndex(of: self) ?? 0 }
}

/// 파티 추가 시트의 펫 정렬 기준.
enum PetSortOrder: String, CaseIterable, Identifiable {
    case dex, rarity, name
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .dex:    return "도감순"
        case .rarity: return "희귀도순"
        case .name:   return "이름순"
        }
    }
}
