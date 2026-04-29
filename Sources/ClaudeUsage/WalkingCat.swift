import SwiftUI
import Charts

// quote 말풍선 크기를 부모로 전달하기 위한 PreferenceKey.
// GeometryReader로 측정한 사이즈를 onPreferenceChange가 @State로 끌어올린다.
private struct QuoteBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

private struct WellnessBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

// 노란 spiky 말풍선용 별 모양 starburst 외곽선.
// 짝수 스텝에서 outer 반경, 홀수에서 inner 반경을 찍어 톱니/번개 느낌의 폴리곤을 만든다.
struct SpikyBubble: Shape {
    var spikes: Int = 18
    var spikeDepth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let outerW = rect.width / 2
        let outerH = rect.height / 2
        let innerW = max(1, outerW - spikeDepth)
        let innerH = max(1, outerH - spikeDepth)
        var path = Path()
        let steps = spikes * 2
        for i in 0..<steps {
            let angle = (Double(i) / Double(steps)) * 2 * .pi - .pi / 2
            let isOuter = i % 2 == 0
            let rx = isOuter ? outerW : innerW
            let ry = isOuter ? outerH : innerH
            let x = cx + cos(angle) * rx
            let y = cy + sin(angle) * ry
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }
}

// 차트 라인 위에서 걷고 쉬고 두리번거리는 펫.
// 표시는 Animated Wild Animals (CC0) 프레임 strip 기반,
// 행동/위치/현재 frame은 PetController가 보유.
struct WalkingCat: View {
    let points: [(Date, Double)]   // 시간순 정렬 가정
    let proxy: ChartProxy
    let plotFrame: CGRect          // 차트 plot rect (좌표 변환 + 말풍선 클램프 용)
    var kind: PetKind = .fox
    /// 색상 변종 (이로치). 0 = 기본, 1/2/3 = shiny tier. hueRotation 각도로 매핑.
    var variant: Int = 0
    var mood: PetMood = .neutral
    var displayHeight: CGFloat = 18
    // 차트 한 구간이 전체 y-range 대비 이 비율 이상일 때 AAAH/WHEE 말풍선 발동. 낮을수록 자주.
    var bigDropThreshold: Double = 0.40
    // ViewModel이 1시간 연속 사용 감지 시 채워주는 휴식 권유 멘트.
    // nil이면 표시 안 함. tap 시 onDismissWellness 호출.
    var wellnessNudge: String? = nil
    /// 클릭 결과를 받아 보상 여부에 따라 코인 popping을 띄움.
    var onDismissWellness: (() -> WellnessDismissResult)? = nil

    @StateObject private var ctrl = PetController()
    @State private var bubbleSize: CGSize = .zero
    @State private var wellnessBubbleSize: CGSize = .zero
    // wellness 말풍선 등장 직후 3초간 blink 시키는 opacity 상태.
    @State private var wellnessOpacity: Double = 1.0
    @State private var wellnessBlinkTask: Task<Void, Never>?
    /// wellness nudge 보상 클릭 시 튀어오르는 코인 파티클.
    @State private var coinPops: [CoinPopParticle] = []
    /// 보상 받은 코인 액수("+50") 말풍선. 한 번에 하나만, 위로 떠오르며 페이드아웃.
    @State private var rewardAmountPop: (origin: CGPoint, amount: Int, createdAt: Date)?

    var body: some View {
        // mood는 매 render마다 컨트롤러에 동기화 (publish 아님 → 경고 없음)
        ctrl.mood = mood
        // 큰 낙폭 segment 통과 중에는 펫 속도를 1/1.5배로 늦춰서
        // 굴러떨어짐/점프와 말풍선이 1.5배 더 오래 보이도록.
        ctrl.speedMultiplier = (bigDropDescent(at: ctrl.x) != 0) ? (1.0 / 1.5) : 1.0
        // 코인 popping/보상 말풍선은 sprite의 if-let pos 분기 안에 묶여 있으면 차트 데이터가
        // 일시적으로 비어 sprite가 사라질 때 같이 사라진다. ZStack의 sibling으로 빼서 보상
        // 연출이 1초 내내 보이도록 보장.
        return ZStack {
            sprite()
            coinPopOverlay.allowsHitTesting(false)
            rewardAmountOverlay.allowsHitTesting(false)
        }
            .onPreferenceChange(QuoteBubbleSizeKey.self) { bubbleSize = $0 }
            .onPreferenceChange(WellnessBubbleSizeKey.self) { wellnessBubbleSize = $0 }
            .onAppear { ctrl.start() }
            .onDisappear {
                ctrl.stop()
                wellnessBlinkTask?.cancel()
            }
            .onChange(of: wellnessNudge) { _, newValue in
                wellnessBlinkTask?.cancel()
                guard newValue != nil else {
                    wellnessOpacity = 1.0
                    return
                }
                wellnessOpacity = 1.0
                wellnessBlinkTask = Task { @MainActor in
                    let start = Date()
                    // 3초 동안 4Hz blink (50ms 폴링), 끝나면 1.0으로 settle.
                    while !Task.isCancelled {
                        let elapsed = Date().timeIntervalSince(start)
                        if elapsed >= 3.0 {
                            wellnessOpacity = 1.0
                            return
                        }
                        let phase = (elapsed * 4).truncatingRemainder(dividingBy: 1.0)
                        wellnessOpacity = phase < 0.5 ? 1.0 : 0.25
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
            }
    }

    @ViewBuilder
    private func sprite() -> some View {
        if let pos = positionFor(xNorm: ctrl.x),
           let nsImg = PetSprite.image(for: kind, action: ctrl.action, frameIndex: ctrl.frameIndex) {
            let (cw, ch) = kind.cellSize
            let aspect = Double(cw) / Double(ch)
            let w = displayHeight * aspect
            let h = displayHeight
            // jitter: 불안할수록 매 프레임 위치 떨림
            let jx: Double = mood.jitter > 0 ? Double.random(in: -mood.jitter...mood.jitter) : 0
            let jy: Double = mood.jitter > 0 ? Double.random(in: -mood.jitter...mood.jitter) : 0

            // 큰 낙폭 구간 통과 중일 때의 추가 모션 (walk/run 한정)
            let descent = bigDropDescent(at: ctrl.x)
            let isMoving = ctrl.action == .walk || ctrl.action == .run
            let now = Date().timeIntervalSinceReferenceDate
            // descent > 0: 내려가는 중 → 굴러 떨어짐 (회전 + 비명)
            // descent < 0: 올라가는 중 → 점프 (위로 튀어오름 + 환호)
            let rollAngle: Double = (isMoving && descent > 0) ? now * 360 * 2 : 0
            let jumpY: Double = (isMoving && descent < 0) ? abs(sin(now * 4)) * 14 : 0

            Image(nsImage: nsImg)
                .resizable()
                .interpolation(.none)
                .frame(width: w, height: h)
                // sprite가 기본 향한 방향과 진행 방향이 다르면 반전.
                // (Wild Animals=좌향, Pixel Adventure=우향)
                .scaleEffect(
                    x: kind.defaultFacingLeft == ctrl.facingRight ? -1 : 1,
                    y: 1,
                    anchor: .center
                )
                .rotationEffect(.degrees(rollAngle), anchor: .center)
                .hueRotation(.degrees(Self.hueDegrees(for: variant)))
                .saturation(variant == 0 ? 1.0 : 1.15)
                .colorMultiply(mood.tint)
                // 작은 sprite(18pt) 위 hover 감지를 쉽게 하려고 32x32 hit area로 확장.
                .frame(width: max(w, 32), height: max(h, 32))
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    // 보상 popping 진행 중엔 reaction 말풍선이 코인 위에 겹쳐 보이지 않도록 차단.
                    if case .active = phase, coinPops.isEmpty {
                        ctrl.startFleeFromMouse()
                    }
                }
                .position(
                    x: pos.x + jx,
                    y: pos.y - h / 2 + jy - jumpY
                )

            // 굴러 떨어지는 중(descent > 0)일 때만 우측에 비명 말풍선.
            // 펫의 rotationEffect와 무관하게 upright 유지하려고 sibling으로 배치.
            if isMoving && descent > 0 {
                bubble("AAAH!")
                    .position(
                        x: pos.x + jx + w / 2 + 18,
                        y: pos.y - h * 0.85 + jy
                    )
                    .allowsHitTesting(false)
            }

            // 점프하며 올라가는 중(descent < 0)일 때 우측에 환호 말풍선.
            // 펫이 위아래 튀므로 jumpY 만큼 함께 올려서 따라다니게 함.
            if isMoving && descent < 0 {
                bubble("WHEE!")
                    .position(
                        x: pos.x + jx + w / 2 + 18,
                        y: pos.y - h * 0.85 + jy - jumpY
                    )
                    .allowsHitTesting(false)
            }

            // quote 동작 중이면 명언 말풍선 표시 (7초 고정).
            // 위치 결정: 기본은 펫 머리 위, plot 좌/우 경계에서는 안쪽으로 시프트,
            // 머리 위가 plot 윗면을 넘으면 펫 아래로 뒤집음.
            if ctrl.action == .quote, let quote = ctrl.currentQuote {
                let bw = bubbleSize.width
                let bh = bubbleSize.height
                let petX = pos.x + jx
                let petY = pos.y + jy

                // 가로: 펫 위 기본, plot 안쪽으로 클램프 (말풍선이 plot보다 넓으면 그대로 둠).
                let minX = plotFrame.minX + 2 + bw / 2
                let maxX = plotFrame.maxX - 2 - bw / 2
                let bx: Double = (minX <= maxX) ? min(maxX, max(minX, petX)) : petX

                // 세로: 머리 위가 윗면을 넘으면 펫 아래로.
                let aboveCY = petY - h - 4 - bh / 2
                let belowCY = petY + 2 + bh / 2
                let by: Double = (bh > 0 && aboveCY - bh / 2 < plotFrame.minY)
                    ? belowCY
                    : aboveCY

                bubble(
                    quote,
                    fontSize: 9,
                    weight: .medium,
                    cornerRadius: 5,
                    padH: 5,
                    padV: 2.5
                )
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: QuoteBubbleSizeKey.self,
                            value: geo.size
                        )
                    }
                )
                .position(x: bx, y: by)
                .allowsHitTesting(false)
            }

            // 마우스 hover로 trigger된 도망 리액션 말풍선. 펫 머리 위에 펫 따라 이동.
            if ctrl.isFleeing, let reaction = ctrl.currentReaction {
                let petX = pos.x + jx
                let petY = pos.y + jy - jumpY
                bubble(
                    reaction,
                    fontSize: 9,
                    weight: .bold,
                    cornerRadius: 5,
                    padH: 5,
                    padV: 2.5
                )
                .fixedSize()
                .position(x: petX, y: petY - h - 6)
                .allowsHitTesting(false)
            }

            // 휴식 권유 말풍선: 노란 spiky 디자인, 클릭 시 dismiss.
            // 펫의 다른 말풍선들과 독립적으로 항상 펫 머리 위 우선, plot 클램프.
            if let nudge = wellnessNudge {
                let bw = wellnessBubbleSize.width
                let bh = wellnessBubbleSize.height
                let petX = pos.x + jx
                let petY = pos.y + jy
                let minX = plotFrame.minX + 2 + bw / 2
                let maxX = plotFrame.maxX - 2 - bw / 2
                let bx: Double = (minX <= maxX) ? min(maxX, max(minX, petX)) : petX
                let aboveCY = petY - h - 6 - bh / 2
                let belowCY = petY + 4 + bh / 2
                let by: Double = (bh > 0 && aboveCY - bh / 2 < plotFrame.minY) ? belowCY : aboveCY

                spikyBubble(nudge)
                    .fixedSize()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: WellnessBubbleSizeKey.self,
                                value: geo.size
                            )
                        }
                    )
                    .opacity(wellnessOpacity)
                    .position(x: bx, y: by)
                    .onTapGesture {
                        let result = onDismissWellness?() ?? .noReward
                        if case .rewarded(let amount) = result {
                            startCoinPop(at: CGPoint(x: bx, y: by), amount: amount)
                        }
                    }
            }

        }
    }

    /// 보상 코인 파티클 렌더링. TimelineView로 매 프레임 위치 갱신 +
    /// 코인 sprite의 회전 frame을 시간 기반으로 cycle.
    @ViewBuilder
    private var coinPopOverlay: some View {
        if !coinPops.isEmpty {
            let coinFrames = PetSprite.frames(named: "Coin", cellSize: (18, 20))
            TimelineView(.animation) { ctx in
                ZStack {
                    ForEach(coinPops) { p in
                        let t = ctx.date.timeIntervalSince(p.createdAt)
                        if t < Self.coinPopDuration, !coinFrames.isEmpty {
                            let gravity: Double = 320
                            let x = p.origin.x + p.velocityX * t
                            let y = p.origin.y + p.velocityY * t + 0.5 * gravity * t * t
                            let opacity = max(0, 1 - t / Self.coinPopDuration)
                            // 코인마다 frame phase를 다르게 → spin이 일제히 똑같이 안 돌게
                            let frameIdx = (Int(t * 14) + p.framePhase) % coinFrames.count
                            Image(nsImage: coinFrames[frameIdx])
                                .resizable()
                                .interpolation(.none)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 16 * p.scale, height: 18 * p.scale)
                                .opacity(opacity)
                                .position(x: x, y: y)
                        }
                    }
                }
            }
        }
    }

    private static let coinPopCount: Int = 8
    private static let coinPopDuration: TimeInterval = 0.9
    private static let rewardAmountDuration: TimeInterval = 1.1

    /// 보상 위치(말풍선 center)에서 코인 파티클 + "+N" 말풍선 함께 시작.
    private func startCoinPop(at origin: CGPoint, amount: Int) {
        let now = Date()
        let particles = (0..<Self.coinPopCount).map { _ in
            CoinPopParticle(
                origin: origin,
                velocityX: Double.random(in: -90...90),
                velocityY: Double.random(in: -200 ... -110),
                scale: Double.random(in: 0.7...1.05),
                framePhase: Int.random(in: 0..<6),
                createdAt: now
            )
        }
        coinPops.append(contentsOf: particles)
        rewardAmountPop = (origin, amount, now)

        let batchIds = Set(particles.map(\.id))
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.coinPopDuration * 1_100_000_000))
            coinPops.removeAll { batchIds.contains($0.id) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.rewardAmountDuration * 1_100_000_000))
            if let r = rewardAmountPop, r.createdAt == now {
                rewardAmountPop = nil
            }
        }
    }

    /// "+50" 보상 액수 말풍선. 위로 떠오르며 페이드아웃.
    @ViewBuilder
    private var rewardAmountOverlay: some View {
        if let r = rewardAmountPop {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSince(r.createdAt)
                if t < Self.rewardAmountDuration {
                    let yOffset = -t * 38
                    let opacity = max(0, 1 - t / Self.rewardAmountDuration)
                    bubble("+\(r.amount)", fontSize: 11, weight: .medium, cornerRadius: 6, padH: 6, padV: 2.5)
                        .opacity(opacity)
                        .position(x: r.origin.x, y: r.origin.y + yOffset - 10)
                }
            }
        }
    }

    /// 노란 spiky 말풍선. 텍스트는 검정 굵은 글씨, 외곽은 starburst 모양.
    private func spikyBubble(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                SpikyBubble(spikes: 18, spikeDepth: 5)
                    .fill(Color.yellow)
            )
            .overlay(
                SpikyBubble(spikes: 18, spikeDepth: 5)
                    .stroke(Color.black, lineWidth: 1.2)
            )
    }

    /// 펫 위에 뜨는 말풍선의 공통 외형 (흰 바탕 + 검정 둥근 테두리, 1줄).
    /// scream/cheer는 짧은 의성어 (defaults), quote는 명언 (fontSize/weight/radius/padding 조정).
    private func bubble(
        _ text: String,
        fontSize: CGFloat = 8,
        weight: Font.Weight = .bold,
        cornerRadius: CGFloat = 4,
        padH: CGFloat = 4,
        padV: CGFloat = 1.5
    ) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: weight, design: .rounded))
            .foregroundStyle(Color.black)
            .lineLimit(1)
            .padding(.horizontal, padH)
            .padding(.vertical, padV)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius).fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.black.opacity(0.7), lineWidth: 0.5)
            )
    }

    // 현재 x가 "큰 낙폭 segment" 안에 있고 진행 방향이 그 segment의 흐름과 같으면
    // descent를 부호로 반환: +1 = 내려가는 중, -1 = 올라가는 중, 0 = 해당 없음.
    // 임계: |dy| >= bigDropThreshold × (ymax - ymin)
    private func bigDropDescent(at xNorm: Double) -> Double {
        guard points.count >= 2 else { return 0 }
        let ys = points.map { $0.1 }
        guard let yMin = ys.min(), let yMax = ys.max(), yMax - yMin > 0 else { return 0 }
        let threshold = (yMax - yMin) * bigDropThreshold
        let xStart = points.first!.0
        let xEnd = points.last!.0
        let span = xEnd.timeIntervalSince(xStart)
        guard span > 0 else { return 0 }
        let targetDate = xStart.addingTimeInterval(span * xNorm)

        for i in 1..<points.count {
            let prev = points[i - 1]
            let next = points[i]
            guard targetDate >= prev.0 && targetDate <= next.0 else { continue }
            let dy = next.1 - prev.1
            if abs(dy) < threshold { return 0 }
            // facingRight = 시간 forward, slope < 0이면 내려가는 중
            // facingLeft  = 시간 backward, slope > 0이면 내려가는 중
            let descending = (ctrl.facingRight && dy < 0) || (!ctrl.facingRight && dy > 0)
            return descending ? 1 : -1
        }
        return 0
    }

    private func positionFor(xNorm: Double) -> CGPoint? {
        guard points.count >= 2 else { return nil }
        let xStart = points.first!.0
        let xEnd = points.last!.0
        let span = xEnd.timeIntervalSince(xStart)
        guard span > 0 else { return nil }
        let targetDate = xStart.addingTimeInterval(span * xNorm)
        let y = sampleY(at: targetDate)
        guard let xPos = proxy.position(forX: targetDate),
              let yPos = proxy.position(forY: y) else { return nil }
        return CGPoint(x: plotFrame.minX + xPos, y: plotFrame.minY + yPos)
    }

    // 인접 두 점 사이 선형 보간. 차트가 .monotone이면 약간 어긋날 수 있으나
    // 작은 sparkline에서는 시각적 차이가 미미하다.
    private func sampleY(at date: Date) -> Double {
        for i in 1..<points.count {
            if points[i].0 >= date {
                let prev = points[i - 1]
                let next = points[i]
                let span = next.0.timeIntervalSince(prev.0)
                if span <= 0 { return next.1 }
                let frac = date.timeIntervalSince(prev.0) / span
                return prev.1 + (next.1 - prev.1) * frac
            }
        }
        return points.last!.1
    }

    /// variant index → hueRotation 각도 (도).
    /// 0 = 기본(미변경), 1/2/3 = shiny tier (서로 충분히 떨어진 색).
    static func hueDegrees(for variant: Int) -> Double {
        switch variant {
        case 1: return 60   // yellow-green shift
        case 2: return 180  // 정반대 색
        case 3: return 300  // purple-red shift
        default: return 0
        }
    }
}

/// wellness 보상 클릭 시 튀는 코인 한 개의 운동 상태.
struct CoinPopParticle: Identifiable {
    let id = UUID()
    let origin: CGPoint
    let velocityX: Double      // px/s
    let velocityY: Double      // px/s (음수=위로 솟구침)
    let scale: Double
    /// sprite의 spin frame cycle을 코인마다 다른 위상에서 시작하기 위한 offset.
    let framePhase: Int
    let createdAt: Date
}

@MainActor
final class PetController: ObservableObject {
    enum Action: String { case walk, run, sit, scan, quote }

    @Published private(set) var x: Double = 0.5             // 0..1 정규화 위치
    @Published private(set) var facingRight: Bool = true
    @Published private(set) var action: Action = .walk
    @Published private(set) var frameIndex: Int = 0
    @Published private(set) var currentQuote: String? = nil
    // 마우스 hover로 trigger된 도망 상태. true 동안 reaction 말풍선 표시 + 가속 + 새 액션 선택 차단.
    @Published private(set) var isFleeing: Bool = false
    @Published private(set) var currentReaction: String? = nil

    // body에서 직접 set. @Published 아님 → SwiftUI 경고 안 남.
    var mood: PetMood = .neutral
    // 1보다 작으면 그 시점 펫 속도가 비례해서 느려짐 (큰 낙폭 구간에서 사용).
    var speedMultiplier: Double = 1.0

    private var direction: Double = 1
    private var actionUntil: Date = .distantPast
    private var lastTick: Date = Date()
    private var frameAccumulator: Double = 0
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        actionUntil = lastTick   // 즉시 첫 액션 결정
        // Timer block은 RunLoop.main 에서 실행되므로 이미 main thread.
        // Task { @MainActor in ... } 로 hop 하면 strict concurrency 에서 self capture
        // 위반 → MainActor.assumeIsolated 로 직접 호출.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 마우스 hover 시 호출. 이미 도망 중이면 무시. 더 가까운 끝쪽에서 멀어지는 방향으로 3초 run.
    func startFleeFromMouse() {
        guard !isFleeing else { return }
        isFleeing = true
        // 더 넓게 달릴 수 있는 쪽으로 도망. (마우스는 펫 위에 있으니 위치 자체가 회피 방향 hint)
        direction = self.x < 0.5 ? 1 : -1
        facingRight = direction > 0
        action = .run
        currentQuote = nil
        currentReaction = Quotes.randomReaction()
        let now = Date()
        actionUntil = now.addingTimeInterval(3.0)
        frameIndex = 0
        frameAccumulator = 0
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, max(0, now.timeIntervalSince(lastTick)))
        lastTick = now

        // 프레임 진행: 동작별 fps 다름. walk/run은 이동 속도에 살짝 비례.
        let fps: Double
        switch action {
        case .walk: fps = 6 + mood.walkSpeed * 30
        case .run:  fps = 12 + mood.walkSpeed * 30
        case .sit:  fps = 3
        case .scan: fps = 4
        case .quote: fps = 3
        }
        let frameDuration = 1.0 / max(1, fps)
        frameAccumulator += dt
        while frameAccumulator >= frameDuration {
            frameAccumulator -= frameDuration
            frameIndex += 1
        }

        if now >= actionUntil {
            if isFleeing {
                isFleeing = false
                currentReaction = nil
            }
            chooseNextAction(now: now)
        }

        if action == .walk || action == .run {
            let speed: Double
            if isFleeing {
                speed = mood.walkSpeed * 3.5   // 도망 시 가속
            } else if action == .run {
                speed = mood.walkSpeed * mood.runSpeedMultiplier
            } else {
                speed = mood.walkSpeed
            }
            x += direction * speed * speedMultiplier * dt
            if x >= 1 {
                x = 1
                direction = -1
                facingRight = false
            } else if x <= 0 {
                x = 0
                direction = 1
                facingRight = true
            } else {
                facingRight = direction > 0
            }
        }
    }

    private func chooseNextAction(now: Date) {
        let r = Double.random(in: 0...1)
        let restEnd = mood.restProbability
        let scanEnd = restEnd + mood.scanProbability
        // mood와 무관한 5% 확률로 명언 표시. 7초 고정.
        let quoteEnd = scanEnd + 0.05
        let prevAction = action
        currentQuote = nil
        if r < restEnd {
            action = .sit
            actionUntil = now.addingTimeInterval(.random(in: mood.restDurationRange))
        } else if r < scanEnd {
            action = .scan
            actionUntil = now.addingTimeInterval(.random(in: 0.4...1.2))
        } else if r < quoteEnd {
            action = .quote
            currentQuote = Quotes.random()
            actionUntil = now.addingTimeInterval(7.0)
        } else {
            // walk vs run: mood.runChance에 따라 분기. run은 짧은 burst.
            if Double.random(in: 0...1) < mood.runChance {
                action = .run
                actionUntil = now.addingTimeInterval(.random(in: mood.runDurationRange))
            } else {
                action = .walk
                actionUntil = now.addingTimeInterval(.random(in: mood.walkDurationRange))
            }
            // 매 walk/run마다 방향 완전 무작위 (가장자리면 안쪽으로 강제) → wandering
            if x < 0.15 {
                direction = 1
            } else if x > 0.85 {
                direction = -1
            } else {
                direction = Bool.random() ? 1 : -1
            }
            facingRight = direction > 0
        }
        if action != prevAction {
            // 새 동작 시작 시 frame 리셋 (sheet마다 frame 수가 달라서 인덱스 누수 방지)
            frameIndex = 0
            frameAccumulator = 0
        }
    }
}

struct PetMood {
    // 이동
    var walkSpeed: Double = 0.06           // 초당 정규화 x-단위 (0.1 = 10초에 끝에서 끝)
    var runSpeedMultiplier: Double = 2.2   // run 시 walk 대비 배속
    // 표현
    var jitter: Double = 0                 // 매 프레임 위치 떨림 amplitude(pt)
    var tint: Color = .white               // .colorMultiply 용. white = 변화 없음
    // 행동 분포
    var restProbability: Double = 0.30
    var scanProbability: Double = 0.10
    var runChance: Double = 0              // walk 결정 시 run으로 승급할 확률
    var restDurationRange: ClosedRange<TimeInterval> = 1.5...4.0
    var walkDurationRange: ClosedRange<TimeInterval> = 3.0...8.0
    var runDurationRange: ClosedRange<TimeInterval> = 1.0...2.5

    static let neutral = PetMood()

    /// pct: 현재 사용량 (0~100). anxietyAt: 불안 시작 비율 (0~1, 보통 첫 임계치).
    static func from(pct: Double?, anxietyAt: Double) -> PetMood {
        guard let pct = pct else { return .neutral }
        let p = max(0, min(1, pct / 100))
        let anx = max(0.01, min(0.99, anxietyAt))

        // 0 → 임계치: excitement 0 → 1
        let excitement = min(1, p / anx)
        // 임계치 → 100%: anxiety 0 → 1
        let anxiety = max(0, min(1, (p - anx) / (1 - anx)))

        let walkSpeed = 0.04 + excitement * 0.10 + anxiety * 0.04
        let jit = anxiety * 1.6
        // colorMultiply: 흰색=원본, 빨강에 가까워질수록 G/B 채널 감쇠
        let tint: Color = anxiety > 0
            ? Color(red: 1, green: 1 - anxiety * 0.55, blue: 1 - anxiety * 0.55)
            : .white

        // 차분: 자주 쉼 / 신남: 거의 안 쉼 / 불안: 거의 안 쉬고 자주 두리번
        let restProb = max(0, 0.35 - excitement * 0.30 - anxiety * 0.05)
        let scanProb = anxiety > 0.3 ? 0.18 : 0.08

        // run: 신남 절정(0.7+) 또는 불안 임계(0.4+)에서 점진 증가
        let excitementRun = max(0, (excitement - 0.70) / 0.30) * 0.55
        let anxietyRun    = max(0, (anxiety    - 0.40) / 0.60) * 0.85
        let runChance = max(excitementRun, anxietyRun)

        return PetMood(
            walkSpeed: walkSpeed,
            runSpeedMultiplier: 2.2,
            jitter: jit,
            tint: tint,
            restProbability: restProb,
            scanProbability: scanProb,
            runChance: runChance,
            restDurationRange: 1.0...3.5,
            walkDurationRange: anxiety > 0.5 ? 1.5...3.5 : 3.0...7.0,
            runDurationRange: 0.8...2.2
        )
    }
}
