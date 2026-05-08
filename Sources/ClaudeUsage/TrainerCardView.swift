import SwiftUI

/// 트레이너 카드 view — 4:3 비율. `TrainerCard` 데이터 모델의 5 layer를 합성.
///
/// 자체 데이터 의존 없는 pure view (모든 입력은 init 인자) — `ImageRenderer`로 captureable.
/// 호출 측(`ReportView`)이 `Settings`에서 stats를 계산해 주입.
///
/// `@MainActor` 명시 — `PetSprite.image(...)` / `TrainerBackground.fillTopColor` 등
/// MainActor 격리된 메서드를 호출하는데, GitHub Actions의 strict concurrency 체크가
/// SwiftUI View struct의 `@ViewBuilder` 메서드를 nonisolated로 추론해 actor 위반 에러를 냄
/// (로컬 빌드는 통과). v0.6.10 `CollectionBadgeTooltip`과 동일 패턴.
@MainActor
struct TrainerCardView: View {
    let card: TrainerCard
    let trainerID: String
    let trainerName: String
    let stats: TrainerStats
    /// (BadgeCategory, cleared, available) tuple — 도장 8 카테고리.
    let badges: [BadgeRow]
    /// (PetCollection, complete) tuple — 컬렉션 11.
    let collections: [(collection: PetCollection, complete: Bool)]
    /// 캡처용 워터마크. preview에선 보이는 게 자연스럽고 export 시도 그대로 박힘.
    var showWatermark: Bool = true

    struct BadgeRow {
        let category: BadgeCategory
        let cleared: Bool
        let available: Bool
    }

    /// 4:3 비율. ImageRenderer가 caller-provided width 기준 자동 계산.
    static let aspectRatio: CGFloat = 4.0 / 3.0
    /// 캡처 표준 해상도 (480×360 → 2x DPI = 960×720 PNG). 높이면 detail ↑, 파일 ↑.
    static let standardWidth: CGFloat = 480

    /// 카드 폭. preview에선 컨테이너 폭, export 시 `standardWidth`. 비율(4:3)에 맞춰 height 자동.
    var width: CGFloat = standardWidth
    /// 액세서리 transform 편집 가능한 binding. nil이면 정적 표시 (export 캡처용).
    /// Set이면 액세서리 sprite에 DragGesture가 붙어 마우스로 위치 조정 가능.
    var accessoryEditing: Binding<AccessoryTransform>? = nil

    var body: some View {
        ZStack {
            backgroundLayer
            VStack(spacing: 10) {
                headerSection
                Divider().background(card.frame.color.opacity(0.3))
                middleSection
                Divider().background(card.frame.color.opacity(0.3))
                badgesSection
                Spacer(minLength: 0)
                if showWatermark {
                    footerSection
                }
            }
            .padding(18)
        }
        .frame(width: width, height: width / Self.aspectRatio)
        .overlay(frameOverlay)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        LinearGradient(
            colors: [
                card.background.fillTopColor.opacity(0.55),
                card.background.fillBottomColor.opacity(0.85),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Frame stroke — `CardFrame`별 색·두께. sparkle은 추가 glow.
    private var frameOverlay: some View {
        RoundedRectangle(cornerRadius: 14)
            .stroke(card.frame.color, lineWidth: card.frame.lineWidth)
            .shadow(
                color: card.frame == .sparkle ? card.frame.color.opacity(0.6) : .clear,
                radius: card.frame == .sparkle ? 8 : 0
            )
    }

    // MARK: - Header (title + name + ID)
    //
    // 칭호를 별도 행으로 빼서 부각. 캡슐 키우고 폰트 14pt heavy + glow shadow로 강조.
    // 트레이너 이름은 24pt black — 카드의 시각적 anchor.

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 칭호 — 카드 정체성의 핵심. dark fill + frame color stroke + glow로 강조하되
            // 모든 frame.color(silver/gold 같은 밝은 톤 포함)에서 흰 글자가 명확히 읽히도록.
            HStack(spacing: 6) {
                Image(systemName: "rosette")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(card.frame.color)
                Text(card.title.displayName.uppercased())
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.55))
                    .overlay(
                        Capsule().stroke(card.frame.color, lineWidth: 1.5)
                    )
                    .shadow(color: card.frame.color.opacity(0.6), radius: 5)
            )
            // 이름 + ID 한 줄.
            HStack(alignment: .lastTextBaseline) {
                Text(trainerName.uppercased())
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("ID #\(trainerID)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Middle (avatar + stats)
    //
    // 레이아웃 옵션 제거 — 항상 avatar 왼쪽, stats 오른쪽으로 고정.

    private var middleSection: some View {
        HStack(alignment: .center, spacing: 14) {
            avatarView
            statsView
            Spacer(minLength: 0)
        }
    }

    private var avatarView: some View {
        ZStack {
            // 펫 sprite — variant hue.
            if let img = PetSprite.image(for: card.avatar.kind, action: .sit, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .hueRotation(.degrees(WalkingCat.hueDegrees(for: card.avatar.variant)))
                    .saturation(card.avatar.variant > 0 ? 1.15 : 1.0)
            }
            // 액세서리 layer — PNG 자원 있으면 그것, 없으면 SF Symbol fallback.
            if let acc = card.accessory {
                accessoryLayer(acc)
            }
        }
        .frame(width: 110, height: 110)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.22))
        )
    }

    @ViewBuilder
    private func accessoryLayer(_ acc: CardAccessory) -> some View {
        let t = card.effectiveAccessoryTransform
        let baseSize: CGFloat = 50
        let size = baseSize * t.scale
        let symbolSize: CGFloat = 26 * t.scale
        Group {
            if let img = PetSprite.image(named: acc.resourceName) {
                // PNG 자원 있음 — 펫 위쪽 중앙(머리 위치 근사) overlay.
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                // Fallback: SF Symbol. 자원 추가되면 자동 swap.
                Image(systemName: acc.fallbackSymbol)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: size, height: size)
            }
        }
        .offset(x: t.offsetX, y: t.offsetY)
        .modifier(AccessoryDragModifier(editing: accessoryEditing))
    }

    private var statsView: some View {
        VStack(alignment: .leading, spacing: 5) {
            statRow(icon: "clock.fill", text: stats.formattedTime)
            statRow(icon: "dollarsign.circle.fill", text: "\(stats.coinsTotalEarned.formatted()) coin")
            statRow(icon: "die.face.5.fill", text: "\(stats.totalPulls) pulls")
            statRow(icon: "trophy.fill", text: "\(stats.badgesCleared)/\(stats.badgesTotal) badges")
            statRow(icon: "checkmark.seal.fill", text: "\(stats.collectionsComplete)/\(stats.collectionsTotal) sets")
        }
    }

    private func statRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.yellow)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 0.5)
        }
    }

    // MARK: - Badges + Collections

    /// 도장 뱃지 8 + 컬렉션 11. 레이아웃 옵션 제거 — 항상 두 행 노출.
    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("BADGES")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 80, alignment: .leading)
                HStack(spacing: 5) {
                    ForEach(badges, id: \.category.rawValue) { b in
                        badgeDot(category: b.category, cleared: b.cleared, available: b.available)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("SETS")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 80, alignment: .leading)
                HStack(spacing: 5) {
                    ForEach(collections, id: \.collection.rawValue) { c in
                        collectionDot(collection: c.collection, complete: c.complete)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func badgeDot(category: BadgeCategory, cleared: Bool, available: Bool) -> some View {
        let color = available
            ? (cleared ? Color(hex: category.gemColorHex) : Color.gray.opacity(0.5))
            : Color.black.opacity(0.4)
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                )
            if cleared {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
            }
        }
    }

    private func collectionDot(collection: PetCollection, complete: Bool) -> some View {
        Circle()
            .fill(complete ? collection.accentColor : Color.gray.opacity(0.4))
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.7))
    }

    // MARK: - Footer

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd"
        return f
    }()

    private var footerSection: some View {
        HStack {
            Spacer()
            Text("AIUsage · \(Self.dateFormatter.string(from: Date()))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
        }
    }
}

/// 액세서리 sprite에 DragGesture를 조건부로 적용하는 modifier.
/// `editing` binding이 nil이면 gesture 미부착(export 캡처용 정적 view).
/// drag 시작 시 transform snapshot을 잡고, 누적 translation을 더해 offset 변경 — clamp로
/// 펫(110px) 영역 너무 벗어나지 않게 제한.
private struct AccessoryDragModifier: ViewModifier {
    let editing: Binding<AccessoryTransform>?
    @State private var dragStart: AccessoryTransform?

    func body(content: Content) -> some View {
        if let editing = editing {
            content.gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil { dragStart = editing.wrappedValue }
                        var t = dragStart ?? editing.wrappedValue
                        t.offsetX = (t.offsetX + value.translation.width)
                            .clamped(to: -AccessoryTransform.offsetLimit...AccessoryTransform.offsetLimit)
                        t.offsetY = (t.offsetY + value.translation.height)
                            .clamped(to: -AccessoryTransform.offsetLimit...AccessoryTransform.offsetLimit)
                        editing.wrappedValue = t
                    }
                    .onEnded { _ in dragStart = nil }
            )
        } else {
            content
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// 트레이너 카드의 통계 입력. `ReportView`가 `Settings`로부터 계산해 주입.
struct TrainerStats {
    let totalSeconds: Int
    let coinsTotalEarned: Int
    let totalPulls: Int
    let badgesCleared: Int
    let badgesTotal: Int
    let collectionsComplete: Int
    let collectionsTotal: Int

    /// "152h 30m" / "5d 12h" — 가독성 우선.
    var formattedTime: String {
        let totalMin = totalSeconds / 60
        let h = totalMin / 60
        let m = totalMin % 60
        let d = h / 24
        if d >= 2 {
            let remainingH = h % 24
            return "\(d)d \(remainingH)h"
        }
        return "\(h)h \(m)m"
    }

    /// `Settings`로부터 stats 계산 — 한 곳에 모아둠.
    @MainActor
    static func compute(from s: Settings) -> TrainerStats {
        let totalSec = Int(s.petUsageSeconds.values.reduce(0, +))
        let totalPulls = s.ownedPets.values.reduce(0) { $0 + $1.count }
        let availBadges = BadgeCategory.allCases.filter { $0.isAvailable(s) }
        return TrainerStats(
            totalSeconds: totalSec,
            coinsTotalEarned: s.coinsTotalEarned,
            totalPulls: totalPulls,
            badgesCleared: s.clearedBadges.count,
            badgesTotal: availBadges.count * BadgeTier.allCases.count,
            collectionsComplete: s.completedCollections.count,
            collectionsTotal: PetCollection.allCases.count
        )
    }
}
