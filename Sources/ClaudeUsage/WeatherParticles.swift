import SwiftUI
import AppKit

/// 메인 패널 위에 깔리는 비/눈 파티클 오버레이.
/// `coinPopOverlay`(WalkingCat)와 같은 `TimelineView(.animation)` + 시간 기반 위치 계산 패턴.
///
/// 파티클은 정규화 좌표(0...1)로 보관하고 렌더 시 plot 크기를 곱한다 → 패널 리사이즈에 무관.
/// `clear`면 상위(MainView)에서 아예 렌더하지 않으므로 여기선 rain/snow/thunder만 다룬다.
struct WeatherParticles: View {
    let condition: WeatherCondition
    /// 강수/강설량 기반 강도(0...1). 파티클 밀도를 비례 — 1.0이 최대 밀도(비 40 / 눈 26).
    var intensity: Double = 1.0

    var body: some View {
        GeometryReader { geo in
            ParticleField(condition: condition, intensity: intensity, size: geo.size)
        }
        .allowsHitTesting(false)
    }
}

/// 한 파티클의 불변 파라미터. 위치는 시간 t로부터 매 프레임 계산한다(상태 없음).
private struct Particle: Identifiable {
    let id: Int
    let x: Double          // 0...1 (수평 시작 위치)
    let speed: Double      // 초당 떨어지는 정규화 거리 (사이클/초)
    let phase: Double      // 0...1 초기 위상 — 시작 시 흩어져 있도록
    let scale: Double      // 스프라이트 크기 배수
    let opacity: Double
    let swayAmp: Double    // 좌우 흔들림 진폭 (정규화 x) — 눈만 사용
    let swayFreq: Double
    let swayPhase: Double
    let drift: Double      // 낙하 중 수평 이동 (정규화) — 비의 사선 효과
}

private struct ParticleField: View {
    let condition: WeatherCondition
    let size: CGSize

    private var isSnow: Bool { condition == .snow }
    private var hasThunder: Bool { condition == .thunder }

    private let particles: [Particle]
    private let spriteName: String
    /// 스프라이트 원본 픽셀 크기 (interpolation(.none) 확대 기준).
    private let spritePixel: CGSize

    init(condition: WeatherCondition, intensity: Double, size: CGSize) {
        self.condition = condition
        self.size = size

        let snow = (condition == .snow)
        self.spriteName = snow ? "snowflake" : "raindrop"
        self.spritePixel = snow ? CGSize(width: 9, height: 9) : CGSize(width: 3, height: 7)

        // 파티클 수 — 강도(0...1)에 비례. 최대 밀도는 눈 26 / 비 40 (강도 1.0 기준).
        // 강도는 WeatherAPI에서 강수/강설량을 정규화한 값이며 0.25 하한이 보장된다.
        let maxCount = snow ? 26 : 40
        let clamped = Swift.max(0, Swift.min(1, intensity))
        let count = Swift.max(1, Int((Double(maxCount) * clamped).rounded()))
        var built: [Particle] = []
        built.reserveCapacity(count)
        for i in 0..<count {
            if snow {
                built.append(Particle(
                    id: i,
                    x: Double.random(in: 0...1),
                    speed: Double.random(in: 0.067...0.134),     // 천천히 (기존 대비 ~33% 감속)
                    phase: Double.random(in: 0...1),
                    scale: Double.random(in: 0.8...1.5),
                    opacity: Double.random(in: 0.6...0.95),
                    swayAmp: Double.random(in: 0.02...0.06),
                    swayFreq: Double.random(in: 0.6...1.4),
                    swayPhase: Double.random(in: 0...(2 * .pi)),
                    drift: 0
                ))
            } else {
                built.append(Particle(
                    id: i,
                    x: Double.random(in: -0.1...1.0),
                    speed: Double.random(in: 0.35...0.55),        // 빠르게 (기존 대비 절반 감속)
                    phase: Double.random(in: 0...1),
                    scale: Double.random(in: 0.9...1.4),
                    opacity: Double.random(in: 0.45...0.8),
                    swayAmp: 0,
                    swayFreq: 0,
                    swayPhase: 0,
                    drift: Double.random(in: 0.06...0.14)         // 살짝 사선
                ))
            }
        }
        self.particles = built
    }

    var body: some View {
        guard let sprite = PetSprite.image(named: spriteName), size.width > 0, size.height > 0 else {
            return AnyView(Color.clear)
        }
        let w = size.width
        let h = size.height

        return AnyView(
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                ZStack {
                    if hasThunder {
                        lightningFlash(t: t)
                    }
                    ForEach(particles) { p in
                        // 정규화 y: 위상 + 시간에 비례, 1을 넘으면 다시 위로 (연속 낙하).
                        let yNorm = (p.phase + t * p.speed).truncatingRemainder(dividingBy: 1.0)
                        let sway = p.swayAmp == 0 ? 0 : p.swayAmp * sin(t * p.swayFreq + p.swayPhase)
                        // 비는 낙하 진행에 비례해 수평으로 흘러 사선이 됨.
                        let xNorm = p.x + sway + p.drift * yNorm
                        // [0,1)로 정규화 — 음수(왼쪽 시작)·1 초과(사선 drift)를 모두 wrap해
                        // 좌우 가장자리까지 파티클이 균일하게 채워지도록.
                        let xWrapped = xNorm - floor(xNorm)
                        let px = xWrapped * w
                        let py = yNorm * (h + 12) - 6      // 위/아래로 살짝 넘겨 화면 밖에서 진입/이탈
                        Image(nsImage: sprite)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: spritePixel.width * p.scale,
                                   height: spritePixel.height * p.scale)
                            .rotationEffect(isSnow ? .degrees(t * 40 + Double(p.id) * 23) : .degrees(8))
                            .opacity(p.opacity)
                            .position(x: px, y: py)
                    }
                }
            }
        )
    }

    /// 뇌우 — 약 9초 주기로 짧은 더블 플래시. 화면 전체를 옅게 밝힘.
    private func lightningFlash(t: Double) -> some View {
        let cycle = 9.0
        let phase = t.truncatingRemainder(dividingBy: cycle)
        var intensity = 0.0
        // 0.0~0.10s 와 0.18~0.26s 에 번쩍 (더블 스트라이크).
        if phase < 0.10 {
            intensity = (1 - phase / 0.10) * 0.5
        } else if phase >= 0.18 && phase < 0.26 {
            intensity = (1 - (phase - 0.18) / 0.08) * 0.35
        }
        return Color.white.opacity(intensity).blendMode(.plusLighter)
    }
}
