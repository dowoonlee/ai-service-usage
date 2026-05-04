import AppKit
import SwiftUI

/// 가챠 + 도감 창. SettingsView "수집" 섹션의 "열기" 버튼으로 띄움.
///
/// 결과 표시는 `ResultPhase` enum 기반:
///   - `.idle`: 결과 없음
///   - `.egg` / `.cracking`: 알 부화 단계 (M4.3에서 자산 + 인터랙션 추가 예정)
///   - `.hatched`: 최종 펫 공개
/// 현재는 `performPull` 직후 즉시 `.hatched`로 진입. egg/cracking 단계 사이에 탭/애니메이션을
/// 끼워넣는 것이 M4.3의 작업.
struct GachaView: View {
    @ObservedObject var settings = Settings.shared
    @State private var phase: ResultPhase = .idle
    @State private var errorMessage: String?
    @State private var eggTapCount: Int = 0
    @State private var eggShakeAngle: Double = 0
    /// `.revealing` 시작 시각. TimelineView가 elapsed 기반 시각 효과 계산에 사용.
    @State private var revealStartedAt: Date?
    /// `.cracking` 시작 시각. crack 라인이 trim으로 점진 그려지는 데 사용.
    @State private var crackStartedAt: Date?
    /// 임계 도달 후 Task spawn race 방지. 부화 시퀀스가 한 번만 commit하도록 가드.
    @State private var hatchInProgress: Bool = false
    /// 상점/도장 탭. 첫 진입 .shop, 가챠 hatch 중에는 잠금.
    @State private var selectedTab: Tab = .shop

    enum Tab: String, CaseIterable, Identifiable {
        case shop, gym
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .shop: return "상점"
            case .gym:  return "도장"
            }
        }
    }

    /// 알을 깨는 데 필요한 탭 수.
    private static let eggTapsRequired: Int = 6
    /// cracking → revealing 사이 머무는 시간.
    private static let crackingDuration: TimeInterval = 1.0
    /// revealing 단계 전체 시간 (flash + silhouette + fadeIn 합).
    private static let revealDuration: TimeInterval = 2.2
    /// hatched/revealing 단계 sprite의 y offset (영역 center 기준).
    /// 두 view가 sprite를 같은 위치에 그려야 cross-fade 시 점프가 없다.
    private static let spriteRestY: CGFloat = -38

    enum ResultPhase {
        case idle
        case egg(GachaPull)
        case cracking(GachaPull)
        case revealing(GachaPull)  // 암전 + flash + 실루엣 + fade in
        case hatched(GachaPull)
        case preview(PetKind, Int) // 인벤토리에서 클릭한 보유 펫 미리보기
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(isHatchingMidAction)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ZStack {
                if selectedTab == .shop {
                    shopTab.transition(.opacity)
                } else {
                    GymView().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: selectedTab)
        }
        .frame(width: 480, height: 640)
    }

    private var shopTab: some View {
        VStack(spacing: 16) {
            header
            Divider()
            resultArea
            Divider()
            inventorySection
        }
        .padding(20)
    }

    /// 가챠 hatch 시퀀스(cracking/revealing)는 펫 commit 전이라 picker 잠금.
    /// idle/egg/hatched/preview 단계는 다른 탭 봐도 OK.
    /// (`hatchInProgress`는 .hatched 진입 후 reset 안 되어 picker 영구 잠금 버그가 있어 — phase만 검사)
    private var isHatchingMidAction: Bool {
        switch phase {
        case .cracking, .revealing: return true
        default: return false
        }
    }

    // MARK: - Header (잔액 + 뽑기 버튼)

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                CoinIcon(size: 18)
                Text("\(settings.coins)")
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
            Spacer()
            Button(action: pull) {
                if settings.gachaTickets > 0 {
                    Label("무료 뽑기", systemImage: "ticket.fill")
                } else {
                    Label("\(Gacha.pullCost)코인 뽑기", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canPull)
        }
    }

    private var canPull: Bool {
        settings.gachaTickets > 0 || settings.coins >= Gacha.pullCost
    }

    private func pull() {
        let useTicket = settings.gachaTickets > 0
        do {
            // 잔액 차감 + 결과 결정만. 보유 상태는 hatched 진입 시점에 commit().
            let result = try Gacha.roll(useTicket: useTicket)
            phase = .egg(result)
            eggTapCount = 0
            eggShakeAngle = 0
            hatchInProgress = false
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .idle
        }
    }

    /// 알 탭 처리. 탭마다 점점 강하게 흔들리고, 임계치에 도달하면 cracking → hatched로 자동 진전.
    /// `hatchInProgress` 가드 — 임계 도달 후 250ms 동안 phase가 아직 `.egg`여서 추가 탭이
    /// race로 두 번째 시퀀스를 시작시키는 것을 방지 (방치 시 commit이 두 번 호출되어 count +2).
    private func tapEgg(_ pull: GachaPull) {
        guard case .egg = phase, !hatchInProgress else { return }
        eggTapCount += 1

        let intensity = min(1.0, Double(eggTapCount) / Double(Self.eggTapsRequired))
        let direction: Double = Bool.random() ? 1 : -1
        let angle = direction * Double.random(in: 18...32) * intensity

        withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) {
            eggShakeAngle = angle
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                eggShakeAngle = 0
            }
        }

        if eggTapCount >= Self.eggTapsRequired {
            hatchInProgress = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                crackStartedAt = Date()
                phase = .cracking(pull)
                try? await Task.sleep(nanoseconds: UInt64(Self.crackingDuration * 1_000_000_000))
                revealStartedAt = Date()
                phase = .revealing(pull)
                try? await Task.sleep(nanoseconds: UInt64(Self.revealDuration * 1_000_000_000))
                // 애니메이션 완료 시점에 비로소 보유 상태 반영 (인벤토리 해금).
                let resolved = Gacha.commit(pull)
                phase = .hatched(resolved)
            }
        }
    }

    // MARK: - Result area

    @ViewBuilder
    private var resultArea: some View {
        Group {
            switch phase {
            case .idle:
                if let msg = errorMessage {
                    Text(msg).foregroundStyle(.red).transition(.opacity)
                } else {
                    Text("뽑기를 돌려 펫을 만나보세요")
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            case .egg(let p):
                eggView(p).transition(.opacity)
            case .cracking(let p):
                crackingView(p).transition(.opacity)
            case .revealing(let p):
                revealingView(p).transition(.opacity)
            case .hatched(let p):
                hatchedView(p).transition(.opacity)
            case .preview(let k, let v):
                // .id로 kind/variant 바뀔 때마다 view 재마운트 → PetPreviewView 안의 enteredAt이 리셋되어
                // 슬라이드 애니메이션이 처음부터 다시 재생된다.
                PetPreviewView(kind: k, variant: v, settings: settings)
                    .id("\(k.rawValue)-\(v)")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .animation(.easeInOut(duration: 0.22), value: phaseKey)
    }

    // 기존 previewView/previewBubble/usageProgressView/formatRemaining 메소드는
    // 슬라이드 애니메이션 도입과 함께 PetPreviewView struct로 이동 (이 파일 하단 참고).

    /// phase enum의 동등성 비교용 (associated value 무시한 단순 식별자).
    /// `.animation(_:value:)`가 phase 변경을 감지하도록 한다.
    private var phaseKey: Int {
        switch phase {
        case .idle:      return 0
        case .egg:       return 1
        case .cracking:  return 2
        case .revealing: return 3
        case .hatched:   return 4
        case .preview:   return 5
        }
    }

    private func eggView(_ pull: GachaPull) -> some View {
        VStack(spacing: 8) {
            eggSprite
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(eggShakeAngle), anchor: .bottom)
                .onTapGesture { tapEgg(pull) }
                .contentShape(Rectangle())

            Text("탭하여 부화 (\(eggTapCount)/\(Self.eggTapsRequired))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 가챠 알 sprite. 자산 누락 시 EggShape으로 fallback.
    @ViewBuilder
    private var eggSprite: some View {
        if let img = PetSprite.image(named: "Egg") {
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            EggShape()
                .fill(Color(white: 0.95))
                .overlay(EggShape().stroke(Color.black.opacity(0.5), lineWidth: 1))
        }
    }

    /// `.cracking` 단계 시각화.
    /// - 0.0 ~ 0.6s: 균열 라인이 위에서 아래로 점진 그려짐 (trim).
    /// - 그 후: 알이 살짝 더 빠르게 진동 (부화 임박).
    private func crackingView(_ pull: GachaPull) -> some View {
        let startedAt = crackStartedAt ?? Date()
        return TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(startedAt)
            let crackProgress = min(1.0, elapsed / 0.6)
            let pulseFreq = elapsed < 0.6 ? 12.0 : 22.0
            let pulseAmp = elapsed < 0.6 ? 0.04 : 0.07
            let pulse = 1.0 + sin(elapsed * pulseFreq) * pulseAmp
            eggSprite
                .overlay(
                    CrackShape()
                        .trim(from: 0, to: crackProgress)
                        .stroke(Color.black, lineWidth: 1.5)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                )
                .frame(width: 96, height: 96)
                .scaleEffect(pulse)
        }
    }

    /// 부화 직후 연출. 시간 구간 (revealStartedAt 기준):
    ///   - 0.0 ~ 0.25s: 검은 배경 fade in + 알 burst-out (scale up + opacity down)
    ///   - 0.0 ~ 0.5s : 흰 flash 페이드아웃 (깜빡임)
    ///   - 0.5 ~ 1.5s : 어두운 실루엣
    ///   - 1.5 ~ 2.2s : 색상 fade in (실루엣 → 풀컬러)
    ///   - 마지막 0.4s: 검은 배경 fade out (hatched로 자연스럽게 연결)
    private func revealingView(_ pull: GachaPull) -> some View {
        let startedAt = revealStartedAt ?? Date()
        return TimelineView(.animation) { ctx in
            let elapsed = ctx.date.timeIntervalSince(startedAt)
            ZStack {
                // 검은 배경 — 들어올 땐 0.25s fade in. 나갈 때는 부모 cross-fade(0.22s)에
                // 맡기고 자체 fade out은 짧게(0.15s)만 — 두 효과가 겹쳐 굼뜨지 않게.
                let bgFadeIn = min(1.0, elapsed / 0.25)
                let fadeOutStart = Self.revealDuration - 0.15
                let bgFadeOut = elapsed > fadeOutStart
                    ? max(0, 1 - (elapsed - fadeOutStart) / 0.15)
                    : 1.0
                Color.black.opacity(bgFadeIn * bgFadeOut)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 알이 폭발하듯 사라짐 — cracking에서 살짝 진동 중이던 알이 그대로 fade out
                if elapsed < 0.35 {
                    let burst = elapsed / 0.35
                    eggSprite
                        .frame(width: 96, height: 96)
                        .scaleEffect(1 + burst * 0.5)
                        .opacity(1 - burst)
                }

                // 흰 flash 깜빡임
                if elapsed < 0.5 {
                    let envelope = max(0, 1 - elapsed / 0.5)
                    let blink = abs(sin(elapsed * 24))
                    Color.white.opacity(envelope * blink * 0.85)
                }

                // 펫 등장 (silhouette → fade in)
                if let img = PetSprite.image(for: pull.kind, action: .sit, frameIndex: 0) {
                    let appearAt: TimeInterval = 0.5
                    let silhouetteUntil: TimeInterval = 1.5
                    let revealDoneAt: TimeInterval = 2.2
                    let progress: Double = {
                        if elapsed < silhouetteUntil { return 0 }
                        return min(1, (elapsed - silhouetteUntil) / (revealDoneAt - silhouetteUntil))
                    }()
                    let multiplier = max(0.15, progress)

                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 84)
                        .hueRotation(.degrees(WalkingCat.hueDegrees(for: pull.variantUnlocked ?? 0)))
                        .colorMultiply(Color(white: multiplier))
                        .saturation(progress)
                        .opacity(elapsed < appearAt ? 0 : 1)
                        .offset(y: Self.spriteRestY)  // hatched의 sprite와 동일 위치
                }
            }
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hatchedView(_ pull: GachaPull) -> some View {
        // ZStack으로 revealing과 동일한 sprite 위치(spriteRestY)를 유지.
        // 메타데이터는 sprite 아래에 별도 묶음으로 배치.
        ZStack {
            if let img = PetSprite.image(for: pull.kind, action: .sit, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 84)
                    .hueRotation(.degrees(WalkingCat.hueDegrees(for: pull.variantUnlocked ?? 0)))
                    .saturation((pull.variantUnlocked ?? 0) > 0 ? 1.15 : 1.0)
                    .offset(y: Self.spriteRestY)
            }

            VStack(spacing: 5) {
                Text(pull.kind.displayName)
                    .font(.title3.weight(.bold))
                Text(pull.rarity.displayName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(rarityColor(pull.rarity).opacity(0.2))
                    .foregroundStyle(rarityColor(pull.rarity))
                    .clipShape(Capsule())

                if let v = pull.variantUnlocked, v > 0 {
                    Label("색상 변종 \(v) 해금!", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                } else if (settings.ownedPets[pull.kind]?.count ?? 0) == 1 {
                    Label("새 펫!", systemImage: "star.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.green)
                } else {
                    Text("중복 (\(settings.ownedPets[pull.kind]?.count ?? 0)마리째)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .offset(y: 50)  // sprite 아래에 배치 (sprite center=−38, 메타 center=+50 → ~88px 떨어짐)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 희귀한 등급 먼저 (위 → 아래).
                    ForEach([Rarity.legendary, .epic, .rare, .common], id: \.self) { r in
                        raritySection(r)
                    }
                }
            }
        }
    }

    private func raritySection(_ rarity: Rarity) -> some View {
        let kinds = Gacha.pool[rarity] ?? []
        let ownedCount = kinds.filter { settings.ownedPets[$0] != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(rarityColor(rarity))
                    .frame(width: 8, height: 8)
                Text(rarity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rarityColor(rarity))
                Spacer()
                Text("\(ownedCount)/\(kinds.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)], spacing: 12) {
                ForEach(kinds) { kind in
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
                            phase = .preview(kind, v)
                            errorMessage = nil
                        }
                    )
                }
            }
        }
    }

    private func rarityColor(_ r: Rarity) -> Color {
        switch r {
        case .common:    return .gray
        case .rare:      return .blue
        case .epic:      return .purple
        case .legendary: return .orange
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
                RoundedRectangle(cornerRadius: 6)
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
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHighlighted ? Color.yellow : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if ownership != nil { onTap?() }
            }
            .help(ownership == nil ? "잠김" : (isHighlighted ? "새로 해금 — 클릭하여 확인" : "클릭하여 미리보기"))

            Text(ownership == nil ? "?" : kind.displayName)
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
            }
        }
    }

    private func variantDot(_ i: Int) -> Color {
        switch i {
        case 0: return .gray
        case 1: return .yellow
        case 2: return .cyan
        case 3: return .pink
        default: return .gray
        }
    }
}

/// 알 윤곽: 위가 좁고 아래가 넓은 oval. cubic curve 4개로 구성.
struct EggShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        // 위 정점에서 시작 → 우상 → 우하 → 하 정점 → 좌하 → 좌상 → 닫기.
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY + h * 0.12),
            control1: CGPoint(x: rect.midX + w * 0.45, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.midY - h * 0.18)
        )
        p.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.05),
            control2: CGPoint(x: rect.midX + w * 0.42, y: rect.maxY)
        )
        p.addCurve(
            to: CGPoint(x: rect.minX, y: rect.midY + h * 0.12),
            control1: CGPoint(x: rect.midX - w * 0.42, y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - h * 0.05)
        )
        p.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.midY - h * 0.18),
            control2: CGPoint(x: rect.midX - w * 0.45, y: rect.minY)
        )
        return p
    }
}

/// 알 표면을 가로지르는 지그재그 균열 라인.
struct CrackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.18, y: rect.minY + rect.height * 0.22))
        p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.16, y: rect.minY + rect.height * 0.42))
        p.addLine(to: CGPoint(x: rect.midX - rect.width * 0.14, y: rect.minY + rect.height * 0.62))
        p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.20, y: rect.minY + rect.height * 0.80))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return p
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
    let variant: Int
    @ObservedObject var settings: Settings

    /// 마운트 시점. 슬라이드 progress(0→1) 계산의 기준.
    @State private var enteredAt: Date = Date()

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
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let elapsed = ctx.date.timeIntervalSince(enteredAt)
            // easeInOut(0..1) — sliding feel.
            let raw = max(0, min(1, elapsed / Self.slideDuration))
            let progress = Self.easeInOut(raw)

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
            let currentQuote = quotes[quoteIdx]

            // 슬라이드 진행 — sprite 그룹의 x offset (음수 = 좌측 이동).
            let slideX = Self.slideEndX * progress
            // description 카드는 우측에서 +30 → descEndX로 살짝 슬라이드인 + 페이드인.
            // progress 0.3부터 페이드인 시작 → 1.0에 완료 (sprite 슬라이드와 살짝 겹치게).
            let descOpacity = max(0, (progress - 0.3) / 0.7)
            let descX = Self.descEndX + (1 - progress) * 30

            ZStack {
                // ─── 펫 그룹 (sprite + 말풍선 + 이름 + 게이지) — 좌측으로 슬라이드 ───
                ZStack {
                    if !frames.isEmpty {
                        Image(nsImage: frames[frameIdx])
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                            .frame(height: 84)
                            .scaleEffect(x: flip ? -1 : 1, y: 1)
                            .hueRotation(.degrees(WalkingCat.hueDegrees(for: variant)))
                            .saturation(variant > 0 ? 1.15 : 1.0)
                            .offset(x: swingX, y: Self.spriteRestY)
                    }

                    Self.bubble(currentQuote)
                        .fixedSize()
                        .offset(y: Self.spriteRestY - 56)
                        .id(quoteIdx)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: quoteIdx)

                    VStack(spacing: 4) {
                        Text(kind.displayName)
                            .font(.title3.weight(.medium))
                        if variant > 0 {
                            Text(String(repeating: "✨", count: variant))
                                .font(.caption)
                        } else {
                            Text("기본")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        usageProgressView()
                    }
                    .offset(y: 50)
                }
                .offset(x: slideX)

                // ─── 우측 캐릭터 설명 카드 — 페이드인 + slide-in ───
                descriptionCard
                    .opacity(descOpacity)
                    .offset(x: descX)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { enteredAt = Date() }
    }

    /// 우측 도감 카드 — 포켓몬 도감 톤. 컬러 헤더 (ID + 이름 + rarity 태그) + 어두운 본문 패널.
    /// 폭(160)은 펫의 ±60 swing 가동 범위와 겹치지 않게 좁게 유지.
    private var descriptionCard: some View {
        let dexNum = Self.dexNumber(for: kind)
        let r = Self.rarity(of: kind)
        let headerColor = Self.rarityColor(r)

        return VStack(alignment: .leading, spacing: 0) {
            // 헤더 — rarity 색상의 띠. ID + 이름 + 등급.
            HStack(spacing: 5) {
                Text(String(format: "#%03d", dexNum))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                Text(kind.displayName)
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

            // 본문 — 도감 화면처럼 살짝 들어간 inset 패널 느낌.
            Text(PetDescriptions.description(for: kind))
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.10))
        }
        .frame(width: Self.descCardWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(headerColor.opacity(0.55), lineWidth: 1.2)
        )
    }

    /// 도감 ID — `PetKind.allCases` 순서를 그대로 dex 번호로 사용. 새 펫이 enum 끝에 추가되면
    /// 자연스럽게 다음 번호를 받음 (포켓몬 도감처럼 #001부터 1-based).
    private static func dexNumber(for kind: PetKind) -> Int {
        (PetKind.allCases.firstIndex(of: kind) ?? 0) + 1
    }

    /// 펫이 속한 rarity 조회. `Gacha.pool`에서 역방향 검색.
    private static func rarity(of kind: PetKind) -> Rarity? {
        for tier in [Rarity.legendary, .epic, .rare, .common] {
            if (Gacha.pool[tier] ?? []).contains(kind) { return tier }
        }
        return nil
    }

    /// rarity 색상 — GachaView의 private rarityColor와 동일한 매핑 (struct 분리로 재선언).
    private static func rarityColor(_ r: Rarity?) -> Color {
        switch r {
        case .legendary: return .orange
        case .epic:      return .purple
        case .rare:      return .blue
        case .common:    return .gray
        case .none:      return .gray
        }
    }

    /// rarity → 별 카운트. 헤더 우측에 컴팩트한 등급 표시로 사용 (LEGENDARY 줄바꿈 회피).
    private static func rarityStars(_ r: Rarity) -> String {
        switch r {
        case .common:    return "★"
        case .rare:      return "★★"
        case .epic:      return "★★★"
        case .legendary: return "★★★★"
        }
    }

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

    /// 말풍선 외형 — WalkingCat의 quote bubble과 동일하게 매칭.
    private static func bubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
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
final class GachaWindowController: NSWindowController {
    static let shared = GachaWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: GachaView())
        let window = NSWindow(contentViewController: host)
        window.title = "가챠 · 도감"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
