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
    /// 10연차 결과 그리드에서 지금까지 공개된 칸 수. 0부터 한 칸씩 "다다다닥" 늘어난다.
    @State private var revealedCount: Int = 0
    /// 순차 공개 타이머 Task — 재진입 시 취소용.
    @State private var revealTask: Task<Void, Never>?
    /// 10연차 진행 확인 alert 트리거. 버튼 클릭 시 즉시 진행 대신 이 값을 set → yes/no 확인.
    @State private var confirmingMultiPull: Bool = false
    /// 상점/도장/레포트/랭킹 탭. 첫 진입 .shop, 가챠 hatch 중에는 잠금.
    @State private var selectedTab: Tab = .shop

    enum Tab: String, CaseIterable, Identifiable {
        case shop, party, gym, report, ranking
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .shop:    return "상점"
            case .party:   return "파티"
            case .gym:     return "도장"
            case .report:  return "레포트"
            case .ranking: return "랭킹"
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
    /// 10연차 placeholder 연출 길이. 전용 에셋 도입 시 이 값/`multiRollingView`만 교체하면 된다.
    private static let multiRevealDuration: TimeInterval = 2.0
    /// 결과 그리드 칸 사이 공개 간격(초). 짧을수록 "다다다닥" 빨라진다.
    private static let multiRevealStagger: TimeInterval = 0.065

    enum ResultPhase {
        case idle
        case egg(GachaPull)
        case cracking(GachaPull)
        case revealing(GachaPull)  // 암전 + flash + 실루엣 + fade in
        case hatched(GachaPull)
        case preview(PetKind, Int) // 인벤토리에서 클릭한 보유 펫 미리보기
        case multiRolling([GachaPull])       // 10연차 연출 재생 중 (commit 전)
        case multiHatched([MultiPullResult]) // 10연차 결과 그리드
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
                switch selectedTab {
                case .shop:    shopTab.transition(.opacity)
                case .party:   PartyView().transition(.opacity)
                case .gym:     GymView().transition(.opacity)
                case .report:  ReportView().transition(.opacity)
                case .ranking: RankingView().transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: selectedTab)
        }
        .frame(width: 480, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: .gachaSwitchTab)) { notif in
            if let tab = notif.object as? Tab { selectedTab = tab }
        }
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
        .alert("10연차 뽑기", isPresented: $confirmingMultiPull) {
            Button("진행") { pull10() }
            Button("취소", role: .cancel) {}
        } message: {
            Text(multiPullConfirmMessage)
        }
    }

    /// 10연차 확인 alert 메시지 — 차감될 가챠권/코인 + 현재 잔액을 명시.
    private var multiPullConfirmMessage: String {
        let (used, coin) = Gacha.multiPullCost(tickets: settings.gachaTickets)
        var parts: [String] = []
        if used > 0 { parts.append("가챠권 \(used)장") }
        if coin > 0 { parts.append("\(coin)코인") }
        if parts.isEmpty { parts.append("무료") }
        let cost = parts.joined(separator: " + ")
        return "10회를 한 번에 뽑습니다.\n비용: \(cost)\n현재 잔액: \(settings.coins)코인 · 가챠권 \(settings.gachaTickets)장"
    }

    /// 가챠 hatch 시퀀스(cracking/revealing)는 펫 commit 전이라 picker 잠금.
    /// idle/egg/hatched/preview 단계는 다른 탭 봐도 OK.
    /// (`hatchInProgress`는 .hatched 진입 후 reset 안 되어 picker 영구 잠금 버그가 있어 — phase만 검사)
    private var isHatchingMidAction: Bool {
        switch phase {
        case .cracking, .revealing, .multiRolling: return true
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
            Spacer()
            HStack(spacing: 8) {
                Button(action: pull) {
                    VStack(spacing: 1) {
                        Text("1회 뽑기").font(.system(size: 12, weight: .bold))
                        Text(settings.gachaTickets > 0 ? "무료" : "\(Gacha.pullCost)코인")
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .frame(minWidth: 56)
                }
                .buttonStyle(.bordered)
                .disabled(!canPull)

                Button(action: { confirmingMultiPull = true }) {
                    VStack(spacing: 1) {
                        Text("10연차").font(.system(size: 12, weight: .bold))
                        Text(multiPullCostLabel)
                            .font(.system(size: 9, design: .monospaced))
                    }
                    .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPull10)
            }
        }
    }

    private var canPull: Bool {
        !isPullInProgress && (settings.gachaTickets > 0 || settings.coins >= Gacha.pullCost)
    }

    /// 10연차 가능 여부 — 티켓 우선 차감 후 남는 코인 비용을 감당할 수 있으면 OK.
    private var canPull10: Bool {
        !isPullInProgress && Gacha.multiPullCost(tickets: settings.gachaTickets).coinCost <= settings.coins
    }

    /// 10연차 버튼 비용 라벨. 티켓 소모분 + 코인 분담을 짧게 표기.
    private var multiPullCostLabel: String {
        let (used, coin) = Gacha.multiPullCost(tickets: settings.gachaTickets)
        if used > 0 && coin > 0 { return "🎟️\(used)+\(coin)" }
        if used > 0 && coin == 0 { return "🎟️\(used) 무료" }
        return "\(coin)코인"
    }

    /// 가챠 부화 시퀀스가 시작된 후 commit 직전까지의 phase 집합. 이 동안엔 새 가챠 진입을
    /// 막아야 한다 — 안 막으면 빠른 더블 클릭이 `pull()`을 두 번 호출해서 잔액만 두 번
    /// 차감되고 첫 결과는 `phase = .egg(pull2)`로 덮어쓰여 commit 안 되고 사라짐.
    private var isPullInProgress: Bool {
        switch phase {
        case .egg, .cracking, .revealing, .multiRolling:    return true
        case .idle, .hatched, .preview, .multiHatched:      return false
        }
    }

    private func pull() {
        // Button.disabled가 1차 가드. 진입 가드는 키보드 단축키·접근성 등 우회 경로
        // 대비한 2차 방어선.
        guard !isPullInProgress else { return }

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

    /// 10연차 진행. 단일 `pull`과 달리 탭 없이 자동 재생 — `rollMulti`로 선차감 + 10개 결정 후
    /// placeholder 연출(`multiRevealDuration`) 재생, 완료 시점에 `commitMulti`로 일괄 반영한다.
    /// 전용 에셋이 들어오면 `multiRollingView`/`multiRevealDuration`만 교체하면 된다.
    private func pull10() {
        guard !isPullInProgress else { return }
        do {
            let pulls = try Gacha.rollMulti()
            phase = .multiRolling(pulls)
            errorMessage = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(Self.multiRevealDuration * 1_000_000_000))
                // 연출 완료 시점에 비로소 보유 상태 반영 (인벤토리 해금).
                let results = Gacha.commitMulti(pulls)
                revealedCount = 0   // 첫 프레임부터 0칸 → onAppear에서 한 칸씩 공개 (깜빡임 방지).
                phase = .multiHatched(results)
            }
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
            case .multiRolling(let pulls):
                multiRollingView(pulls).transition(.opacity)
            case .multiHatched(let results):
                multiHatchedView(results).transition(.opacity)
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
        case .multiRolling:  return 6
        case .multiHatched:  return 7
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
        // 펜딩 컬렉션 컴플리트가 있으면 상단에 배너 오버레이 — `.hatched` 진입 시
        // `Settings.pendingCollectionCelebration`이 set돼있으면 노출하고 onAppear에서 nil로 소비.
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
                Text(PetMetaStore.shared.displayName(for: pull.kind))
                    .font(.title3.weight(.bold))
                Text(pull.rarity.displayName)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(pull.rarity.color.opacity(0.2))
                    .foregroundStyle(pull.rarity.color)
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
        .overlay(alignment: .top) {
            if let raw = settings.pendingCollectionCelebration,
               let c = PetCollection(rawValue: raw) {
                CollectionCompleteBanner(collection: c) {
                    settings.pendingCollectionCelebration = nil
                }
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.pendingCollectionCelebration)
    }

    // MARK: - 10연차 (multi pull)

    /// 10연차 placeholder 연출 — 전용 에셋 도입 전까지의 임시 화면. 텍스트 없이 알이 격하게
    /// 흔들/팝하고 뒤에서 glow가 throb, sparkle 링이 회전해 "곧 터질 듯한" 역동성을 준다.
    /// 자산이 들어오면 이 함수와 `multiRevealDuration`만 교체하면 된다.
    private func multiRollingView(_ pulls: [GachaPull]) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // 고주파 흔들림 + 팝 스케일 + 상하 바운스.
            let wobble = sin(t * 24) * 16 + sin(t * 9) * 6
            let pop = 1.0 + 0.14 * sin(t * 13)
            let bob = sin(t * 17) * 5
            let throb = abs(sin(t * 5))
            ZStack {
                // 뒤에서 맥동하는 glow.
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 120, height: 120)
                    .scaleEffect(0.85 + 0.3 * throb)
                    .blur(radius: 26)
                    .opacity(0.25 + 0.35 * throb)
                // 회전하는 sparkle 링.
                ForEach(0..<6, id: \.self) { i in
                    let ang = t * 2.4 + Double(i) * (.pi * 2 / 6)
                    let radius = 58.0 + 10 * sin(t * 6 + Double(i))
                    Image(systemName: "sparkle")
                        .font(.system(size: 13))
                        .foregroundStyle(.yellow)
                        .opacity(0.4 + 0.6 * abs(sin(t * 4 + Double(i))))
                        .offset(x: cos(ang) * radius, y: sin(ang) * radius)
                }
                // 알.
                eggSprite
                    .frame(width: 96, height: 96)
                    .scaleEffect(pop)
                    .rotationEffect(.degrees(wobble), anchor: .bottom)
                    .offset(y: bob)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 결과 그리드 진입 시 0칸부터 한 칸씩 빠르게 공개. 재진입 대비 이전 Task는 취소.
    private func startSequentialReveal(total: Int) {
        revealTask?.cancel()
        revealedCount = 0
        revealTask = Task { @MainActor in
            for i in 1...max(1, total) {
                try? await Task.sleep(nanoseconds: UInt64(Self.multiRevealStagger * 1_000_000_000))
                if Task.isCancelled { return }
                revealedCount = i
            }
        }
    }

    /// 10연차 결과 그리드 — 2×5. halo로 신규/중복 구분, 상단 요약 + 하단 확인 버튼.
    /// 컬렉션 컴플리트 배너는 `hatchedView`와 동일하게 상단 오버레이로 재사용.
    private func multiHatchedView(_ results: [MultiPullResult]) -> some View {
        let newCount = results.filter { $0.isNew }.count
        let dupCount = results.count - newCount
        let revealDone = revealedCount >= results.count
        return VStack(spacing: 10) {
            // 모든 칸 공개가 끝난 뒤에야 요약 노출 — 카운트 스포일러 방지. 자리는 항상 차지(레이아웃 고정).
            HStack(spacing: 12) {
                Label("신규 \(newCount)", systemImage: "sparkles")
                    .foregroundStyle(.green)
                Label("중복 \(dupCount)", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .semibold))
            .opacity(revealDone ? 1 : 0)
            .animation(.easeIn(duration: 0.2), value: revealDone)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 10) {
                ForEach(Array(results.enumerated()), id: \.offset) { (i, r) in
                    // 슬롯은 항상 자리 차지(레이아웃 고정), 내용만 i < revealedCount일 때 팝-인.
                    multiResultCell(r)
                        .opacity(i < revealedCount ? 1 : 0)
                        .scaleEffect(i < revealedCount ? 1 : 0.4)
                        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: revealedCount)
                }
            }

            Button("확인") { phase = .idle }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear { startSequentialReveal(total: results.count) }
        .overlay(alignment: .top) {
            if let raw = settings.pendingCollectionCelebration,
               let c = PetCollection(rawValue: raw) {
                CollectionCompleteBanner(collection: c) {
                    settings.pendingCollectionCelebration = nil
                }
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.pendingCollectionCelebration)
    }

    /// 결과 한 칸 — halo로 신규/중복 구분 (신규=밝은 등급색, 중복=회색+흐림). 별도 뱃지 없음.
    private func multiResultCell(_ r: MultiPullResult) -> some View {
        let variant = r.pull.variantUnlocked ?? 0
        let haloColor = r.isNew ? r.pull.rarity.color : Color.gray
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(haloColor)
                    .frame(width: 52, height: 52)
                    .blur(radius: 9)
                    .opacity(r.isNew ? 0.85 : 0.30)
                if let img = PetSprite.image(for: r.pull.kind, action: .sit, frameIndex: 0) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 44, height: 44)
                        .hueRotation(.degrees(WalkingCat.hueDegrees(for: variant)))
                        .saturation(r.isNew ? (variant > 0 ? 1.15 : 1.0) : 0.55)
                        .opacity(r.isNew ? 1.0 : 0.6)
                }
            }
            Text(PetMetaStore.shared.displayName(for: r.pull.kind))
                .font(.system(size: 9))
                .lineLimit(1)
                .foregroundStyle(r.isNew ? .primary : .secondary)
                .frame(maxWidth: .infinity)
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
                VStack(alignment: .leading, spacing: 14) {
                    // 희귀한 등급 먼저 (위 → 아래).
                    ForEach([Rarity.legendary, .epic, .rare, .common], id: \.self) { r in
                        raritySection(r)
                    }
                    // 컬렉션 업적 섹션 — rarity 레이아웃 그대로 유지하고 그 아래에 묶음.
                    Divider().padding(.vertical, 4)
                    collectionsAchievementSection()
                }
            }
        }
    }

    // MARK: - Collections (셋 보너스 업적)

    /// 펫 컬렉션(셋 보너스) 뱃지 그리드 11개. 완성된 그룹은 accentColor + ✓,
    /// 미완성은 회색 + 진행도(`5/8`). 코드네임/농담/보너스는 호버 시 `.help` tooltip으로 노출
    /// — 뱃지 자체는 작고 균일한 사이즈(56px)로 깔끔하게 통일.
    private func collectionsAchievementSection() -> some View {
        let totalCompleted = settings.completedCollections.count
        let totalCollections = PetCollection.allCases.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .foregroundStyle(.yellow)
                Text("업적")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(totalCompleted)/\(totalCollections)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 10)], spacing: 12) {
                ForEach(PetCollection.allCases, id: \.self) { c in
                    CollectionBadge(collection: c, settings: settings)
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
                    .fill(rarity.color)
                    .frame(width: 8, height: 8)
                Text(rarity.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rarity.color)
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
            }
        }
    }

    private func variantDot(_ i: Int) -> Color { WalkingCat.variantDotColor(i) }
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
            RoundedRectangle(cornerRadius: 10)
                .fill(collection.accentColor)
                .shadow(color: collection.accentColor.opacity(0.6), radius: pulse ? 12 : 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
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
            Text(isComplete ? "✓" : "\(progress.collected)/\(progress.total)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(isComplete ? color : .secondary)
                .monospacedDigit()
        }
        .frame(width: 60, height: 70)
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
    @ObservedObject var settings: Settings

    /// 마운트 시점. 슬라이드 progress(0→1) 계산의 기준.
    @State private var enteredAt: Date = Date()

    /// 사용자가 dot selector로 토글하는 현재 variant. init 시점의 variant로 시드.
    /// 외부에서 variant 변경은 .id() 재마운트로 처리 (다른 펫 → 새 PetPreviewView 인스턴스).
    /// 같은 펫 안에서 이로치 토글은 internal state라 슬라이드 애니메이션 재생 X — 즉시 hue 변경.
    @State private var selectedVariant: Int
    /// hover 중인 칩의 이펙트 — 구매/장착 전 미리보기 펫에 임시 적용. nil이면 없음. (PetEffectShelf가 콜백으로 갱신.)
    @State private var previewEffect: EffectKind? = nil

    init(kind: PetKind, variant: Int, settings: Settings) {
        self.kind = kind
        self._selectedVariant = State(initialValue: variant)
        self.settings = settings
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
                        // 장착 이펙트 + hover 프리뷰를 펫과 같은 고정 프레임에서 함께 렌더.
                        let fx = (settings.equippedEffects[kind] ?? [])
                            .union(previewEffect.map { [$0] } ?? [])
                        ZStack {
                            PetEffectOverlay(effects: fx, placement: .backdrop,
                                             center: CGPoint(x: 55, y: 55), footY: 95,
                                             petHeight: 70, facingRight: movingRight, isMoving: true)
                            Image(nsImage: frames[frameIdx])
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 84)
                                .scaleEffect(x: flip ? -1 : 1, y: 1)
                                .hueRotation(.degrees(WalkingCat.hueDegrees(for: selectedVariant)))
                                .saturation(selectedVariant > 0 ? 1.15 : 1.0)
                            PetEffectOverlay(effects: fx, placement: .particles,
                                             center: CGPoint(x: 55, y: 55), footY: 95,
                                             petHeight: 70, facingRight: movingRight, isMoving: true)
                        }
                        .frame(width: 110, height: 110)
                        .offset(x: swingX, y: Self.spriteRestY)
                    }

                    Self.bubble(currentQuote)
                        .fixedSize()
                        .offset(y: Self.spriteRestY - 56)
                        .id(quoteIdx)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.35), value: quoteIdx)

                    VStack(spacing: 4) {
                        Text(PetMetaStore.shared.displayName(for: kind))
                            .font(.title3.weight(.medium))
                        if selectedVariant > 0 {
                            Text(String(repeating: "✨", count: selectedVariant))
                                .font(.caption)
                        } else {
                            Text("기본")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        variantSelector
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
        // 칩 바는 미리보기 영역 밖(아래 독립 행) — 펫 슬라이드(slideX)·variant와 분리되어 잘리지 않는다.
        // 공용 PetEffectShelf 재활용. hover 프리뷰는 previewEffect로 받아 미리보기 펫에 임시 반영.
        PetEffectShelf(kind: kind, settings: settings, onPreview: { previewEffect = $0 })
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .onAppear { enteredAt = Date() }
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

            // 본문 — 도감 화면처럼 살짝 들어간 inset 패널 느낌.
            Text(PetMetaStore.shared.description(for: kind))
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

    /// rarity → 별 카운트. 헤더 우측에 컴팩트한 등급 표시로 사용 (LEGENDARY 줄바꿈 회피).
    private static func rarityStars(_ r: Rarity) -> String {
        switch r {
        case .common:    return "★"
        case .rare:      return "★★"
        case .epic:      return "★★★"
        case .legendary: return "★★★★"
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

    /// 윈도우를 띄우면서 특정 탭으로 전환. `tab=nil`이면 마지막 선택 상태 유지.
    /// 외부(SettingsView 등)가 "보드 열기" 같은 라우팅에 사용.
    func present(tab: GachaView.Tab? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let tab {
            NotificationCenter.default.post(name: .gachaSwitchTab, object: tab)
        }
    }
}

extension Notification.Name {
    /// GachaView가 외부 요청으로 탭 전환할 때 사용. object = GachaView.Tab.
    static let gachaSwitchTab = Notification.Name("gachaSwitchTab")
}
