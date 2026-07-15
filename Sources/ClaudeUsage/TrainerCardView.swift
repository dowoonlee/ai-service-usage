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
    /// 금/은/동 메달 누적 — 서버 집계(`monthly_winners`) 권위 값. nil이거나 total 0이면 메달 행 미표시.
    /// `stats`(profile_json)와 분리해 위조 불가능한 서버 값만 별도 주입받는다.
    var medals: MedalTally? = nil
    /// true면 avatar가 walk 사이클로 애니메이션 (preview 전용 — `ImageRenderer` 캡처는 한 순간만 잡는다).
    var animatedAvatar: Bool = false
    /// GIF 프레임 캡처용 — 지정 시 avatar를 그 walk frameIndex로 고정 렌더 (preview 애니보다 우선).
    var avatarFrame: Int? = nil
    /// 펫에 장착된 RP 코스메틱 이펙트 — avatar 뒤·앞에 광원/무지개/파티클로 렌더 (PNG·GIF·preview 공통).
    var equippedEffects: Set<EffectKind> = []
    /// 소속 길드명 태그 (P2a) — 이름 행 아래 캡슐. nil/빈 문자열이면 미표시.
    /// 원격 사용자는 profileJson.guildName(본인 submit 시 포함)에서 옴 — 표시용 캐시라 최신성은 느슨.
    var guildName: String? = nil

    /// avatar walk 애니메이션 속도 (preview·GIF 공통). GIF delay = 1/avatarFPS.
    static let avatarFPS: Double = 8

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
        ZStack {
            LinearGradient(
                colors: [
                    card.background.fillTopColor.opacity(0.55),
                    card.background.fillBottomColor.opacity(0.85),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 컬렉션 배경은 밈 타이틀(예: "IT'S ALWAYS DNS")을 대각선 반복 워터마크로 깔아
            // '색만 다른 그라디언트' 느낌을 덜어준다. PetTheme(잔디밭/바다 등 자연 테마)은
            // 텍스트가 어색해 그라디언트만 유지 — `.collection`일 때만 패턴을 얹는다.
            if case .collection = card.background {
                watermarkPattern
            }
        }
    }

    /// 배경명을 기울여 타일링한 반투명 워터마크. 매우 옅은(opacity 0.08) 흰색이라
    /// 위에 얹히는 흰색 본문 가독성을 해치지 않으면서 질감만 더한다. 행마다 절반씩
    /// 어긋낸 벽돌 패턴으로 격자 느낌을 제거. 카드 대각선을 덮도록 넉넉히 그린 뒤
    /// body 최상위 `clipShape`가 카드 밖으로 넘친 부분을 잘라낸다. 본문 제스처(액세서리
    /// drag)를 가로채지 않도록 hit test 비활성.
    private var watermarkPattern: some View {
        let phrase = card.background.displayName.uppercased()
        let line = Array(repeating: phrase, count: 10).joined(separator: "   ")
        let fontSize = max(10, width * 0.028)
        return VStack(alignment: .leading, spacing: fontSize * 0.9) {
            ForEach(0..<18, id: \.self) { row in
                Text(line)
                    .font(.system(size: fontSize, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.15))
                    .lineLimit(1)
                    .fixedSize()
                    .offset(x: row.isMultiple(of: 2) ? 0 : -fontSize * 4)
            }
        }
        .rotationEffect(.degrees(-22))
        .frame(width: width, height: width / Self.aspectRatio)
        .allowsHitTesting(false)
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
            // 이름 + (길드 태그) + ID 한 줄.
            HStack(alignment: .lastTextBaseline) {
                Text(trainerName.uppercased())
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let guildName, !guildName.isEmpty {
                    Text("⚔ \(guildName)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.teal.opacity(0.45))
                                .overlay(Capsule().stroke(Color.teal.opacity(0.7), lineWidth: 0.5))
                        )
                }
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
        Group {
            if let avatarFrame {
                // GIF 캡처 — 외부 주입 프레임 고정.
                avatarStack(walkFrame: avatarFrame)
            } else if animatedAvatar {
                // 미리보기 — walk 사이클 자체 애니메이션 (ImageRenderer 캡처는 한 순간만 잡는다).
                TimelineView(.animation) { ctx in
                    let count = PetSprite.frames(for: card.avatar.kind, action: .walk).count
                    let idx = count > 0 ? Int(ctx.date.timeIntervalSinceReferenceDate * Self.avatarFPS) % count : 0
                    avatarStack(walkFrame: idx)
                }
            } else {
                // PNG export·기본 — 정적 sit.
                avatarStack(walkFrame: nil)
            }
        }
        .frame(width: 110, height: 110)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.xl)
                .fill(.black.opacity(0.22))
        )
    }

    // 펫 + RP 이펙트 + 액세서리를 한 frameIndex 기준으로 함께 그린다. z-order: 광원/무지개(뒤) →
    // 펫 → 파티클(앞) → 액세서리(맨 위). `walkFrame`이 nil이면 정적 sit, 값이면 walk 프레임.
    @ViewBuilder
    private func avatarStack(walkFrame: Int?) -> some View {
        let moving = walkFrame != nil
        ZStack {
            // RP 코스메틱 — 광원(glow/aura)·무지개는 펫 뒤(backdrop).
            effectOverlay(.backdrop, moving: moving)
            if let wf = walkFrame {
                avatarImage(action: .walk, frameIndex: wf)
            } else {
                avatarImage(action: .sit, frameIndex: 0)
            }
            // RP 코스메틱 — 발자국·잔상 파티클은 펫 앞(particles).
            effectOverlay(.particles, moving: moving)
            // 액세서리 layer — PNG 자원 있으면 그것, 없으면 SF Symbol fallback. 맨 위.
            if let acc = card.accessory {
                accessoryLayer(acc)
            }
        }
    }

    // 장착된 RP 이펙트를 카드 셀(110×110) 좌표에 맞춰 그린다. 비어 있으면 아무것도 렌더하지 않는다.
    // center/petHeight는 셀 안 펫 표시 영역 근사값 — WalkingCat의 차트 좌표 대신 카드 셀 기준.
    @ViewBuilder
    private func effectOverlay(_ placement: PetEffectOverlay.Placement, moving: Bool) -> some View {
        if !equippedEffects.isEmpty {
            PetEffectOverlay(
                effects: equippedEffects,
                placement: placement,
                center: CGPoint(x: 55, y: 52),
                footY: 84,
                petHeight: 54,
                facingRight: !card.avatar.kind.defaultFacingLeft,
                isMoving: moving
            )
            .frame(width: 110, height: 110)
        }
    }

    @ViewBuilder
    private func avatarImage(action: PetController.Action, frameIndex: Int) -> some View {
        if let img = PetSprite.image(for: card.avatar.kind, action: action, frameIndex: frameIndex) {
            let v = card.avatar.variant
            let isRainbow = v == PetOwnership.prestigeVariant
            // 레인보우 레어 아바타 — 무지개 순환. now는 walk 프레임 애니(TimelineView) 캐이던스로 갱신.
            let now = Date().timeIntervalSinceReferenceDate
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(isRainbow ? WalkingCat.prestigeHueDegrees(at: now) : WalkingCat.hueDegrees(for: v)))
                .saturation(v > 0 ? 1.15 : 1.0)
                .colorMultiply(isRainbow ? WalkingCat.prestigeTint(at: now) : .white)
        }
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
            // 금/은/동 메달 — 서버 집계값. 하나라도 있을 때만 노출 (대부분 사용자는 0 → 행 숨김).
            if let m = medals, m.total > 0 {
                medalRow(m)
            }
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

    /// 1·2·3위 누적 메달 — 올림픽 메달 테이블처럼 🥇🥈🥉 셋을 항상 함께 노출(0 포함).
    /// 행 자체는 total > 0 일 때만 렌더되므로 "전부 0"인 카드엔 안 보인다.
    private func medalRow(_ m: MedalTally) -> some View {
        HStack(spacing: 10) {
            medalChip("🥇", m.gold)
            medalChip("🥈", m.silver)
            medalChip("🥉", m.bronze)
        }
    }

    private func medalChip(_ emoji: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Text(emoji).font(.system(size: 13))
            Text("\(count)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 0.5)
        }
    }

    // MARK: - Badges + Collections

    /// 도장 뱃지 8 + 컬렉션 11. 레이아웃 옵션 제거 — 항상 두 행 노출.
    /// dot 행이 카드 폭을 넘지 않도록 개수에 맞춰 dot 지름을 축소한다 (base 이하로만, 최소 9).
    /// 컬렉션(sets)이 19개로 늘면서 고정 16pt × 19개 + 라벨이 카드 내부폭을 초과해 body 전체가
    /// 넓어지고 `.frame(width)` center 정렬로 좌우가 잘리던 회귀를 막는다.
    /// available = 카드폭 - padding(36) - 라벨(80) - 라벨/도트 간격(6) - 우측 여유(8).
    private func rowDotSize(count: Int, base: CGFloat, spacing: CGFloat = 5) -> CGFloat {
        guard count > 1 else { return base }
        let available = width - 36 - 80 - 6 - 8
        let raw = (available - CGFloat(count - 1) * spacing) / CGFloat(count)
        return min(base, max(9, raw))
    }

    private var badgesSection: some View {
        let badgeSize = rowDotSize(count: badges.count, base: 20)
        let setSize = rowDotSize(count: collections.count, base: 16)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("BADGES")
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 80, alignment: .leading)
                HStack(spacing: 5) {
                    ForEach(badges, id: \.category.rawValue) { b in
                        badgeDot(size: badgeSize, category: b.category, cleared: b.cleared, available: b.available)
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
                        collectionDot(size: setSize, collection: c.collection, complete: c.complete)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func badgeDot(size: CGFloat, category: BadgeCategory, cleared: Bool, available: Bool) -> some View {
        let color = available
            ? (cleared ? Color(hex: category.gemColorHex) : Color.gray.opacity(0.5))
            : Color.black.opacity(0.4)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.15)
                .fill(color)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7)
                )
            if cleared {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.55, weight: .black))
                    .foregroundStyle(.white)
            }
        }
    }

    private func collectionDot(size: CGFloat, collection: PetCollection, complete: Bool) -> some View {
        Circle()
            .fill(complete ? collection.accentColor : Color.gray.opacity(0.4))
            .frame(width: size, height: size)
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
/// Codable — 랭킹 보드 ProfileState 직렬화 대상.
struct TrainerStats: Codable {
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

/// 금/은/동 메달 누적 집계. 서버 `monthly_winners`(rank 1/2/3)에서 집계해 leaderboard 응답
/// top-level로 내려오는 권위 값 — `TrainerStats`(profile_json, 클라 작성=위조 가능)와 달리
/// 클라이언트가 위조할 수 없다. 카드 렌더 시 별도 주입한다.
struct MedalTally: Codable, Equatable, Sendable {
    let gold: Int
    let silver: Int
    let bronze: Int
    var total: Int { gold + silver + bronze }
    static let zero = MedalTally(gold: 0, silver: 0, bronze: 0)
}
