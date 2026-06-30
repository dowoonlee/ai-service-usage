import SwiftUI
import Foundation

// WalkingCat이 그리는 RP 코스메틱 이펙트 레이어. 펫 스프라이트와 같은 좌표계에서 펫 몸통 중심/발
// 위치를 받아 파티클·광원을 그린다. 펫 이미지에 의존하지 않는 순수 기하 렌더라 모든 PetKind에
// 동일하게 적용된다. cf. docs/DESIGN_RP_ECONOMY.md
//
// z-order를 위해 두 placement로 나눠 호출된다:
//   .backdrop  — glow/aura 광원. 펫 스프라이트 *뒤*에 깔린다.
//   .particles — footsteps/trail 파티클. 펫 스프라이트 *앞*에 그려진다.
struct PetEffectOverlay: View {
    enum Placement { case backdrop, particles }

    let effects: Set<EffectKind>
    let placement: Placement
    let center: CGPoint       // 펫 몸통 중심 (차트 좌표)
    let footY: CGFloat        // 펫 발 y (footsteps 기준선)
    let petHeight: CGFloat
    let facingRight: Bool
    let isMoving: Bool         // footsteps/trail은 이동 중에만. glow/aura는 항상.
    /// Mythic 등급 펫의 기본 오라 — 구매 효과(EffectKind)와 별개로 항상 켜진다. WalkingCat이 주입.
    var mythicBase: Bool = false
    /// 펫 점프(올라가는 큰 낙폭)와 동기화 — 오라를 위로 올리는 offset. WalkingCat이 sprite와 같은 값 주입.
    var mythicJumpY: CGFloat = 0
    /// 펫 구르기(내려가는 큰 낙폭)와 동기화 — 오라 회전 각도. sprite의 rollAngle과 동일.
    var mythicRoll: Double = 0
    /// mythic 펫별 오라 스타일(색). WalkingCat이 `Mythic.spec(for:)?.aura`를 주입.
    var mythicAuraStyle: MythicAura = .crimsonGold

    var body: some View {
        ZStack {
            switch placement {
            case .backdrop:
                // Mythic 기본 오라 — 구매 효과보다 뒤(맨 아래)에 깔린다.
                if mythicBase { mythicAura }
                // 무지개/별가루 트레일은 펫 뒤로 흐르므로 backdrop. 광원(glow/aura)과 공존 가능.
                if effects.contains(.rainbow) { rainbow }
                if effects.contains(.stardust) { stardust }
                // aura는 강화 glow를 포함하므로 glow와 중복으로 그리지 않는다.
                if effects.contains(.aura) { auraGlow }
                else if effects.contains(.glow) { glow }
            case .particles:
                if effects.contains(.trail) || effects.contains(.aura) { trail }
                if effects.contains(.flame) { flame }
                if effects.contains(.footsteps) || effects.contains(.aura) { footsteps }
                if effects.contains(.heart) { heartParticles }
                if effects.contains(.star) { starParticles }
                if effects.contains(.petal) { petalParticles }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - backdrop

    /// 펫 뒤 은은한 노란 광원 + 느린 펄스.
    private var glow: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 0.35 + 0.12 * sin(t * 2.2)
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [Color.yellow.opacity(pulse), .clear]),
                    center: .center, startRadius: 0, endRadius: petHeight))
                .frame(width: petHeight * 2.4, height: petHeight * 2.4)
                .blur(radius: 3)
                .position(center)
        }
    }

    /// 프리미엄 — 천천히 색이 순환하는 강한 광원.
    private var auraGlow: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let hue = (t * 0.15).truncatingRemainder(dividingBy: 1.0)
            let pulse = 0.45 + 0.15 * sin(t * 2.6)
            Circle()
                .fill(RadialGradient(
                    gradient: Gradient(colors: [
                        Color(hue: hue, saturation: 0.8, brightness: 1.0).opacity(pulse), .clear]),
                    center: .center, startRadius: 0, endRadius: petHeight * 1.2))
                .frame(width: petHeight * 2.8, height: petHeight * 2.8)
                .blur(radius: 4)
                .position(center)
        }
    }

    /// Mythic 등급 전용 기본 오라 — 진홍·금 angular 광선이 회전 + 진홍 radial glow 맥동.
    /// sudo pull 가챠 연출(`GachaView.premiumAura`)과 같은 톤이라 "Mythic = 진홍/금" 정체성을 공유한다.
    private var mythicAura: some View {
        let (mythic, gold) = Self.auraColors(mythicAuraStyle)
        return TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let spin = (t * 20).truncatingRemainder(dividingBy: 360)
            let pulse = 0.40 + 0.12 * sin(t * 2.6)
            ZStack {
                AngularGradient(
                    gradient: Gradient(colors: [.clear, mythic.opacity(0.5), .clear,
                                                gold.opacity(0.4), .clear, mythic.opacity(0.45), .clear]),
                    center: .center)
                    .rotationEffect(.degrees(spin))
                    .blur(radius: 3)
                    .blendMode(.screen)
                    .frame(width: petHeight * 1.3, height: petHeight * 1.3)
                Circle()
                    .fill(RadialGradient(
                        gradient: Gradient(colors: [mythic.opacity(pulse), gold.opacity(pulse * 0.4), .clear]),
                        center: .center, startRadius: 0, endRadius: petHeight * 0.55))
                    .frame(width: petHeight * 1.2, height: petHeight * 1.2)
                    .blur(radius: 2)
            }
            // 펫 구르기(roll)와 동기화 — 펫과 같은 중심 기준 회전.
            .rotationEffect(.degrees(mythicRoll))
            // 펫 점프(jump)와 동기화 — 위로 같은 만큼 offset.
            .position(x: center.x, y: center.y - mythicJumpY)
        }
    }

    /// MythicAura 스타일 → (주색, 보조색). 펫별 시그니처 오라 색.
    static func auraColors(_ style: MythicAura) -> (Color, Color) {
        switch style {
        case .crimsonGold:    return (Rarity.mythic.color, Color(red: 1.0, green: 0.82, blue: 0.35))
        case .volcanicFire:   return (Color(red: 0.95, green: 0.30, blue: 0.08), Color(red: 1.0, green: 0.78, blue: 0.30))
        case .stormLightning: return (Color(red: 0.40, green: 0.62, blue: 1.0),  Color(red: 0.85, green: 0.92, blue: 1.0))
        case .holyLight:      return (Color(red: 1.0, green: 0.90, blue: 0.55),  Color(red: 0.55, green: 1.0, blue: 0.85))
        }
    }

    /// Nyan Cat 무지개 트레일 — 6색 띠가 펫 뒤로 흐른다. 핵심은 평평한 띠가 아니라 세로 픽셀
    /// 블록(`block`)마다 위아래로 양자화된 사인만큼 어긋나 **계단식으로 물결치며 스크롤**되는 것.
    /// Canvas로 안티앨리어싱 없는 각진 블록을 직접 채워 픽셀 아트 느낌을 낸다.
    private var rainbow: some View {
        let colors: [Color] = [
            Color(red: 1.00, green: 0.07, blue: 0.07),   // #ff1211
            Color(red: 1.00, green: 0.65, blue: 0.05),   // #ffa70e
            Color(red: 1.00, green: 1.00, blue: 0.02),   // #ffff04
            Color(red: 0.26, green: 1.00, blue: 0.05),   // #43ff0d
            Color(red: 0.07, green: 0.67, blue: 1.00),   // #13abff
            Color(red: 0.47, green: 0.27, blue: 1.00),   // #7745ff
        ]
        let length = petHeight * 2.4
        let bandH = petHeight * 0.82
        let block = max(2.0, petHeight * 0.16)   // 픽셀 블록 = 계단 한 칸
        let canvasH = bandH + block * 3          // 위아래 출렁임 여유
        return TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let cols = max(1, Int((size.width / block).rounded(.up)))
                let stripeH = bandH / CGFloat(colors.count)
                for c in 0..<cols {
                    // 펫에 붙는 앞끝을 진행 방향 반대쪽 끝에 두고 뒤로 깐다.
                    let x = facingRight ? size.width - CGFloat(c + 1) * block
                                        : CGFloat(c) * block
                    // 컬럼 인덱스를 따라가는 사인을 블록 단위로 양자화 → 계단 물결.
                    // 시간(t)으로 phase를 밀어 물결이 펫 뒤로 흐르게.
                    let phase = Double(c) * 0.7 + t * 7 * (facingRight ? 1 : -1)
                    let stepped = (sin(phase) * 1.5).rounded() / 1.5
                    let yOff = CGFloat(stepped) * block
                    let top = (canvasH - bandH) / 2 + yOff
                    // 펫에서 먼 끝(c↑)으로 갈수록 투명 → 트레일이 점점 흐려지며 사라진다.
                    let alpha = 1.0 - Double(c) / Double(cols)
                    for (i, color) in colors.enumerated() {
                        // +0.5로 블록 사이 미세 틈을 메운다.
                        let rect = CGRect(x: x, y: top + CGFloat(i) * stripeH,
                                          width: block + 0.5, height: stripeH + 0.5)
                        gc.fill(Path(rect), with: .color(color.opacity(alpha)))
                    }
                }
            }
            .frame(width: length, height: canvasH)
            .position(x: center.x + (facingRight ? -1 : 1) * (length / 2 + petHeight * 0.3),
                      y: center.y)
        }
    }

    // MARK: - particles

    /// 발밑에서 진행 반대 방향으로 흘러가며 사라지는 먼지/별.
    private var footsteps: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let dir: CGFloat = facingRight ? -1 : 1
            ZStack {
                if isMoving {
                    ForEach(0..<5, id: \.self) { i in
                        let phase = (t * 1.6 + Double(i) / 5).truncatingRemainder(dividingBy: 1.0)
                        let r = CGFloat(1 - phase) * 2 + 0.8
                        let dx = dir * CGFloat(phase) * petHeight * 1.1
                        let dy = -CGFloat(phase) * petHeight * 0.3
                        Circle()
                            .fill(Color.white)
                            .frame(width: r * 2, height: r * 2)
                            .opacity((1 - phase) * 0.6)
                            .position(x: center.x + dx, y: footY + dy)
                    }
                }
            }
        }
    }

    /// 몸통 높이에서 진행 반대 방향으로 늘어지는 발광 잔상.
    private var trail: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let dir: CGFloat = facingRight ? -1 : 1
            ZStack {
                if isMoving {
                    ForEach(0..<6, id: \.self) { i in
                        let phase = (t * 1.2 + Double(i) / 6).truncatingRemainder(dividingBy: 1.0)
                        let r = CGFloat(1 - phase) * 3 + 1
                        let dx = dir * CGFloat(phase) * petHeight * 1.6
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: r * 2, height: r * 2)
                            .opacity((1 - phase) * 0.5)
                            .blur(radius: 1)
                            .position(x: center.x + dx, y: center.y)
                    }
                }
            }
        }
    }

    // MARK: - 신규 코스메틱 (파티클: 떠오르는 입자 / 궤적: 뒤로 흐름)

    /// 펫 주변에서 위로 떠오르며 사라지는 하트.
    private var heartParticles: some View { riser(HeartShape(), color: .pink, count: 4) }
    /// 별.
    private var starParticles: some View { riser(StarShape(), color: .yellow, count: 4) }
    /// 꽃잎 (좌우로 더 크게 흔들리며).
    private var petalParticles: some View {
        riser(Ellipse(), color: Color(red: 1, green: 0.72, blue: 0.85), count: 5, sway: 0.5)
    }

    /// 떠오르는 입자 공통 — 모양/색/개수/흔들림만 바꿔 재사용. 이동과 무관하게 항상 은은히.
    private func riser<S: Shape>(_ shape: S, color: Color, count: Int, sway: Double = 0.3) -> some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let phase = (t * 0.6 + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1.0)
                    let dx = sin((phase * 2 + Double(i)) * .pi) * petHeight * sway
                    let dy = -CGFloat(phase) * petHeight * 1.3
                    let sz = petHeight * 0.22
                    shape
                        .fill(color)
                        .frame(width: sz, height: sz)
                        .opacity((1 - phase) * 0.85)
                        .position(x: center.x + dx, y: footY - petHeight * 0.2 + dy)
                }
            }
        }
    }

    /// 별가루 궤적 — 이동 시 뒤로 흐르는 반짝이 점.
    private var stardust: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let dir: CGFloat = facingRight ? -1 : 1
            ZStack {
                if isMoving {
                    ForEach(0..<7, id: \.self) { i in
                        let phase = (t * 1.4 + Double(i) / 7).truncatingRemainder(dividingBy: 1.0)
                        let dx = dir * CGFloat(phase) * petHeight * 1.5
                        let dy = sin((phase + Double(i)) * 5) * petHeight * 0.25
                        let r = CGFloat(1 - phase) * 1.6 + 0.6
                        Circle()
                            .fill(Color(red: 1, green: 0.95, blue: 0.6))
                            .frame(width: r * 2, height: r * 2)
                            .opacity((1 - phase) * 0.9)
                            .position(x: center.x + dx, y: center.y + dy)
                    }
                }
            }
        }
    }

    /// 불꽃 궤적 — 이동 시 뒤로 흐르는 주황 잔상 (식어가며 빨강으로).
    private var flame: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let dir: CGFloat = facingRight ? -1 : 1
            ZStack {
                if isMoving {
                    ForEach(0..<6, id: \.self) { i in
                        let phase = (t * 1.5 + Double(i) / 6).truncatingRemainder(dividingBy: 1.0)
                        let dx = dir * CGFloat(phase) * petHeight * 1.3
                        let r = CGFloat(1 - phase) * 3.2 + 1
                        let col = Color(red: 1, green: 0.55 - 0.35 * phase, blue: 0.1)
                        Circle()
                            .fill(col)
                            .frame(width: r * 2, height: r * 2)
                            .opacity((1 - phase) * 0.6)
                            .blur(radius: 1)
                            .position(x: center.x + dx, y: center.y - CGFloat(phase) * petHeight * 0.2)
                    }
                }
            }
        }
    }
}

/// 떠오르는 입자용 하트 모양.
struct HeartShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: h * 0.32))
        p.addCurve(to: CGPoint(x: 0, y: h * 0.28),
                   control1: CGPoint(x: w * 0.5, y: h * 0.06), control2: CGPoint(x: 0, y: 0))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h),
                   control1: CGPoint(x: 0, y: h * 0.58), control2: CGPoint(x: w * 0.5, y: h * 0.78))
        p.addCurve(to: CGPoint(x: w, y: h * 0.28),
                   control1: CGPoint(x: w * 0.5, y: h * 0.78), control2: CGPoint(x: w, y: h * 0.58))
        p.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.32),
                   control1: CGPoint(x: w, y: 0), control2: CGPoint(x: w * 0.5, y: h * 0.06))
        return p
    }
}

/// 떠오르는 입자용 별 모양 (5각).
struct StarShape: Shape {
    var points: Int = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: r.midX, y: r.midY)
        let outer = min(r.width, r.height) / 2
        let inner = outer * 0.42
        for i in 0..<(points * 2) {
            let angle = Double(i) * .pi / Double(points) - .pi / 2
            let rad = i % 2 == 0 ? outer : inner
            // Foundation.cos/sin으로 명시 qualify — SwiftUI가 끌어오는 simd 오버로드와 모호해지는 것 방지.
            let ca = CGFloat(Foundation.cos(angle))
            let sa = CGFloat(Foundation.sin(angle))
            let pt = CGPoint(x: c.x + ca * rad, y: c.y + sa * rad)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
