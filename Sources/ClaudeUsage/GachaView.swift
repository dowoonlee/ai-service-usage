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

    /// 알을 깨는 데 필요한 탭 수.
    private static let eggTapsRequired: Int = 6
    /// cracking → hatched 사이 머무는 시간.
    private static let crackingDuration: TimeInterval = 1.0

    enum ResultPhase {
        case idle
        case egg(GachaPull)
        case cracking(GachaPull)
        case hatched(GachaPull)
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            resultArea
            Divider()
            inventorySection
        }
        .padding(20)
        .frame(width: 480, height: 640)
    }

    // MARK: - Header (잔액 + 뽑기 버튼)

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(.yellow)
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
            let result = try Gacha.performPull(useTicket: useTicket)
            phase = .egg(result)
            eggTapCount = 0
            eggShakeAngle = 0
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .idle
        }
    }

    /// 알 탭 처리. 탭마다 점점 강하게 흔들리고, 임계치에 도달하면 cracking → hatched로 자동 진전.
    private func tapEgg(_ pull: GachaPull) {
        guard case .egg = phase else { return }
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
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                withAnimation(.easeInOut(duration: 0.3)) {
                    phase = .cracking(pull)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.crackingDuration * 1_000_000_000))
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    phase = .hatched(pull)
                }
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
                    Text(msg).foregroundStyle(.red)
                } else {
                    Text("뽑기를 돌려 펫을 만나보세요")
                        .foregroundStyle(.secondary)
                }
            case .egg(let p):
                eggView(p)
            case .cracking(let p):
                crackingView(p)
            case .hatched(let p):
                hatchedView(p)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private func eggView(_ pull: GachaPull) -> some View {
        VStack(spacing: 8) {
            EggShape()
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.78)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(EggShape().stroke(Color.black.opacity(0.55), lineWidth: 1.2))
                .overlay(eggSpots)
                .frame(width: 80, height: 100)
                .rotationEffect(.degrees(eggShakeAngle), anchor: .bottom)
                .onTapGesture { tapEgg(pull) }
                .contentShape(Rectangle())

            Text("탭하여 부화 (\(eggTapCount)/\(Self.eggTapsRequired))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// 알 표면의 점박이 무늬.
    private var eggSpots: some View {
        ZStack {
            Circle().fill(Color.brown.opacity(0.55)).frame(width: 9, height: 9).offset(x: -12, y: -4)
            Circle().fill(Color.brown.opacity(0.55)).frame(width: 6, height: 6).offset(x: 8, y: -14)
            Circle().fill(Color.brown.opacity(0.55)).frame(width: 5, height: 5).offset(x: 14, y: 12)
            Circle().fill(Color.brown.opacity(0.55)).frame(width: 7, height: 7).offset(x: -6, y: 18)
        }
    }

    private func crackingView(_ pull: GachaPull) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 1.0 + sin(t * 16) * 0.06
            EggShape()
                .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.78)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(EggShape().stroke(Color.black.opacity(0.55), lineWidth: 1.2))
                .overlay(eggSpots)
                .overlay(
                    CrackShape()
                        .stroke(Color.black, lineWidth: 1.5)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                )
                .frame(width: 80, height: 100)
                .scaleEffect(pulse)
        }
    }

    private func hatchedView(_ pull: GachaPull) -> some View {
        VStack(spacing: 6) {
            if let img = PetSprite.image(for: pull.kind, action: .sit, frameIndex: 0) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 64)
                    .hueRotation(.degrees(WalkingCat.hueDegrees(for: pull.variantUnlocked ?? 0)))
                    .saturation((pull.variantUnlocked ?? 0) > 0 ? 1.15 : 1.0)
            }
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
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 10)], spacing: 12) {
                    ForEach(PetKind.allCases) { kind in
                        InventorySlot(kind: kind, ownership: settings.ownedPets[kind])
                    }
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

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
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
            }
            .frame(width: 60, height: 60)

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
