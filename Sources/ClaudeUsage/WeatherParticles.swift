import SwiftUI
import AppKit

/// 메인 패널 위에 깔리는 비/눈 파티클 오버레이.
/// `coinPopOverlay`(WalkingCat)와 같은 `TimelineView(.animation)` + 시간 기반 위치 계산 패턴.
///
/// 파티클은 정규화 좌표(0...1)로 보관하고 렌더 시 plot 크기를 곱한다 → 패널 리사이즈에 무관.
/// `clear`면 상위(MainView)에서 아예 렌더하지 않으므로 여기선 rain/snow/thunder만 다룬다.
struct WeatherParticles: View {
    let style: ParticleStyle

    /// 실제 날씨용 — 시즌 ambient는 `ParticleStyle`을 직접 넘긴다. clear면 상위가 렌더하지 않는다.
    init(condition: WeatherCondition, intensity: Double = 1.0) {
        self.style = ParticleStyle.weather(condition, intensity: intensity) ?? .snow.with(intensity: 0)
    }

    init(style: ParticleStyle) {
        self.style = style
    }

    var body: some View {
        GeometryReader { geo in
            ParticleField(style: style, size: geo.size)
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
    /// 창이 안 보이면 프레임 루프를 멈춘다 (WindowVisibility.swift).
    @Environment(\.windowIsVisible) private var windowIsVisible
    let style: ParticleStyle
    let size: CGSize

    private var isSnow: Bool { style.spins }
    private var hasThunder: Bool { style.thunder }

    private let particles: [Particle]
    private var spriteName: String { style.sprite }
    /// 스프라이트 원본 픽셀 크기 (interpolation(.none) 확대 기준).
    private var spritePixel: CGSize { style.pixel }

    init(style: ParticleStyle, size: CGSize) {
        self.style = style
        self.size = size

        // 파티클 수 — 강도(0...1)에 비례. 최대 밀도는 스타일이 정한다(눈 26 / 비 40, 강도 1.0 기준).
        // 날씨 강도는 WeatherAPI가 강수량을 정규화한 값(0.25 하한), 시즌 ambient는 고정값.
        let clamped = Swift.max(0, Swift.min(1, style.intensity))
        let count = Swift.max(1, Int((Double(style.maxCount) * clamped).rounded()))
        var built: [Particle] = []
        built.reserveCapacity(count)
        let sways = style.sway.upperBound > 0
        for i in 0..<count {
            built.append(Particle(
                id: i,
                x: Double.random(in: (style.drift.upperBound > 0 ? -0.1 : 0)...1.0),
                speed: Double.random(in: style.speed),
                phase: Double.random(in: 0...1),
                scale: Double.random(in: style.scale),
                opacity: Double.random(in: style.opacity),
                swayAmp: sways ? Double.random(in: style.sway) : 0,
                swayFreq: sways ? Double.random(in: 0.6...1.4) : 0,
                swayPhase: sways ? Double.random(in: 0...(2 * .pi)) : 0,
                drift: style.drift.upperBound > 0 ? Double.random(in: style.drift) : 0
            ))
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
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) { ctx in
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
