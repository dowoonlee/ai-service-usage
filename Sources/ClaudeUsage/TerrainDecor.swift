import SwiftUI

// 차트 plot 하단(펫이 서 있는 "땅")에 테마별 장식 모티프를 그리는 레이어.
// chartOverlay 안에서 plotFrame 을 받아 Canvas 로 그린다. 펫(chartPet)보다 먼저
// 적용해서 z-순서상 펫 아래(땅)에 깔리도록 한다.
// 위치/크기는 Date/난수 없이 인덱스 해시로 결정론적 산출 → 매 렌더 흔들리지 않는다.

enum TerrainMotif {
    case grass       // 풀잎
    case dryGrass    // 마른 풀
    case pebble      // 자갈·흙점
    case wave        // 물결
    case snowflake   // 눈 반짝임
    case dune        // 모래언덕 곡선
    case ember       // 불씨
    case star        // 별
    case petal       // 꽃잎 (벚꽃)
    case rain        // 빗줄기 (뇌우)
    case bubble      // 기포 (독성 늪)
}

extension PetTheme {
    var motif: TerrainMotif {
        switch self {
        case .grassland:    return .grass
        case .field:        return .dryGrass
        case .wilderness:   return .pebble
        case .sea:          return .wave
        case .snowMountain: return .snowflake
        case .desert:       return .dune
        case .volcano:      return .ember
        case .space:        return .star
        case .aurora:       return .star    // 밤하늘 별빛 재활용
        case .sakura:       return .petal
        case .storm:        return .rain
        case .toxic:        return .bubble
        }
    }
}

struct TerrainDecor: View {
    let plotFrame: CGRect
    let theme: PetTheme

    // 모티프가 깔리는 땅 밴드 높이 (plot 하단부터 위로).
    private let band: CGFloat = 9

    var body: some View {
        Canvas { ctx, _ in
            guard plotFrame.width > 1, plotFrame.height > 1 else { return }
            drawMotifs(in: ctx)
        }
        .allowsHitTesting(false)
    }

    // 결정론적 해시 (0~1). i, 채널 seed 로 분기.
    private func h(_ i: Int, _ seed: Double) -> CGFloat {
        let x = sin(Double(i) * 127.1 + seed * 311.7) * 43758.5453
        return CGFloat(x - floor(x))
    }

    private func drawMotifs(in ctx: GraphicsContext) {
        let baseY = plotFrame.maxY          // 땅 바닥 (x축 라인)
        let minX = plotFrame.minX
        let w = plotFrame.width

        // 모티프 종류별 간격 → 개수.
        let spacing: CGFloat
        switch theme.motif {
        case .grass, .dryGrass: spacing = 11
        case .pebble:           spacing = 16
        case .snowflake, .star: spacing = 13
        case .ember:            spacing = 18
        case .petal:            spacing = 15
        case .rain:             spacing = 9
        case .bubble:           spacing = 15
        case .wave, .dune:      spacing = 1   // 연속 곡선 — 개수 무관
        }

        switch theme.motif {
        case .wave:  drawWaves(ctx, baseY: baseY, minX: minX, w: w); return
        case .dune:  drawDunes(ctx, baseY: baseY, minX: minX, w: w); return
        default: break
        }

        let count = max(3, Int(w / spacing))
        for i in 0..<count {
            // 균등 분포 + 약간의 해시 흔들림.
            let fx = (CGFloat(i) + 0.5) / CGFloat(count) + (h(i, 1) - 0.5) * 0.4 / CGFloat(count)
            let x = minX + fx * w
            switch theme.motif {
            case .grass:     drawBlade(ctx, x: x, baseY: baseY, i: i, dry: false)
            case .dryGrass:  drawBlade(ctx, x: x, baseY: baseY, i: i, dry: true)
            case .pebble:    drawPebble(ctx, x: x, baseY: baseY, i: i)
            case .snowflake: drawSparkle(ctx, x: x, baseY: baseY, i: i, color: .white)
            case .star:      drawSparkle(ctx, x: x, baseY: baseY, i: i, color: theme.lineColor)
            case .ember:     drawEmber(ctx, x: x, baseY: baseY, i: i)
            case .petal:     drawPetal(ctx, x: x, baseY: baseY, i: i)
            case .rain:      drawRain(ctx, x: x, baseY: baseY, i: i)
            case .bubble:    drawBubble(ctx, x: x, baseY: baseY, i: i)
            case .wave, .dune: break // 위에서 처리됨
            }
        }
    }

    // 풀잎: 바닥에서 위로 뻗는 곡선 한 가닥. dry=true 면 황색·더 기욺.
    private func drawBlade(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int, dry: Bool) {
        let height = band * (0.55 + 0.45 * h(i, 2))
        let lean = (h(i, 3) - 0.5) * (dry ? 6 : 3.5)
        var p = Path()
        p.move(to: CGPoint(x: x, y: baseY))
        p.addQuadCurve(
            to: CGPoint(x: x + lean, y: baseY - height),
            control: CGPoint(x: x + lean * 0.4, y: baseY - height * 0.5)
        )
        let c = dry ? theme.lineColor.opacity(0.40) : theme.lineColor.opacity(0.50)
        ctx.stroke(p, with: .color(c), lineWidth: 1)
    }

    // 자갈·흙점: 바닥에 깔린 작은 타원.
    private func drawPebble(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int) {
        let rw = 1.4 + 1.8 * h(i, 2)
        let rh = rw * 0.6
        let y = baseY - rh * 0.5 - h(i, 4) * 1.5
        let rect = CGRect(x: x - rw, y: y - rh, width: rw * 2, height: rh * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(theme.bottomColor.opacity(0.55)))
    }

    // 눈 반짝임 / 별: 작은 십자 광채.
    private func drawSparkle(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int, color: Color) {
        let s = 1.0 + 1.6 * h(i, 2)
        let y = baseY - h(i, 4) * band   // 바닥~밴드 위쪽까지 흩뿌림
        var p = Path()
        p.move(to: CGPoint(x: x - s, y: y)); p.addLine(to: CGPoint(x: x + s, y: y))
        p.move(to: CGPoint(x: x, y: y - s)); p.addLine(to: CGPoint(x: x, y: y + s))
        let op = 0.35 + 0.45 * h(i, 5)
        ctx.stroke(p, with: .color(color.opacity(op)), lineWidth: 0.8)
    }

    // 불씨: 바닥 위로 살짝 뜬 작은 원 (주황→적색).
    private func drawEmber(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int) {
        let r = 0.9 + 1.2 * h(i, 2)
        let y = baseY - h(i, 4) * band
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        ctx.fill(Path(ellipseIn: rect), with: .color(theme.lineColor.opacity(0.45 + 0.35 * h(i, 5))))
    }

    // 꽃잎: 살짝 기운 작은 타원 (분홍). 바닥~밴드 위쪽까지 흩뿌림.
    private func drawPetal(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int) {
        let rw = 1.6 + 1.4 * h(i, 2)
        let rh = rw * 0.55
        let y = baseY - h(i, 4) * band
        let rect = CGRect(x: -rw, y: -rh, width: rw * 2, height: rh * 2)
        let angle = (h(i, 3) - 0.5) * 1.2 // 라디안
        var t = ctx
        t.translateBy(x: x, y: y)
        t.rotate(by: .radians(angle))
        t.fill(Path(ellipseIn: rect), with: .color(theme.lineColor.opacity(0.40 + 0.30 * h(i, 5))))
    }

    // 빗줄기: 위에서 아래로 떨어지는 짧은 사선. 밴드보다 위까지 흩뿌림.
    private func drawRain(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int) {
        let len = band * (0.7 + 0.6 * h(i, 2))
        let top = baseY - band * 1.6 - h(i, 4) * band * 1.4
        let slant: CGFloat = 2.0
        var p = Path()
        p.move(to: CGPoint(x: x, y: top))
        p.addLine(to: CGPoint(x: x - slant, y: top + len))
        ctx.stroke(p, with: .color(theme.lineColor.opacity(0.35 + 0.30 * h(i, 5))), lineWidth: 0.9)
    }

    // 기포: 바닥 근처에서 떠오르는 작은 빈 원 (형광 녹 테두리).
    private func drawBubble(_ ctx: GraphicsContext, x: CGFloat, baseY: CGFloat, i: Int) {
        let r = 1.0 + 1.8 * h(i, 2)
        let y = baseY - h(i, 4) * band
        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
        ctx.stroke(Path(ellipseIn: rect), with: .color(theme.lineColor.opacity(0.40 + 0.35 * h(i, 5))), lineWidth: 0.8)
    }

    // 물결: 바닥을 따라 흐르는 sin 가로선 2줄.
    private func drawWaves(_ ctx: GraphicsContext, baseY: CGFloat, minX: CGFloat, w: CGFloat) {
        for row in 0..<2 {
            let y = baseY - CGFloat(row) * 4 - 1.5
            let amp: CGFloat = 1.6
            let phase = CGFloat(row) * 1.3
            var p = Path()
            p.move(to: CGPoint(x: minX, y: y))
            let steps = max(8, Int(w / 6))
            for s in 0...steps {
                let fx = CGFloat(s) / CGFloat(steps)
                let x = minX + fx * w
                let yy = y + sin(fx * .pi * 6 + phase) * amp
                p.addLine(to: CGPoint(x: x, y: yy))
            }
            ctx.stroke(p, with: .color(theme.lineColor.opacity(row == 0 ? 0.50 : 0.30)), lineWidth: 1)
        }
    }

    // 모래언덕: 바닥에 완만한 곡선 실루엣 fill.
    private func drawDunes(_ ctx: GraphicsContext, baseY: CGFloat, minX: CGFloat, w: CGFloat) {
        var p = Path()
        p.move(to: CGPoint(x: minX, y: baseY))
        let steps = max(8, Int(w / 8))
        for s in 0...steps {
            let fx = CGFloat(s) / CGFloat(steps)
            let x = minX + fx * w
            let y = baseY - (sin(fx * .pi * 3) * 0.5 + 0.5) * band * 0.7
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: minX + w, y: baseY))
        p.closeSubpath()
        ctx.fill(p, with: .color(theme.bottomColor.opacity(0.40)))
    }
}
