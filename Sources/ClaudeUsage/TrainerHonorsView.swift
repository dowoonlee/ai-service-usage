import SwiftUI

struct TrainerHonorsView: View {
    enum Category: String, CaseIterable {
        case collection = "펫 수집", gym = "도장", battle = "수동 전투", ranking = "랭킹", titles = "업적 칭호"
    }
    @ObservedObject private var settings = Settings.shared
    @State private var category: Category

    init(initial: Category = .collection) { _category = State(initialValue: initial) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("훈장 종류", selection: $category) {
                ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch category {
                    case .collection: collections
                    case .gym: gym
                    case .battle: BattleHonorsView()
                    case .ranking: ranking
                    case .titles: titles
                    }
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }.id(category)
        }
    }

    private var collections: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("완성한 컬렉션  \(settings.completedCollections.count) / \(PetCollection.allCases.count)").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 14) {
                ForEach(PetCollection.allCases, id: \.self) { CollectionBadge(collection: $0, settings: settings) }
            }
        }
    }

    private var gym: some View {
        let progress = BadgeRegistry.totalProgress(settings)
        return VStack(alignment: .leading, spacing: 12) {
            Text("도장 뱃지  \(progress.cleared) / \(progress.total)").font(.headline)
            HStack {
                award("본토 챔피언", earned: settings.championBadgeEarnedAt != nil)
                award("클라우드 챔피언", earned: settings.cloudChampionAt != nil)
                award("그랜드 챔피언", earned: settings.grandChampionAt != nil)
            }
            seasonalVictories
            Divider()
            GymBadgeShelf()
        }
    }

    /// The instance year is part of the persisted award, so past victories remain visible off-season.
    @ViewBuilder private var seasonalVictories: some View {
        let wins = settings.seasonalFlags.sorted().compactMap { flag -> String? in
            let parts = flag.split(separator: ":")
            guard parts.count == 3, parts[0] == "boss", let tier = BadgeTier(rawValue: String(parts[2])),
                  let split = parts[1].lastIndex(of: "-") else { return nil }
            let kind = parts[1][..<split]
            let year = parts[1][parts[1].index(after: split)...]
            let name = SeasonRegistry.all.first { $0.kind.rawValue == kind }?.boss?.name ?? String(kind)
            return "\(year) · \(name) · \(tier.displayName)"
        }
        if !wins.isEmpty {
            Text("시즌 관장 격파").font(.subheadline.bold())
            ForEach(wins, id: \.self) { award($0, earned: true) }
        }
    }

    private var ranking: some View {
        let medals = settings.medalTally
        return VStack(alignment: .leading, spacing: 12) {
            Text("월간 랭킹 메달").font(.headline)
            HStack(spacing: 18) {
                Text("🥇 금 \(medals.gold)")
                Text("🥈 은 \(medals.silver)")
                Text("🥉 동 \(medals.bronze)")
            }.monospacedDigit()
            if medals.total == 0 {
                Text("월간 랭킹 1·2·3위에 들면 메달을 받습니다.").foregroundStyle(.secondary)
            }
        }
    }

    private var titles: some View {
        let unlocked = CardTitle.unlocked(in: settings)
        let visible = CardTitle.allCases.filter { $0 != .newcomer && $0.purchasePrice == nil && settings.shopVisible($0, owned: unlocked.contains($0)) }
        return LazyVStack(alignment: .leading, spacing: 10) {
            Text("해금한 업적 칭호  \(visible.filter(unlocked.contains).count) / \(visible.count)").font(.headline)
            ForEach(visible, id: \.self) { title in
                let earned = unlocked.contains(title)
                let hidden = !earned && ManualAchievement.forTitle(title)?.hidden == true
                VStack(alignment: .leading, spacing: 3) {
                    award(hidden ? "히든 전투 칭호" : title.displayName, earned: earned)
                    Text(hidden ? "특별한 전투 업적을 발견하면 해금됩니다." : title.unlockDescription)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
        }
    }

    private func award(_ name: String, earned: Bool) -> some View {
        Label(name, systemImage: earned ? "checkmark.seal.fill" : "lock")
            .font(.callout).foregroundStyle(earned ? Color.primary : Color.secondary)
            .accessibilityValue(earned ? "획득" : "미획득")
    }
}

private struct BattleHonorsView: View {
    @StateObject private var session = ManualBattleSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = session.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            OwnedManualAchievementShelf(expanded: true, preview: session.archive.achievementPreview)
            ManualMasteryShelf(practice: session.archive.records)
        }
    }
}

/// 컬렉션 업적 뱃지. 원형 48px + SF Symbol + 진행도 caption — 카드보다 균일하고 컴팩트.
/// 호버 시 popover로 displayName/subtitle/진행도/보너스 노출. `.help` modifier는 ScrollView
/// 내부 LazyVGrid에서 hit-test가 안 잡히는 케이스가 있어 `.onHover` + `.popover` 조합으로
/// 직접 우회. 미완성은 회색, 완성은 `accentColor`.
private struct CollectionBadge: View {
    let collection: PetCollection
    @ObservedObject var settings: Settings

    @State private var hovering: Bool = false

    var body: some View {
        let isComplete = settings.completedCollections.contains(collection.rawValue)
        let isHighlighted = settings.pendingCollectionHighlights.contains(collection.rawValue)
        let progress = collection.progress(settings)
        let color: Color = isComplete ? collection.accentColor : Color.gray

        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                // 입체감 = (1) 위→아래 linear gradient (밝 → 어둡) +
                //         (2) 좌상단 plusLighter radial 하이라이트 +
                //         (3) drop shadow.
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(isComplete ? 1.00 : 0.40),
                                color.opacity(isComplete ? 0.65 : 0.20),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 48, height: 48)
                    .overlay(
                        // 좌상단 광택 — plusLighter blend로 밝게 보이는 spec highlight.
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.white.opacity(isComplete ? 0.50 : 0.22), .clear],
                                    center: UnitPoint(x: 0.30, y: 0.22),
                                    startRadius: 1,
                                    endRadius: 18
                                )
                            )
                            .frame(width: 48, height: 48)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    )
                    .overlay(
                        // 외곽 stroke — highlighted면 노란색·두꺼움(클릭 확인하기 전까지 강조).
                        Circle()
                            .stroke(
                                isHighlighted ? Color.yellow : color.opacity(isComplete ? 0.95 : 0.45),
                                lineWidth: isHighlighted ? 2.0 : 1.0
                            )
                    )
                    .shadow(
                        color: isHighlighted ? Color.yellow.opacity(0.65) : color.opacity(isComplete ? 0.55 : 0.18),
                        radius: isHighlighted ? 6 : 4, x: 0, y: 2
                    )
                Image(systemName: collection.iconSystemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(isComplete ? 1.0 : 0.70))
                    .shadow(color: .black.opacity(0.30), radius: 1, x: 0, y: 0.5)
                    .frame(width: 48, height: 48)
                    .allowsHitTesting(false)
                if isHighlighted {
                    // 신규 컴플리트 — 클릭으로 확인하기 전까지 ! 마크 유지.
                    // (✓ 마크와 같은 위치에 표시 — 사용자가 클릭하면 ! → ✓로 자연 전환.)
                    Text("!")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(Color.yellow))
                        .overlay(Circle().stroke(Color.orange, lineWidth: 1))
                        .shadow(color: Color.yellow.opacity(0.7), radius: 3)
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                } else if isComplete {
                    // 완성 표식 — 우상단 노란 체크. 뱃지 가장자리 살짝 넘게 배치.
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.yellow)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
            Text(collection.displayName)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
            Text(isComplete ? "완성" : "\(progress.collected)/\(progress.total)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isComplete ? color : .secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        // hit-test 영역을 frame 전체(원 + caption)로 — background가 없는 VStack은 hover 감지가
        // 자식 view 영역으로만 한정되므로 명시.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // 클릭으로 강조 확인 — 호버 popover로 정보를 봤다고 자동 dismiss하지 않음.
            // (`pendingHighlights`(펫 슬롯)와 동일 패턴 — 명시적 클릭만 acknowledge.)
            settings.acknowledgeCollectionHighlight(collection.rawValue)
        }
        .popover(isPresented: $hovering, arrowEdge: .top) {
            CollectionBadgeTooltip(
                collection: collection,
                isComplete: isComplete,
                progress: progress,
                completedAt: settings.collectionCompletedAt[collection.rawValue],
                ownedPets: settings.ownedPets
            )
        }
    }
}

/// 뱃지 호버 popover 내용. 시스템 popover 안에서 렌더링되므로 ScrollView clip 영향 없음.
/// 컴플리트 조건(어떤 펫을 모아야 하는지)을 멤버 sprite + 이름 + 보유 ✓로 명시.
///
/// `@MainActor` 명시 — `spriteThumb`가 `PetSprite.image(...)`를 호출하는데, GitHub Actions의
/// 엄격한 Swift concurrency 체크가 SwiftUI View의 `@ViewBuilder` 메서드를 nonisolated로
/// 추론해서 actor 위반 에러를 냈음 (로컬 빌드는 통과). 명시적으로 격리.
@MainActor
private struct CollectionBadgeTooltip: View {
    let collection: PetCollection
    let isComplete: Bool
    let progress: (collected: Int, total: Int)
    let completedAt: Date?
    let ownedPets: [PetKind: PetOwnership]

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 헤더: 아이콘 + 코드네임 + 진행도.
            HStack(spacing: 6) {
                Image(systemName: collection.iconSystemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(collection.accentColor)
                Text(collection.displayName)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer(minLength: 4)
                Text("\(progress.collected)/\(progress.total)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isComplete ? collection.accentColor : .secondary)
            }
            Text(collection.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            // 멤버 리스트 — sprite + 한국어 이름 + 보유 체크. 컴플리트 조건이 명시적으로 보임.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(collection.members) { kind in
                    let owned = (ownedPets[kind]?.count ?? 0) > 0
                    HStack(spacing: 6) {
                        spriteThumb(kind: kind, owned: owned)
                        Text(PetMetaStore.shared.displayName(for: kind))
                            .font(.caption2)
                            .foregroundStyle(owned ? .primary : .secondary)
                        Spacer(minLength: 0)
                        Image(systemName: owned ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(owned ? .green : .secondary.opacity(0.5))
                    }
                }
            }
            Divider()
            // 상태/보너스
            if isComplete {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("컴플리트")
                        .font(.caption.weight(.semibold))
                    if let date = completedAt {
                        Text("· \(Self.dateFormatter.string(from: date))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("+\(collection.bonusCoins) coin 적립됨")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text("완성 시 +\(collection.bonusCoins) coin")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(collection.accentColor)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }

    /// 멤버 펫의 미니 sprite. 보유: 컬러 + 외곽선, 미보유: 흑백 + 흐림.
    @ViewBuilder
    private func spriteThumb(kind: PetKind, owned: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.10))
            if let img = PetSprite.image(for: kind, action: .sit, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .padding(1)
                    .colorMultiply(owned ? .white : .black)
                    .opacity(owned ? 1.0 : 0.45)
            }
        }
        .frame(width: 18, height: 18)
    }
}
