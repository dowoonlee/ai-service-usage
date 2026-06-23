import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// "리포트" 탭 — 트레이너 카드 미리보기 + customization + 공유.
///
/// 좌상단 카드 미리보기 (압축 표시) → 아래 customization 섹션들 → 마지막 공유 버튼 row.
/// 가챠 탭 컨테이너(`width: 480`) 안에 들어가므로 카드는 0.85 scale로 압축, 공유 export 시엔
/// `TrainerCardView.standardWidth`로 캡처.
///
/// `@MainActor` 명시 — `Settings` 직접 접근 + MainActor 격리 enum의 unlock/compute 호출.
/// `TrainerCardView`와 동일 이유 (CI strict concurrency).
@MainActor
struct ReportView: View {
    @ObservedObject var settings = Settings.shared

    /// 호버된 칭호/프레임 — popover 트리거 single-track. 한 번에 하나만 popover 노출.
    @State private var hoveringTitle: CardTitle?
    @State private var hoveringFrame: CardFrame?
    /// 액세서리 구매 확인 alert 트리거. 사용자가 미보유 액세서리를 클릭하면 즉시 차감
    /// 대신 이 state를 set → alert으로 yes/no 받음.
    @State private var pendingAccessoryPurchase: CardAccessory?

    /// 미리보기에서 카드 폭. 컨테이너(480) 안에 패딩 포함.
    private static let previewWidth: CGFloat = 440

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cardPreview
                customizationGroups
                shareSection
            }
            .padding(16)
        }
        .alert(
            pendingAccessoryPurchase.map { "\($0.displayName) 구매" } ?? "",
            isPresented: Binding(
                get: { pendingAccessoryPurchase != nil },
                set: { if !$0 { pendingAccessoryPurchase = nil } }
            ),
            presenting: pendingAccessoryPurchase
        ) { acc in
            Button("\(acc.price) coin 으로 구매") {
                guard settings.coins >= acc.price else { return }
                settings.coins -= acc.price
                settings.ownedAccessories.insert(acc.rawValue)
                settings.trainerCard.accessory = acc
            }
            Button("취소", role: .cancel) {}
        } message: { acc in
            Text("이 액세서리를 구매하시겠습니까?\n현재 잔액: \(settings.coins.formatted()) coin → 구매 후 \((settings.coins - acc.price).formatted()) coin")
        }
    }

    // MARK: - Card preview

    private var cardPreview: some View {
        HStack {
            Spacer()
            TrainerCardView(
                card: settings.trainerCard,
                trainerID: settings.trainerID,
                trainerName: displayName,
                stats: TrainerStats.compute(from: settings),
                badges: badgeRows,
                collections: collectionRows,
                showWatermark: true,
                width: Self.previewWidth,
                accessoryEditing: accessoryTransformBinding,
                medals: settings.medalTally,
                animatedAvatar: true,
                equippedEffects: settings.equippedEffects[settings.trainerCard.avatar.kind] ?? []
            )
            Spacer()
        }
    }

    /// 액세서리 transform 편집 binding — 카드 sprite drag로 위치 변경 + sidebar slider로 scale.
    /// nil-coalescing은 effective default로 fallback해 첫 launch에서 자연스러운 시작 위치
    /// (펫 머리 위, 50px)부터 조작 가능.
    private var accessoryTransformBinding: Binding<AccessoryTransform> {
        Binding(
            get: { settings.trainerCard.effectiveAccessoryTransform },
            set: { settings.trainerCard.accessoryTransform = $0 }
        )
    }

    // MARK: - Customization

    private var customizationGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("아바타")
            avatarRow
            sectionHeader("배경")
            backgroundRow
            sectionHeader("프레임")
            frameRow
            sectionHeader("칭호")
            titleRow
            sectionHeader("액세서리")
            accessoryRow
            if settings.trainerCard.accessory != nil {
                accessoryAdjustRow
            }
            sectionHeader("공유 설정")
            shareSettingsRow
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    // MARK: - Avatar (보유 펫 + variant)

    // 한 줄 가로 스크롤이면 보유 펫이 늘수록 끝없이 옆으로 늘어나 선택이 어려워서
    // 희귀도별 그룹으로 줄바꿈해 표시. 등급마다 라벨 + 별도 그리드 → 등급 경계에서 줄바꿈.
    // (kind, variant) 쌍을 평탄화하되 같은 펫의 variant는 인접 유지.
    // 컬렉터처럼 보유가 많을 때 아래 섹션을 밀어내지 않도록 높이를 캡한 내부 스크롤로 감싼다.
    private var avatarRow: some View {
        let owned = settings.ownedPets.keys
        // 등급별(Legendary→Common) 그룹. 보유한 등급만 노출.
        let grouped: [(rarity: Rarity, choices: [PetSelection])] = Rarity.allCases.reversed().compactMap { rarity in
            let kinds = owned
                .filter { PetKind.rarityFor($0) == rarity }
                .sorted { (PetKind.allCases.firstIndex(of: $0) ?? 0) < (PetKind.allCases.firstIndex(of: $1) ?? 0) }
            guard !kinds.isEmpty else { return nil }
            let choices = kinds.flatMap { kind in
                (settings.ownedPets[kind]?.unlockedVariants ?? [0]).sorted()
                    .map { PetSelection(kind: kind, variant: $0) }
            }
            return (rarity, choices)
        }
        let columns = [GridItem(.adaptive(minimum: 40, maximum: 44), spacing: 6, alignment: .leading)]
        return Group {
            if grouped.isEmpty {
                Text("가챠로 펫을 뽑아 아바타를 선택하세요")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(grouped, id: \.rarity) { group in
                            Text(group.rarity.displayName)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(group.rarity.color)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                                ForEach(group.choices, id: \.self) { sel in
                                    avatarChoice(kind: sel.kind, variant: sel.variant)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 200)   // 더 많으면 내부 스크롤
            }
        }
    }

    private func avatarChoice(kind: PetKind, variant v: Int) -> some View {
        let isSelected = (settings.trainerCard.avatar.kind == kind && settings.trainerCard.avatar.variant == v)
        return Button {
            settings.trainerCard.avatar = PetSelection(kind: kind, variant: v)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.10))
                if let img = PetSprite.image(for: kind, action: .sit, frameIndex: 0) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                        .hueRotation(.degrees(WalkingCat.hueDegrees(for: v)))
                        .saturation(v > 0 ? 1.15 : 1.0)
                }
            }
            .frame(width: 36, height: 36)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help("\(PetMetaStore.shared.displayName(for: kind))\(v > 0 ? " · 색상\(v)" : "")")
    }

    // MARK: - Background

    private var backgroundRow: some View {
        let opts = TrainerBackground.unlocked(in: settings)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(opts.enumerated()), id: \.offset) { (_, bg) in
                    let isSelected = settings.trainerCard.background == bg
                    Button {
                        settings.trainerCard.background = bg
                    } label: {
                        VStack(spacing: 2) {
                            LinearGradient(
                                colors: [bg.fillTopColor, bg.fillBottomColor],
                                startPoint: .top, endPoint: .bottom
                            )
                            .frame(width: 38, height: 28)
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                            )
                            Text(bg.displayName)
                                .font(.system(size: 8))
                                .lineLimit(1)
                                .frame(width: 50)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Frame

    private var frameRow: some View {
        let unlocked = CardFrame.unlocked(in: settings)
        return HStack(spacing: 8) {
            ForEach(CardFrame.allCases, id: \.self) { f in
                frameCell(f, available: unlocked.contains(f))
            }
        }
    }

    private func frameCell(_ f: CardFrame, available: Bool) -> some View {
        let isSelected = settings.trainerCard.frame == f
        return Button {
            if available { settings.trainerCard.frame = f }
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    // 프레임 미리보기 — 실제 frame과 같은 stroke·color·lineWidth.
                    // fill로 hit test 영역을 명시 — stroke만으로는 클릭 영역이 라인 자체로
                    // 한정돼 사용자 클릭이 종종 빗나감.
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.black.opacity(0.001)) // hit-target 확보
                        .frame(width: 44, height: 32)
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(f.color, lineWidth: f.lineWidth)
                        .frame(width: 44, height: 32)
                    if !available {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if isSelected {
                        // 선택 표시는 frame 안 가운데 ✓ — 외곽선에 추가 stroke 안 그림.
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(Color(NSColor.windowBackgroundColor)).padding(2))
                    }
                }
                Text(f.displayName)
                    .font(.system(size: 9))
                    .foregroundStyle(available ? .primary : .secondary)
            }
            .opacity(available ? 1.0 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .onHover { hovering in
            hoveringFrame = hovering ? f : (hoveringFrame == f ? nil : hoveringFrame)
        }
        .popover(isPresented: Binding(
            get: { hoveringFrame == f },
            set: { isPresented in
                if !isPresented, hoveringFrame == f { hoveringFrame = nil }
            }
        ), arrowEdge: .top) {
            unlockTooltip(title: f.displayName, description: f.unlockDescription, unlocked: available)
        }
    }

    // MARK: - Title

    private var titleRow: some View {
        let unlocked = CardTitle.unlocked(in: settings)
        // 보유(unlocked) 칭호를 먼저, 잠긴 것을 뒤로 — 사용자가 즉시 사용 가능한 옵션부터 노출.
        // 각 그룹 내에선 enum 정의 순서 유지(filter는 stable).
        let ordered = CardTitle.allCases.filter { unlocked.contains($0) }
                    + CardTitle.allCases.filter { !unlocked.contains($0) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ordered, id: \.self) { t in
                    titleCell(t, available: unlocked.contains(t))
                }
            }
        }
    }

    private func titleCell(_ t: CardTitle, available: Bool) -> some View {
        let isSelected = settings.trainerCard.title == t
        let canPurchase = !available && t.purchasePrice != nil
        return Button {
            if available {
                settings.trainerCard.title = t
            } else if canPurchase, let price = t.purchasePrice, settings.coins >= price {
                // 코인 차감 + 인벤토리 등록 → 자동 unlock 평가에 포함됨.
                settings.coins -= price
                settings.ownedTitles.insert(t.rawValue)
                settings.trainerCard.title = t
            }
        } label: {
            Text(t.displayName)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule().fill(
                        isSelected ? Color.accentColor.opacity(0.30)
                        : (available ? Color.secondary.opacity(0.15) : Color.gray.opacity(0.10))
                    )
                )
                .overlay(
                    Capsule().stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .foregroundStyle(available ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(!available && !canPurchase)
        .onHover { hovering in
            hoveringTitle = hovering ? t : (hoveringTitle == t ? nil : hoveringTitle)
        }
        .popover(isPresented: Binding(
            get: { hoveringTitle == t },
            set: { isPresented in
                if !isPresented, hoveringTitle == t { hoveringTitle = nil }
            }
        ), arrowEdge: .top) {
            unlockTooltip(title: t.displayName, description: t.unlockDescription, unlocked: available)
        }
    }

    /// 칭호/프레임 호버 popover 공통 — 이름 + unlock 조건 + 잠금 상태 표시.
    @ViewBuilder
    private func unlockTooltip(title: String, description: String, unlocked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: unlocked ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundStyle(unlocked ? .green : .secondary)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            Divider()
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !unlocked {
                Text("아직 unlock 안 됨")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }

    // MARK: - Accessory

    private var accessoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                accessoryChoice(nil)
                ForEach(CardAccessory.allCases, id: \.self) { acc in
                    accessoryChoice(acc)
                }
            }
        }
    }

    @ViewBuilder
    private func accessoryChoice(_ acc: CardAccessory?) -> some View {
        let isSelected = settings.trainerCard.accessory == acc
        let owned = acc.map { settings.ownedAccessories.contains($0.rawValue) } ?? true
        let canPurchase = !owned && acc != nil
        Button {
            if owned {
                settings.trainerCard.accessory = acc
            } else if canPurchase, let a = acc, settings.coins >= a.price {
                // 즉시 차감 대신 confirmation alert — 실수 클릭 방지.
                pendingAccessoryPurchase = a
            }
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.10))
                        .frame(width: 38, height: 38)
                    if let acc = acc {
                        if let img = PetSprite.image(named: acc.resourceName) {
                            Image(nsImage: img).resizable().interpolation(.none)
                                .aspectRatio(contentMode: .fit).padding(4)
                        } else {
                            Image(systemName: acc.fallbackSymbol)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(owned ? .primary : .secondary)
                        }
                        if !owned {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .background(Circle().fill(Color.black.opacity(0.5)).padding(-2))
                                .offset(x: 12, y: -12)
                        }
                    } else {
                        Image(systemName: "nosign")
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )
                Text(acc?.displayName ?? "없음")
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .frame(width: 50)
                if let acc = acc, !owned {
                    Text("\(acc.price) coin")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!owned && !canPurchase)
    }

    // MARK: - Accessory adjust (위치는 카드 위 drag, 크기는 slider)

    private var accessoryAdjustRow: some View {
        let binding = accessoryTransformBinding
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("카드의 액세서리를 마우스로 끌어 위치 조정")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("크기")
                    .font(.caption)
                    .frame(width: 30, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { binding.wrappedValue.scale },
                        set: { var t = binding.wrappedValue; t.scale = $0; binding.wrappedValue = t }
                    ),
                    in: AccessoryTransform.scaleRange
                )
                .frame(width: 200)
                Text(String(format: "%.2f×", binding.wrappedValue.scale))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40)
                Button("초기화") {
                    settings.trainerCard.accessoryTransform = .default
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
    }

    // MARK: - Share settings

    private var shareSettingsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("카드에 GitHub username 표시", isOn: $settings.showGitHubLoginInCard)
                .font(.caption)
                .disabled(settings.githubLogin == nil)
            if settings.githubLogin == nil {
                Text("GitHub 미연결 상태 — Settings에서 연결 시 활성화")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Share section (Phase D에서 채움)

    private var shareSection: some View {
        HStack(spacing: 8) {
            Button {
                copyCardToPasteboard()
            } label: {
                Label("클립보드 복사", systemImage: "doc.on.doc")
            }
            Button {
                saveCardToFile()
            } label: {
                Label("이미지로 저장", systemImage: "square.and.arrow.down")
            }
            Button {
                shareCard()
            } label: {
                Label("공유...", systemImage: "square.and.arrow.up")
            }
            Divider().frame(height: 16)
            // 움직이는 GIF — avatar walk 사이클을 애니메이션으로 내보낸다.
            Button {
                saveGIFToFile()
            } label: {
                Label("GIF 저장", systemImage: "square.and.arrow.down.on.square")
            }
            Button {
                shareGIF()
            } label: {
                Label("GIF 공유", systemImage: "square.and.arrow.up.on.square")
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Trainer name fallback chain

    private var displayName: String {
        if settings.showGitHubLoginInCard, let login = settings.githubLogin, !login.isEmpty {
            return login
        }
        // GitHub 미연결이거나 표시 토글 off — 디바이스 username으로 fallback.
        let fullName = NSFullUserName()
        return fullName.isEmpty ? NSUserName() : fullName
    }

    // MARK: - Stats helpers

    private var badgeRows: [TrainerCardView.BadgeRow] {
        BadgeCategory.allCases.map { cat in
            let cleared = BadgeTier.allCases.contains { tier in
                settings.clearedBadges.contains(BadgeID(category: cat, tier: tier).key)
            }
            return TrainerCardView.BadgeRow(
                category: cat,
                cleared: cleared,
                available: cat.isAvailable(settings)
            )
        }
    }

    private var collectionRows: [(collection: PetCollection, complete: Bool)] {
        PetCollection.allCases.map { c in
            (c, settings.completedCollections.contains(c.rawValue))
        }
    }

    // MARK: - Share actions (Phase D 구현)

    private func copyCardToPasteboard() {
        guard let png = renderCardPNG() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }

    private func saveCardToFile() {
        guard let png = renderCardPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "trainer-card-\(settings.trainerID).png"
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url)
        }
    }

    private func shareCard() {
        guard let png = renderCardPNG() else { return }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trainer-card-\(settings.trainerID).png")
        do {
            try png.write(to: tmpURL)
        } catch { return }
        let picker = NSSharingServicePicker(items: [tmpURL])
        if let window = NSApp.keyWindow,
           let view = window.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }

    /// `TrainerCardView`를 standardWidth 해상도로 PNG 캡처. 2x DPI 적용.
    @MainActor
    private func renderCardPNG() -> Data? {
        let cardView = TrainerCardView(
            card: settings.trainerCard,
            trainerID: settings.trainerID,
            trainerName: displayName,
            stats: TrainerStats.compute(from: settings),
            badges: badgeRows,
            collections: collectionRows,
            showWatermark: true,
            width: TrainerCardView.standardWidth,
            medals: settings.medalTally,
            equippedEffects: settings.equippedEffects[settings.trainerCard.avatar.kind] ?? []
        )
        let renderer = ImageRenderer(content: cardView)
        renderer.scale = 2.0  // Retina export — 캡처 PNG 960×720
        guard let nsImage = renderer.nsImage else { return nil }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 카드 avatar의 walk 한 사이클을 프레임별로 캡처해 애니메이션 GIF로 합성.
    /// 각 프레임은 `avatarFrame`을 주입한 `TrainerCardView`를 `ImageRenderer`로 PNG 캡처한 것 —
    /// avatar 외 나머지(stats·badges 등)는 매 프레임 동일하므로 한 번만 계산해 재사용한다.
    @MainActor
    private func renderCardGIF() -> Data? {
        let kind = settings.trainerCard.avatar.kind
        let frameCount = PetSprite.frames(for: kind, action: .walk).count
        guard frameCount > 0 else { return nil }

        let stats = TrainerStats.compute(from: settings)
        let badges = badgeRows
        let cols = collectionRows
        let effects = settings.equippedEffects[kind] ?? []
        var cgFrames: [CGImage] = []
        cgFrames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let cardView = TrainerCardView(
                card: settings.trainerCard,
                trainerID: settings.trainerID,
                trainerName: displayName,
                stats: stats,
                badges: badges,
                collections: cols,
                showWatermark: true,
                width: TrainerCardView.standardWidth,
                medals: settings.medalTally,
                avatarFrame: i,
                equippedEffects: effects
            )
            let renderer = ImageRenderer(content: cardView)
            renderer.scale = 2.0
            if let cg = renderer.cgImage { cgFrames.append(cg) }
        }
        return Self.encodeGIF(frames: cgFrames, delay: 1.0 / TrainerCardView.avatarFPS)
    }

    /// CGImage 배열 → 무한 루프 애니메이션 GIF 데이터 (ImageIO).
    private static func encodeGIF(frames: [CGImage], delay: Double) -> Data? {
        guard !frames.isEmpty else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]   // 0 = 무한 루프
        ] as CFDictionary)
        let frameProps = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
        ] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func saveGIFToFile() {
        guard let gif = renderCardGIF() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "trainer-card-\(settings.trainerID).gif"
        if panel.runModal() == .OK, let url = panel.url {
            try? gif.write(to: url)
        }
    }

    private func shareGIF() {
        guard let gif = renderCardGIF() else { return }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trainer-card-\(settings.trainerID).gif")
        do {
            try gif.write(to: tmpURL)
        } catch { return }
        let picker = NSSharingServicePicker(items: [tmpURL])
        if let window = NSApp.keyWindow,
           let view = window.contentView {
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        }
    }
}
