import SwiftUI
import Charts

// 차트 라인 위에서 걷고 쉬고 두리번거리는 펫.
// 표시는 Animated Wild Animals (CC0) 프레임 strip 기반,
// 행동/위치/현재 frame은 PetController가 보유.
struct WalkingCat: View {
    let points: [(Date, Double)]   // 시간순 정렬 가정
    let proxy: ChartProxy
    let plotOrigin: CGPoint
    var kind: PetKind = .fox
    var mood: PetMood = .neutral
    var displayHeight: CGFloat = 18

    @StateObject private var ctrl = PetController()

    var body: some View {
        // mood는 매 render마다 컨트롤러에 동기화 (publish 아님 → 경고 없음)
        ctrl.mood = mood
        return sprite()
            .onAppear { ctrl.start() }
            .onDisappear { ctrl.stop() }
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
            // descent > 0: 내려가는 중 → 굴러 떨어짐 (회전)
            // descent < 0: 올라가는 중 → 점프 (위로 튀어오름)
            let rollAngle: Double = (isMoving && descent > 0) ? now * 360 * 2 : 0
            let jumpY: Double = (isMoving && descent < 0) ? abs(sin(now * 5)) * 6 : 0

            Image(nsImage: nsImg)
                .resizable()
                .interpolation(.none)
                .frame(width: w, height: h)
                // Wild Animals sprite는 모두 좌향 → 우측 이동시 반전
                .scaleEffect(x: ctrl.facingRight ? -1 : 1, y: 1, anchor: .center)
                .rotationEffect(.degrees(rollAngle), anchor: .center)
                .colorMultiply(mood.tint)
                .position(
                    x: pos.x + jx,
                    y: pos.y - h / 2 + jy - jumpY
                )
                .allowsHitTesting(false)

            // 굴러 떨어지는 중(descent > 0)일 때만 우측에 비명 말풍선.
            // 펫의 rotationEffect와 무관하게 upright 유지하려고 sibling으로 배치.
            if isMoving && descent > 0 {
                screamBubble
                    .position(
                        x: pos.x + jx + w / 2 + 18,
                        y: pos.y - h * 0.85 + jy
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    private var screamBubble: some View {
        Text("AAAH!")
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black.opacity(0.7), lineWidth: 0.5)
            )
    }

    // 현재 x가 "큰 낙폭 segment" 안에 있고 진행 방향이 그 segment의 흐름과 같으면
    // descent를 부호로 반환: +1 = 내려가는 중, -1 = 올라가는 중, 0 = 해당 없음.
    // 임계: |dy| >= 40% × (ymax - ymin)
    private func bigDropDescent(at xNorm: Double) -> Double {
        guard points.count >= 2 else { return 0 }
        let ys = points.map { $0.1 }
        guard let yMin = ys.min(), let yMax = ys.max(), yMax - yMin > 0 else { return 0 }
        let threshold = (yMax - yMin) * 0.40
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
        return CGPoint(x: plotOrigin.x + xPos, y: plotOrigin.y + yPos)
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
}

@MainActor
final class PetController: ObservableObject {
    enum Action: String { case walk, run, sit, scan }

    @Published private(set) var x: Double = 0.5             // 0..1 정규화 위치
    @Published private(set) var facingRight: Bool = true
    @Published private(set) var action: Action = .walk
    @Published private(set) var frameIndex: Int = 0

    // body에서 직접 set. @Published 아님 → SwiftUI 경고 안 남.
    var mood: PetMood = .neutral

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
        }
        let frameDuration = 1.0 / max(1, fps)
        frameAccumulator += dt
        while frameAccumulator >= frameDuration {
            frameAccumulator -= frameDuration
            frameIndex += 1
        }

        if now >= actionUntil {
            chooseNextAction(now: now)
        }

        if action == .walk || action == .run {
            let speed = action == .run
                ? mood.walkSpeed * mood.runSpeedMultiplier
                : mood.walkSpeed
            x += direction * speed * dt
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
        let prevAction = action
        if r < restEnd {
            action = .sit
            actionUntil = now.addingTimeInterval(.random(in: mood.restDurationRange))
        } else if r < scanEnd {
            action = .scan
            actionUntil = now.addingTimeInterval(.random(in: 0.4...1.2))
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
