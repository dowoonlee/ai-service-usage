import SwiftUI

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

    var body: some View {
        ZStack {
            switch placement {
            case .backdrop:
                // 무지개 트레일은 펫 뒤로 흐르므로 backdrop. 광원(glow/aura)과 공존 가능.
                if effects.contains(.rainbow) { rainbow }
                // aura는 강화 glow를 포함하므로 glow와 중복으로 그리지 않는다.
                if effects.contains(.aura) { auraGlow }
                else if effects.contains(.glow) { glow }
            case .particles:
                if effects.contains(.trail) || effects.contains(.aura) { trail }
                if effects.contains(.footsteps) || effects.contains(.aura) { footsteps }
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
}
