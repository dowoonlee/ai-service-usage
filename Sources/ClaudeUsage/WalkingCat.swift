import SwiftUI
import Charts

// 차트 라인 위에서 살아있는 듯이 행동하는 펫.
// 표시는 Tiny Creatures 16x16 sprite (PetSprite),
// 행동(걷기/앉기/두리번)과 위치 상태는 PetController가 보유.
// sprite 자체는 단일 프레임이라 walk는 bob+squash로 페이크.
struct WalkingCat: View {
    let points: [(Date, Double)]   // 시간순 정렬 가정
    let proxy: ChartProxy
    let plotOrigin: CGPoint
    var kind: PetKind = .cat
    var mood: PetMood = .neutral
    var sizePt: CGFloat = 16

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
        if let pos = positionFor(xNorm: ctrl.x), let nsImg = PetSprite.image(for: kind) {
            let now = Date().timeIntervalSinceReferenceDate
            // 걷는 동안 bob (위아래) + squash (세로 펄스) → 살아있는 느낌
            let walking = ctrl.action == .walk
            let bobPhase = sin(now * mood.bobFreq * .pi * 2)
            let bob: Double = walking ? bobPhase * mood.bobAmplitude : 0
            let squash: Double = walking ? 1 + bobPhase * 0.10 : 1
            // jitter: 불안할수록 매 프레임 위치 떨림
            let jx: Double = mood.jitter > 0 ? Double.random(in: -mood.jitter...mood.jitter) : 0
            let jy: Double = mood.jitter > 0 ? Double.random(in: -mood.jitter...mood.jitter) : 0
            // scan: 두리번 → 미세 좌우 기울임
            let tilt: Double = ctrl.action == .scan ? sin(now * 4) * 10 : 0

            Image(nsImage: nsImg)
                .resizable()
                .interpolation(.none)
                .frame(width: sizePt, height: sizePt)
                // SF Symbol과 다르게 시트 sprite는 모두 우측 향함 → 좌측 이동시 반전
                .scaleEffect(
                    x: ctrl.facingRight ? 1 : -1,
                    y: squash,
                    anchor: .bottom
                )
                .rotationEffect(.degrees(tilt), anchor: .bottom)
                .colorMultiply(mood.tint)
                .position(
                    x: pos.x + jx,
                    y: pos.y - sizePt / 2 + bob + jy
                )
                .allowsHitTesting(false)
        }
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
    enum Action { case walk, sit, scan }

    @Published private(set) var x: Double = 0.5             // 0..1 정규화 위치
    @Published private(set) var facingRight: Bool = true
    @Published private(set) var action: Action = .walk

    // body에서 직접 set. @Published 아님 → SwiftUI 경고 안 남.
    var mood: PetMood = .neutral

    private var direction: Double = 1
    private var actionUntil: Date = .distantPast
    private var lastTick: Date = Date()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        lastTick = Date()
        actionUntil = lastTick   // 즉시 첫 액션 결정
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
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

        if now >= actionUntil {
            chooseNextAction(now: now)
        }

        if action == .walk {
            x += direction * mood.walkSpeed * dt
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
        if r < restEnd {
            action = .sit
            actionUntil = now.addingTimeInterval(.random(in: mood.restDurationRange))
        } else if r < scanEnd {
            action = .scan
            actionUntil = now.addingTimeInterval(.random(in: 0.4...1.2))
        } else {
            action = .walk
            actionUntil = now.addingTimeInterval(.random(in: mood.walkDurationRange))
            // 가끔 시작 시 방향 반전 (불안할수록 자주)
            if Double.random(in: 0...1) < mood.directionFlipProb {
                direction = -direction
                facingRight = direction > 0
            }
        }
    }
}

struct PetMood {
    // 이동
    var walkSpeed: Double = 0.06           // 초당 정규화 x-단위 (0.1 = 10초에 끝에서 끝)
    // 표현
    var bobAmplitude: Double = 0           // y 통통 진폭(pt)
    var bobFreq: Double = 2                // 초당 통통 횟수
    var jitter: Double = 0                 // 매 프레임 위치 떨림 amplitude(pt)
    var tint: Color = .white               // .colorMultiply 용. white = 변화 없음
    // 행동 분포
    var restProbability: Double = 0.30
    var scanProbability: Double = 0.10
    var directionFlipProb: Double = 0.20
    var restDurationRange: ClosedRange<TimeInterval> = 1.5...4.0
    var walkDurationRange: ClosedRange<TimeInterval> = 3.0...8.0

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
        let bob = excitement * 4.0 * (1 - anxiety)
        let jit = anxiety * 1.6
        // colorMultiply: 흰색=원본, 빨강에 가까워질수록 G/B 채널 감쇠
        let tint = anxiety > 0
            ? Color(red: 1, green: 1 - anxiety * 0.55, blue: 1 - anxiety * 0.55)
            : .white

        // 차분: 자주 쉼 / 신남: 거의 안 쉼 / 불안: 거의 안 쉬고 자주 두리번
        let restProb = max(0, 0.35 - excitement * 0.30 - anxiety * 0.05)
        let scanProb = anxiety > 0.3 ? 0.18 : 0.08
        let dirFlip = 0.10 + anxiety * 0.50

        return PetMood(
            walkSpeed: walkSpeed,
            bobAmplitude: bob,
            bobFreq: 2 + excitement * 2,
            jitter: jit,
            tint: tint,
            restProbability: restProb,
            scanProbability: scanProb,
            directionFlipProb: dirFlip,
            restDurationRange: 1.0...3.5,
            walkDurationRange: anxiety > 0.5 ? 1.5...3.5 : 3.0...7.0
        )
    }
}
