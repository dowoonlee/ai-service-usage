import SwiftUI

// 사주/오행 시각화 — DailyFortuneView 전용 렌더 컴포넌트.
//
//   * SajuPillarsGrid    — 전통 명식표. 4열(시·일·월·년) × 2행(천간/지지) 타일을
//                          오행 전통색으로 칠하고 일간(나) 타일을 강조.
//   * FiveElementPentagon — 오행 분포 + 오늘의 관계를 한 그림에. 상생 순환 순서로
//                          배치한 오각형 노드(크기·채도 ∝ 카운트)에 일간→오늘 관계
//                          화살표를 강조. 카운트가 0~8 정수라 레이더 차트는 0값 축이
//                          중심으로 꺼져 찌그러지므로 채택하지 않음.
//
// 두 뷰 모두 @Environment(\.colorScheme) 으로 팔레트를 전환한다 — hud(다크)와
// 클립보드 캡처(라이트 강제) 양쪽에서 쓰이기 때문.

// MARK: - 오행 팔레트

extension FiveElement {
    /// 전통 오행색 기반. 수=흑/금=백은 배경 대비가 죽어 다크/라이트 각각 보정.
    func color(dark: Bool) -> Color {
        switch self {
        case .wood:  return dark ? Color(red: 0.35, green: 0.78, blue: 0.47)
                                 : Color(red: 0.20, green: 0.58, blue: 0.33)
        case .fire:  return dark ? Color(red: 0.95, green: 0.42, blue: 0.36)
                                 : Color(red: 0.80, green: 0.25, blue: 0.22)
        case .earth: return dark ? Color(red: 0.92, green: 0.72, blue: 0.30)
                                 : Color(red: 0.72, green: 0.53, blue: 0.13)
        case .metal: return dark ? Color(red: 0.82, green: 0.85, blue: 0.90)
                                 : Color(red: 0.50, green: 0.54, blue: 0.60)
        case .water: return dark ? Color(red: 0.45, green: 0.62, blue: 0.96)
                                 : Color(red: 0.17, green: 0.30, blue: 0.62)
        }
    }
}

extension ElementRelation {
    /// 펜타곤 아래 캡션용 한 줄 풀이.
    var shortDescription: String {
        switch self {
        case .same:       return "평이한 결의 날"
        case .generates:  return "내가 표현하고 내보내는 날"
        case .generated:  return "도움을 받는 날"
        case .overcomes:  return "내가 다스리는 날"
        case .overcome:   return "압박을 받는 날"
        }
    }
}

// MARK: - 명식표 그리드

struct SajuPillarsGrid: View {
    let chart: SajuChart
    @Environment(\.colorScheme) private var scheme

    /// 전통 명식표 열 순서 — 왼쪽부터 시·일·월·년.
    private var columns: [(label: String, pillar: SajuPillar, isDay: Bool)] {
        [("시", chart.hour, false),
         ("일", chart.day, true),
         ("월", chart.month, false),
         ("년", chart.year, false)]
    }

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 24, height: 1)
                ForEach(columns, id: \.label) { col in
                    Text(col.label)
                        .font(.system(size: 9, weight: col.isDay ? .bold : .regular))
                        .foregroundStyle(col.isDay ? .primary : .secondary)
                }
            }
            GridRow {
                rowLabel("천간")
                ForEach(columns, id: \.label) { col in
                    tile(char: col.pillar.stem.korean,
                         element: col.pillar.stem.element,
                         highlighted: col.isDay)  // 일간 = "나"
                }
            }
            GridRow {
                rowLabel("지지")
                ForEach(columns, id: \.label) { col in
                    tile(char: col.pillar.branch.korean,
                         element: col.pillar.branch.element,
                         highlighted: false)
                }
            }
        }
    }

    private func rowLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            .frame(width: 24)
    }

    private func tile(char: String, element: FiveElement, highlighted: Bool) -> some View {
        let color = element.color(dark: scheme == .dark)
        return VStack(spacing: 1) {
            Text(char)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(color)
            Text(element.rawValue)
                .font(.system(size: 8))
                .foregroundStyle(color.opacity(0.75))
        }
        .frame(width: 34, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(scheme == .dark ? 0.16 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(highlighted ? 1.0 : 0.35),
                        lineWidth: highlighted ? 1.5 : 1)
        )
    }
}

// MARK: - 오행 펜타곤

struct FiveElementPentagon: View {
    let counts: [FiveElement: Int]
    let dayElement: FiveElement     // 일간 오행 — "나"
    let todayElement: FiveElement   // 오늘 일진 천간 오행
    let relation: ElementRelation
    @Environment(\.colorScheme) private var scheme

    /// 상생 순환 순서로 시계방향 배치 — 인접 변 = 상생, 한 칸 건너 대각선 = 상극.
    private static let order: [FiveElement] = [.wood, .fire, .earth, .metal, .water]

    /// 강조 화살표의 (시작, 끝). 비화는 화살표 없이 노드 이중 링으로 표시.
    private var highlightArrow: (from: FiveElement, to: FiveElement)? {
        switch relation {
        case .same:       return nil
        case .generates:  return (dayElement, todayElement)   // 내가 오늘을 생함
        case .generated:  return (todayElement, dayElement)   // 오늘이 나를 생함
        case .overcomes:  return (dayElement, todayElement)   // 내가 오늘을 극함
        case .overcome:   return (todayElement, dayElement)   // 오늘이 나를 극함
        }
    }

    var body: some View {
        Canvas { ctx, size in
            let dark = scheme == .dark
            let gold = Color(red: 1.0, green: 0.78, blue: 0.2)
            let faint = Color.secondary.opacity(dark ? 0.30 : 0.35)

            // 상단 라벨 2줄(오행+카운트 / 나·오늘)이 들어갈 헤드룸 확보를 위해
            // 중심을 살짝 아래로, 반지름은 고정.
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 4)
            let radius: CGFloat = 46

            var pos: [FiveElement: CGPoint] = [:]
            for (i, el) in Self.order.enumerated() {
                let a = -CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 5
                pos[el] = CGPoint(x: center.x + cos(a) * radius,
                                  y: center.y + sin(a) * radius)
            }
            func nodeRadius(_ el: FiveElement) -> CGFloat {
                7 + CGFloat(counts[el] ?? 0) * 1.3
            }

            // 1) 배경 순환 — 상생(인접 변, 화살촉) + 상극(대각선, 점선).
            for (i, el) in Self.order.enumerated() {
                let nextGen = Self.order[(i + 1) % 5]
                drawArrow(ctx, from: pos[el]!, to: pos[nextGen]!,
                          fromR: nodeRadius(el), toR: nodeRadius(nextGen),
                          color: faint, lineWidth: 1, headLength: 4)
                let nextOvr = Self.order[(i + 2) % 5]
                drawLine(ctx, from: pos[el]!, to: pos[nextOvr]!,
                         fromR: nodeRadius(el), toR: nodeRadius(nextOvr),
                         color: faint.opacity(0.5), lineWidth: 0.8, dash: [3, 3])
            }

            // 2) 오늘의 관계 강조 — 금색 굵은 화살표.
            if let hl = highlightArrow {
                drawArrow(ctx, from: pos[hl.from]!, to: pos[hl.to]!,
                          fromR: nodeRadius(hl.from), toR: nodeRadius(hl.to),
                          color: gold, lineWidth: 2.5, headLength: 7)
            }

            // 3) 노드 — 크기·채도 ∝ 카운트. 0이면 빈 원으로 자리만 유지.
            for el in Self.order {
                let p = pos[el]!
                let n = counts[el] ?? 0
                let r = nodeRadius(el)
                let color = el.color(dark: dark)
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                if n > 0 {
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(color.opacity(0.25 + Double(n) * 0.08)))
                }
                ctx.stroke(Path(ellipseIn: rect), with: .color(color),
                           lineWidth: el == dayElement ? 2.2 : 1.2)
                if relation == .same && el == dayElement {
                    // 비화 — 화살표가 없으니 이중 링으로 "나=오늘" 표시.
                    let r2 = r + 3.5
                    let rect2 = CGRect(x: p.x - r2, y: p.y - r2, width: r2 * 2, height: r2 * 2)
                    ctx.stroke(Path(ellipseIn: rect2), with: .color(gold), lineWidth: 1.2)
                }

                // 라벨 — 중심 반대 방향 바깥쪽에 "오행 카운트" + 나/오늘 표시.
                let dir = CGVector(dx: (p.x - center.x) / radius, dy: (p.y - center.y) / radius)
                let labelPos = CGPoint(x: p.x + dir.dx * (r + 9), y: p.y + dir.dy * (r + 9))
                ctx.draw(
                    Text("\(el.rawValue)\(n)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(color),
                    at: labelPos
                )
                var roles: [String] = []
                if el == dayElement { roles.append("나") }
                if el == todayElement { roles.append("오늘") }
                if !roles.isEmpty {
                    // 노드에서 멀어지는 방향으로 쌓는다 — 위쪽 반구는 라벨 위, 아래는 아래.
                    let roleDy: CGFloat = dir.dy < 0 ? -10 : 10
                    ctx.draw(
                        Text(roles.joined(separator: "·"))
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(gold),
                        at: CGPoint(x: labelPos.x, y: labelPos.y + roleDy)
                    )
                }
            }
        }
        .frame(width: 156, height: 160)
    }

    // MARK: - Canvas 헬퍼

    /// 노드 원 경계에서 시작/끝나도록 선분을 잘라 그린다.
    private func drawLine(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint,
                          fromR: CGFloat, toR: CGFloat,
                          color: Color, lineWidth: CGFloat, dash: [CGFloat] = []) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / len, uy = dy / len
        let start = CGPoint(x: a.x + ux * (fromR + 2), y: a.y + uy * (fromR + 2))
        let end = CGPoint(x: b.x - ux * (toR + 2), y: b.y - uy * (toR + 2))
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, dash: dash))
    }

    private func drawArrow(_ ctx: GraphicsContext, from a: CGPoint, to b: CGPoint,
                           fromR: CGFloat, toR: CGFloat,
                           color: Color, lineWidth: CGFloat, headLength: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let ux = dx / len, uy = dy / len
        let start = CGPoint(x: a.x + ux * (fromR + 2), y: a.y + uy * (fromR + 2))
        let end = CGPoint(x: b.x - ux * (toR + 3), y: b.y - uy * (toR + 3))

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        ctx.stroke(line, with: .color(color), lineWidth: lineWidth)

        // 화살촉 — 끝점에서 진행 방향 기준 ±150° 두 날개.
        let angle = atan2(uy, ux)
        let wing1 = angle + .pi * 5 / 6
        let wing2 = angle - .pi * 5 / 6
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(wing1) * headLength,
                                 y: end.y + sin(wing1) * headLength))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(wing2) * headLength,
                                 y: end.y + sin(wing2) * headLength))
        ctx.stroke(head, with: .color(color),
                   style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }
}
