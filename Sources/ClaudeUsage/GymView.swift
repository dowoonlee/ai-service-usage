import AppKit
import SwiftUI

// 도장 탭 — 가챠 윈도우 안 segmented picker로 진입.
// 상단 4 region 2x2 그리드(자유 진행), 하단 선택 region의 2 카테고리 × 4 tier 셀.
// 호버 tooltip으로 임계값/현재 진행/보상 한 줄 노출. 클릭은 안 받음.

@MainActor
struct GymView: View {
    @ObservedObject var settings: Settings = .shared
    @State private var selectedRegion: BadgeRegion = .coffee
    /// 호버된 뱃지 ID (BadgeID.key). nil이면 tooltip 숨김.
    @State private var hoveredKey: String?

    var body: some View {
        VStack(spacing: 12) {
            header
            WorldMapView(selected: $selectedRegion)
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
            gymLeaderSection
            Divider()
            categorySection
            Spacer(minLength: 0)
        }
        .padding(16)
        .onAppear {
            if !settings.hasViewedGymPage {
                settings.hasViewedGymPage = true
            }
        }
    }

    /// 맵과 카테고리 사이 — selected region의 관장 sprite + 진척도별 대사.
    private var gymLeaderSection: some View {
        let leader = GymLeader.leader(for: selectedRegion)
        let progress = BadgeRegistry.progress(forRegion: selectedRegion, settings)
        let stage = GymLeader.stage(cleared: progress.cleared, total: progress.total)
        let action = leader.action(stage: stage)
        let defeated = stage == 3

        // King Human(Repo)은 다른 펫보다 sprite 픽셀이 작아 시각적으로 묻힘 → scale up.
        let extraScale: CGFloat = (leader.kind == .kingHuman) ? 1.45 : 1.0

        return HStack(alignment: .center, spacing: 12) {
            // sprite — 상태별 다른 action.
            ZStack {
                if let img = PetSprite.image(for: leader.kind, action: action, frameIndex: 0) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .saturation(defeated ? 0.6 : 1.0)
                        .opacity(defeated ? 0.85 : 1.0)
                        .scaleEffect(x: leader.kind.defaultFacingLeft ? -extraScale : extraScale,
                                     y: extraScale)
                }
            }
            .frame(width: 64, height: 64)

            // 대사 bubble — 흰 배경 + 검정 텍스트로 가독성↑.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(leader.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("\(progress.cleared)/\(progress.total)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if defeated {
                        Text("VICTORY")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.yellow)
                    }
                }
                Text(leader.dialogue(stage: stage))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)     // tail 폭 + body padding
                    .padding(.trailing, 10)
                    .padding(.vertical, 6)
                    .background(
                        SpeechBubble(tailWidth: 8, tailHeight: 6, cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .overlay(
                        SpeechBubble(tailWidth: 8, tailHeight: 6, cornerRadius: 8)
                            .stroke(Color.black.opacity(0.4), lineWidth: 0.8)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var header: some View {
        let progress = BadgeRegistry.totalProgress(settings)
        return HStack(spacing: 8) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 14))
            Text("도장")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Text("\(progress.cleared) / \(progress.total)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if settings.championBadgeEarnedAt != nil {
                Image(systemName: "crown.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 13))
                    .help("챔피언 — 모든 도장 정복")
            }
        }
    }

    // MARK: - Category section

    /// tier 셀 고정 높이 — placeholder 행과 동기화해야 하므로 상수화 (tierCell의 frame과 동일 값).
    /// 아이콘(36×30)·게이지(3)는 그대로 두고 셀 내부 여백만 조여 56→44 로 축소 — vibe(3카테고리=12칸)
    /// 선택 시 categorySection이 3행이라 마지막 행(Codex)이 패널 밖으로 잘리던 문제 해소.
    /// 행당 12pt × 3행 = 36pt 회수. 빈 패딩 행도 같은 상수를 따라 자동 축소.
    private static let tierCellHeight: CGFloat = 44

    /// 모든 region 중 최대 카테고리 수 (현재 vibe=3, 나머지=2). region 추가/변경 시 자동 반영.
    private var maxCategoryRows: Int {
        BadgeRegion.allCases.map { $0.categories.count }.max() ?? 0
    }

    private var categorySection: some View {
        let regionProgress = BadgeRegistry.progress(forRegion: selectedRegion, settings)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PixelIconView(icon: selectedRegion.pixelIcon, color: .secondary)
                    .frame(width: 14, height: 14)
                Text(selectedRegion.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text("— \(regionProgress.cleared)/\(regionProgress.total)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            tierHeader
            VStack(spacing: 6) {
                ForEach(selectedRegion.categories, id: \.self) { cat in
                    categoryRow(cat)
                }
                // 카테고리 수가 적은 region(2개)은 빈 행으로 높이를 최대치(vibe=3)에 맞춘다 —
                // 안 그러면 vibe 선택 시 categorySection이 한 행 더 높아져 하단 Spacer가 줄고
                // 패널 전체 레이아웃이 region마다 점프한다.
                ForEach(0..<max(0, maxCategoryRows - selectedRegion.categories.count), id: \.self) { _ in
                    Color.clear.frame(height: Self.tierCellHeight)
                }
            }
        }
    }

    /// tier 컬럼 헤더 — 카테고리 라벨 폭만큼 left padding 후 4 tier 이름.
    private var tierHeader: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 90)
            ForEach(BadgeTier.allCases, id: \.self) { tier in
                Text(tier.displayName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Self.strokeColor(for: tier))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func categoryRow(_ cat: BadgeCategory) -> some View {
        let value = cat.currentValue(settings)
        let available = cat.isAvailable(settings)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(cat.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text("\(value) \(cat.unit)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .leading)

            ForEach(BadgeTier.allCases, id: \.self) { tier in
                tierCell(category: cat, tier: tier, currentValue: value, available: available)
            }
        }
    }

    private func tierCell(category: BadgeCategory, tier: BadgeTier, currentValue: Int, available: Bool) -> some View {
        let id = BadgeID(category: category, tier: tier)
        let cleared = settings.clearedBadges.contains(id.key)
        let threshold = category.thresholds[tier] ?? 0
        let progress: Double = threshold > 0 ? min(1.0, Double(currentValue) / Double(threshold)) : 0
        let strokeColor = Self.strokeColor(for: tier)
        let gemColor = Color(hex: category.gemColorHex)
        let isHovered = (hoveredKey == id.key)

        return ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor).opacity(isHovered ? 0.55 : 0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(strokeColor.opacity(cleared ? 0.85 : 0.4),
                                lineWidth: Self.strokeWidth(for: tier))
                )
                .shadow(color: (cleared && tier == .production) ? strokeColor.opacity(0.6) : .clear,
                        radius: 4)

            VStack(spacing: 2) {
                tierSprite(category: category, tier: tier, gemColor: gemColor,
                           cleared: cleared, available: available)
                    .frame(width: 36, height: 30)

                // 진행 바 자리는 항상 같은 높이 차지 — cell intrinsic height 안정.
                if !cleared && available && progress > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule().fill(strokeColor.opacity(0.8))
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 6)
                } else {
                    Color.clear.frame(height: 3)
                }
            }
            .padding(.vertical, 3)
        }
        // cell intrinsic size 고정 — hover 상태와 무관하게 column 폭 일정.
        .frame(maxWidth: .infinity, minHeight: Self.tierCellHeight, maxHeight: Self.tierCellHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredKey = hovering ? id.key : (hoveredKey == id.key ? nil : hoveredKey)
        }
        // 가챠 컬렉션 뱃지와 동일한 호버 패턴 — 시스템 popover로 풍부한 카드 노출.
        // (이전엔 검은 박스 .overlay tooltip이었음. ScrollView clip / hit-test 이슈 회피
        // 효과 + 페이드 애니메이션 자동 + 화면 가장자리 자동 배치 + 디자인 통일.)
        .popover(isPresented: Binding(
            get: { isHovered },
            set: { isPresented in
                if !isPresented, hoveredKey == id.key { hoveredKey = nil }
            }
        ), arrowEdge: .top) {
            BadgeTierTooltip(category: category, tier: tier,
                             currentValue: currentValue, threshold: threshold,
                             cleared: cleared, available: available,
                             strokeColor: strokeColor)
        }
    }

    /// tier별 화려함 progression — 모든 tier가 카테고리 jewel sprite(풀컬러 픽셀)를 base로,
    /// tier 진행에 따라 deco가 추가됨:
    ///   localhost  : jewel만 (작게, opacity 살짝 낮음)
    ///   dev        : jewel (보통 크기, 풀컬러)
    ///   staging    : jewel + sparkle 좌상단
    ///   production : jewel + crown 위쪽 + sparkles 양옆
    /// 잠긴 셀은 jewel 위에 회색 overlay + lock 아이콘.
    @ViewBuilder
    private func tierSprite(category: BadgeCategory, tier: BadgeTier,
                            gemColor: Color, cleared: Bool, available: Bool) -> some View {
        ZStack {
            // production: crown 위쪽에 작게.
            if tier == .production && cleared {
                PixelIconView(icon: BadgePixelIcons.crown, color: .yellow)
                    .frame(width: 14, height: 10)
                    .offset(y: -14)
                    .shadow(color: .yellow.opacity(0.5), radius: 2)
            }

            // base jewel sprite.
            jewelImage(for: category, tier: tier, cleared: cleared, available: available)

            // 잠긴 카테고리(Cursor Pro/Free): 자물쇠.
            if !available {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.7), radius: 1)
            }

            // staging+: sparkle deco 좌상단.
            if cleared && (tier == .staging || tier == .production) {
                PixelIconView(icon: BadgePixelIcons.sparkle, color: .white)
                    .frame(width: 9, height: 9)
                    .offset(x: -13, y: -10)
                    .shadow(color: .white.opacity(0.6), radius: 1)
            }
            // production: 추가 sparkle 우하단.
            if cleared && tier == .production {
                PixelIconView(icon: BadgePixelIcons.sparkle, color: .white)
                    .frame(width: 8, height: 8)
                    .offset(x: 13, y: 8)
                    .shadow(color: .white.opacity(0.6), radius: 1)
            }
        }
    }

    /// 카테고리 jewel PNG. cleared/available에 따라 saturation·brightness 조정.
    private func jewelImage(for category: BadgeCategory, tier: BadgeTier,
                            cleared: Bool, available: Bool) -> some View {
        let size: CGFloat = (tier == .localhost) ? 22 : 26
        let img = NSImage.gymJewel(named: category.jewelSpriteName)
        return Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                // Fallback — sprite 로딩 실패 시 SF Symbol.
                Image(systemName: category.systemImage)
                    .font(.system(size: 16))
                    .foregroundStyle(Color(hex: category.gemColorHex))
            }
        }
        .frame(width: size, height: size)
        .saturation(cleared ? 1.0 : (available ? 0.0 : 0.0))
        .brightness(cleared ? 0 : (available ? -0.1 : -0.4))
        .opacity(cleared ? 1.0 : (available ? 0.45 : 0.35))
        .shadow(color: (cleared && tier == .production) ? Color(hex: category.gemColorHex).opacity(0.6) : .clear,
                radius: 4)
    }


    // MARK: - Tier 색 / 굵기

    private static func strokeColor(for tier: BadgeTier) -> Color {
        switch tier {
        case .localhost:  return Color(white: 0.50)
        case .dev:        return Color(red: 0.20, green: 0.50, blue: 0.95)
        case .staging:    return Color(red: 0.18, green: 0.62, blue: 0.55)
        case .production: return Color(red: 1.0,  green: 0.78, blue: 0.0)
        }
    }

    /// tier 별 stroke 굵기 — production일수록 진함.
    private static func strokeWidth(for tier: BadgeTier) -> CGFloat {
        switch tier {
        case .localhost:  return 2.0
        case .dev:        return 2.5
        case .staging:    return 3.0
        case .production: return 3.5
        }
    }
}

/// 도장 셀 호버 popover. 가챠 컬렉션 뱃지의 `CollectionBadgeTooltip`과 동일 톤 —
/// 헤더(카테고리·tier) + 본문(상태별 분기: cleared/locked/in-progress) + 보상.
/// macOS 시스템 popover라 ScrollView clip 영향 없고 페이드/스케일 애니메이션 자동.
private struct BadgeTierTooltip: View {
    let category: BadgeCategory
    let tier: BadgeTier
    let currentValue: Int
    let threshold: Int
    let cleared: Bool
    let available: Bool
    let strokeColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 헤더: 카테고리 · tier + tier 색 도트.
            HStack(spacing: 6) {
                Circle()
                    .fill(strokeColor)
                    .frame(width: 8, height: 8)
                Text("\(category.displayName) · \(tier.displayName)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer(minLength: 4)
            }
            Divider()
            // 상태별 본문.
            if !available {
                Label {
                    Text(category.lockReason)
                        .font(.caption)
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            } else if cleared {
                Label {
                    Text("클리어")
                        .font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Text("\(threshold) \(category.unit) 달성")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("+\(tier.coinReward) coin 적립됨")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                // 진행도 + 진행 바 + 보상.
                let pct = threshold > 0 ? min(1.0, Double(currentValue) / Double(threshold)) : 0
                Text("\(currentValue)/\(threshold) \(category.unit)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(strokeColor.opacity(0.85))
                            .frame(width: geo.size.width * pct)
                    }
                }
                .frame(height: 4)
                Text("달성 시 +\(tier.coinReward) coin")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(strokeColor)
            }
        }
        .padding(12)
        .frame(width: 230, alignment: .leading)
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        var s = hex.uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
