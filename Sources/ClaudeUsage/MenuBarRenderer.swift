import AppKit
import CoreImage
import SwiftUI

/// 메뉴바 위젯의 한 장짜리 이미지 — [% 텍스트][차트 + 그 위를 걷는 펫] — 를 그린다.
///
/// `AppDelegate`에서 분리한 이유: 상태(프레임 인덱스·펫 좌표·회전 누적)와 그리기(그라디언트,
/// Catmull-Rom, 이로치 틴트 캐시)가 400줄 가까이 앱 생명주기 델리게이트에 섞여 있었다.
/// 여기로 모으면 AppDelegate는 status item과 타이머만 다루고, 렌더러는 "Feed → NSImage"라는
/// 순수한 계약만 갖는다.
///
/// 데이터 출처(claude/cursor/codex 분기)는 의도적으로 밖에 둔다 — 렌더러는 무엇을 그리는지만
/// 알고 어디서 왔는지는 모른다.
@MainActor
final class MenuBarRenderer {
    /// 한 tick에 그릴 것 전부. 소스 분기는 호출부(AppDelegate)가 끝낸 뒤 넘긴다.
    struct Feed {
        let pct: Double?
        let history: [(Date, Double)]
        let kind: PetKind
        /// 파티 리더의 이로치 variant.
        let variant: Int
        let theme: PetTheme
    }

    // MARK: - 레이아웃 상수

    private let pctW: CGFloat = 26
    private let chartW: CGFloat = 60
    private let canvasH: CGFloat = 20
    private let petH: CGFloat = 14
    /// 펫이 차트를 좌→우 한 번 지나가는 데 걸리는 초.
    private let traversalSec: Double = 18.0

    // MARK: - 애니메이션 상태

    private var frameIdx: Int = 0
    private var frameAccum: TimeInterval = 0
    private var lastTick: Date = Date()
    /// 펫의 차트 위 정규화 위치(0..1). 좌→우 진행 후 반전, 다시 우→좌. 핑퐁.
    private var petX: Double = 0
    private var petDir: Double = 1
    /// 뒹굴 회전 누적 — big drop 통과 중에만 가속, 빠져나오면 즉시 0.
    private var rollAngle: Double = 0

    // MARK: - 캐시

    /// 직전에 그린 composite의 시각적 키. 모두 같으면 NSImage 생성/할당을 건너뛴다.
    /// 사용률 0% 같은 idle 구간에서 frameIdx·petX bucket·pct·rollAngle bucket이 동시에
    /// 동결되면 시각 결과가 완전히 같음 — 30Hz redraw 비용을 무피해로 절감.
    private var lastRenderKey: RenderKey?
    /// 이로치 sprite 색조 변환용 — CIContext는 생성 비용이 커서 1회만 만들어 재사용.
    private let ciContext = CIContext(options: nil)
    /// 변환 결과 캐시 — (kind, action, frameIdx, variant)당 CI 파이프라인을 1회만 돌린다.
    /// 키 공간이 유한(펫×액션×프레임×variant)해 무한정 커지지 않는다.
    private var tintedSpriteCache: [TintedSpriteKey: NSImage] = [:]

    private struct TintedSpriteKey: Hashable {
        let kind: PetKind
        let action: PetController.Action
        let frameIdx: Int
        let variant: Int
    }

    private struct RenderKey: Equatable {
        let frameIdx: Int
        let petXBucket: Int       // 0..100
        let petDir: Int           // +1 / -1
        let pctBucket: Int        // -1 if nil, else 0..100
        let rollBucket: Int       // angle / 5
        let kind: PetKind
        let variant: Int
        let theme: PetTheme
        let action: PetController.Action
        let historyCount: Int     // history 끝부분이 push되면 변화 감지
    }

    // MARK: - 공개 API

    /// 타이머 재시작 시 호출 — 경과 시간 기준점과 프레임 누적을 초기화한다.
    func reset(now: Date = Date()) {
        lastTick = now
        frameAccum = 0
    }

    /// 30Hz tick. 시각 결과가 직전과 동일하면 `nil`을 반환해 호출부가 이미지 재할당을 건너뛰게 한다.
    func render(feed: Feed, now: Date = Date()) -> NSImage? {
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now

        let pct = max(0, min(100, feed.pct ?? 0))

        // FPS: 6~24, 사용률 비례.
        let fps = 6.0 + (pct / 100.0) * 18.0
        let frameInterval = 1.0 / fps
        frameAccum += dt
        if frameAccum >= frameInterval {
            frameAccum = 0
            frameIdx &+= 1
        }

        // 펫 위치 핑퐁. 사용률 높을수록 traversal 빨라짐.
        let speedMul = 1.0 + (pct / 100.0) * 0.8
        petX += petDir * (dt * speedMul / traversalSec)
        if petX >= 1 { petX = 1; petDir = -1 }
        if petX <= 0 { petX = 0; petDir = 1 }

        // bigDrop 검사 — render와 동일한 inset 기준의 chart-relative xFrac.
        let (cw, ch) = feed.kind.cellSize
        let aspect = CGFloat(cw) / CGFloat(ch)
        let petWApprox = petH * aspect
        let petXPx = petWApprox / 2 + (chartW - petWApprox) * CGFloat(petX)
        let chartXFrac = Double(petXPx / chartW)
        let bigDrop = bigDropAt(xFrac: chartXFrac, dir: petDir, points: feed.history)
        rollAngle = bigDrop ? rollAngle + dt * 720 : 0

        let action: PetController.Action = pct >= 60 ? .run : .walk

        // 시각 결과를 결정하는 모든 입력을 양자화한 키. 직전 tick과 같으면 합성 skip.
        // petX bucket=100단위(1% ≈ 0.6pt at chartW=60), rollAngle bucket=5°.
        let key = RenderKey(
            frameIdx: frameIdx,
            petXBucket: Int(petX * 100),
            petDir: petDir > 0 ? 1 : -1,
            pctBucket: feed.pct.map { Int($0) } ?? -1,
            rollBucket: Int(rollAngle / 5),
            kind: feed.kind,
            variant: feed.variant,
            theme: feed.theme,
            action: action,
            historyCount: feed.history.count
        )
        if key == lastRenderKey { return nil }
        lastRenderKey = key

        return composite(feed: feed, action: action, facingRight: petDir > 0)
    }

    // MARK: - 그리기

    /// [좌하단 baseline 정렬 % | gradient backdrop + 라인 + 라인 위 펫] 한 장.
    /// y 축은 visible window의 min/max 정규화 — 윈도우 안 최댓값이 항상 천장.
    private func composite(feed: Feed, action: PetController.Action, facingRight: Bool) -> NSImage {
        let totalW = pctW + chartW
        let H = canvasH
        let canvas = NSImage(size: NSSize(width: totalW, height: H))
        canvas.lockFocus()
        defer { canvas.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .none

        // 좌측 % 영역 — baseline = 1pt(하단 정렬), 우측 정렬(차트 라인과 붙도록).
        drawPctText(in: NSRect(x: 0, y: 0, width: pctW, height: H), pct: feed.pct)

        // 차트 영역은 우측. 펫 좌표계 등 모두 chart-local origin 기준이므로 ctx translate.
        let pad: CGFloat = 2
        if let outerCtx = NSGraphicsContext.current?.cgContext {
            outerCtx.saveGState()
            outerCtx.translateBy(x: pctW, y: 0)
            defer { outerCtx.restoreGState() }
            drawChartAndPet(W: chartW, H: H, plotMinY: pad, plotMaxY: H - pad,
                            history: feed.history, theme: feed.theme, kind: feed.kind,
                            variant: feed.variant, action: action, frameIdx: frameIdx,
                            petXNorm: petX, facingRight: facingRight, rollAngle: rollAngle,
                            pct: feed.pct, threshold: Settings.shared.petAnxietyThreshold)
        }

        canvas.isTemplate = false
        return canvas
    }

    /// % 텍스트를 영역 우하단(baseline=1)에 그림. 숫자/% 동일 baseline.
    private func drawPctText(in rect: NSRect, pct: Double?) {
        let numFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let pctFont = NSFont.systemFont(ofSize: 8, weight: .regular)

        let baseColor: NSColor
        let numStr: String
        var alpha: CGFloat = 1.0

        if let p = pct {
            let i = max(0, min(100, Int(p.rounded())))
            numStr = "\(i)"
            switch i {
            case 90...:   baseColor = .systemRed
            case 60..<90: baseColor = .systemOrange
            case 30..<60: baseColor = .systemGreen
            default:      baseColor = .secondaryLabelColor
            }
            if i >= 90 {
                let phase = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                alpha = 0.6 + 0.4 * (0.5 + 0.5 * sin(phase * 2 * .pi))
            }
        } else {
            numStr = "—"
            baseColor = .secondaryLabelColor
        }

        let numAttr = NSAttributedString(string: numStr, attributes: [
            .font: numFont,
            .foregroundColor: baseColor.withAlphaComponent(alpha),
        ])
        let pctAttr = NSAttributedString(string: "%", attributes: [
            .font: pctFont,
            .foregroundColor: baseColor.withAlphaComponent(alpha * 0.65),
        ])

        let numSize = numAttr.size()
        let pctSize = pctAttr.size()
        let totalW = numSize.width + 1 + pctSize.width
        // 우측 정렬(차트 라인과 붙음): 영역 우측 끝에서 1pt 안쪽.
        // 단, "100%"(3자리)는 totalW가 영역 폭을 넘겨 baselineX가 음수가 되면 선두 "1"이 캔버스
        // 좌측 밖으로 잘려 "00%"처럼 보인다(#58). rect.minX로 좌측 클램프해 3자리도 꽉 채워 그린다
        // — 2자리는 totalW가 작아 클램프가 발동하지 않아 무변경.
        let baselineX = max(rect.minX, rect.maxX - 1 - totalW)
        let baselineY: CGFloat = 1   // 하단 정렬: descender 여유 1pt
        numAttr.draw(at: NSPoint(x: baselineX, y: baselineY))
        pctAttr.draw(at: NSPoint(x: baselineX + numSize.width + 1, y: baselineY))
    }

    /// 차트 + 펫 (origin은 호출 측이 translate로 맞춰줌).
    private func drawChartAndPet(
        W: CGFloat, H: CGFloat, plotMinY: CGFloat, plotMaxY: CGFloat,
        history: [(Date, Double)], theme: PetTheme, kind: PetKind, variant: Int,
        action: PetController.Action, frameIdx: Int,
        petXNorm: Double, facingRight: Bool, rollAngle: Double,
        pct: Double?, threshold: Double
    ) {
        // 1) gradient backdrop (라인 아래 영역) — 데이터가 있을 때만 색감 입힘.
        //    y 축은 visible window의 min/max로 정규화(가장 큰 값이 천장).
        let pts = history
        let toY: (Double) -> CGFloat
        if pts.count >= 2 {
            let ys = pts.map(\.1)
            let ymin = ys.min() ?? 0
            let ymax = max(ys.max() ?? 1, ymin + 1)
            toY = { v in
                let t = (v - ymin) / (ymax - ymin)
                return plotMinY + CGFloat(t) * (plotMaxY - plotMinY)
            }
        } else {
            toY = { _ in H / 2 }
        }
        if pts.count >= 2, let ctx = NSGraphicsContext.current?.cgContext {
            let n = pts.count
            // gradient fill polygon: 라인 점들 + 우하단 + 좌하단
            let fillPath = CGMutablePath()
            fillPath.move(to: CGPoint(x: 0, y: 0))
            for i in 0..<n {
                let x = W * CGFloat(i) / CGFloat(n - 1)
                fillPath.addLine(to: CGPoint(x: x, y: toY(pts[i].1)))
            }
            fillPath.addLine(to: CGPoint(x: W, y: 0))
            fillPath.closeSubpath()

            // in-app 차트와 동일한 테마 그라디언트 stop을 그대로 사용 — 동적 테마는 pct/threshold가
            // 반영돼 메뉴바에서도 사용량에 따라 눈·용암·심해 등이 차오른다(맵 테마/배경 싱크).
            let stops = theme.fillStops(pct: pct, threshold: threshold)
            let cs = CGColorSpaceCreateDeviceRGB()
            let gradColors = stops.map { cgColor($0.color) } as CFArray
            let gradLocations = stops.map { CGFloat($0.location) }
            if let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: gradLocations) {
                ctx.saveGState()
                ctx.addPath(fillPath)
                ctx.clip()
                ctx.drawLinearGradient(grad,
                                       start: CGPoint(x: 0, y: H),
                                       end:   CGPoint(x: 0, y: 0),
                                       options: [])
                ctx.restoreGState()
            }

            // 2) 부드러운 라인 (Catmull-Rom → Bezier 변환)
            let linePts = (0..<n).map { i -> CGPoint in
                let x = W * CGFloat(i) / CGFloat(n - 1)
                return CGPoint(x: x, y: toY(pts[i].1))
            }
            let smooth = catmullRomPath(points: linePts)
            ctx.saveGState()
            ctx.setStrokeColor(cgColor(theme.lineColor))
            ctx.setLineWidth(1.2)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(smooth)
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: H / 2))
            path.line(to: NSPoint(x: W, y: H / 2))
            path.lineWidth = 1
            NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
            path.stroke()
        }

        // 3) 펫 — 라인 위 (xNorm → 실제 x 매핑 시 양 끝에서 잘리지 않도록 안쪽으로 inset).
        //    variant > 0이면 이로치(shiny) hue/saturation을 in-app WalkingCat과 동일하게 입힌다.
        if let frame = PetSprite.image(for: kind, action: action, frameIndex: frameIdx)
            .map({ tintedSprite($0, kind: kind, action: action, frameIdx: frameIdx, variant: variant) }) {
            let (cw, ch) = kind.cellSize
            let aspect = CGFloat(cw) / CGFloat(ch)
            let petHeight = petH
            let petW = petHeight * aspect
            // 펫 중심이 [petW/2, W - petW/2] 안에 머물도록 매핑 — 좌/우 끝에서 sprite 잘림 방지.
            let xPx = petW / 2 + (W - petW) * CGFloat(petXNorm)
            // 라인 y도 같은 실제 x 기준 + 동일한 toY 함수로 보간.
            let yPx: CGFloat
            if pts.count >= 2 {
                let n = pts.count
                let xFrac = Double(xPx / W)
                let f = Double(n - 1) * xFrac
                let i0 = max(0, min(n - 2, Int(f.rounded(.down))))
                let frac = f - Double(i0)
                let v = pts[i0].1 + (pts[i0 + 1].1 - pts[i0].1) * frac
                yPx = toY(v)
            } else {
                yPx = H / 2
            }
            // 발이 라인 위에 닿도록 펫 중심을 라인 + petH/2 - 살짝 올림
            let cy = yPx + petHeight / 2 - 1

            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.translateBy(x: xPx, y: cy)
                // sprite default direction과 진행 방향이 다르면 가로 flip
                let needFlip = (kind.defaultFacingLeft && facingRight) || (!kind.defaultFacingLeft && !facingRight)
                if needFlip { ctx.scaleBy(x: -1, y: 1) }
                if rollAngle != 0 { ctx.rotate(by: -rollAngle * .pi / 180) }
                let drawRect = NSRect(x: -petW / 2, y: -petHeight / 2, width: petW, height: petHeight)
                frame.draw(in: drawRect,
                           from: NSRect(origin: .zero, size: frame.size),
                           operation: .sourceOver, fraction: 1.0)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - 헬퍼

    /// 펫이 현재 위치한 segment가 "big drop"인지 + 진행 방향이 내려가는 쪽인지.
    /// in-app `bigDropDescent`의 메뉴바 단순화 버전. `xFrac`은 inset 적용된 chart-relative 위치(0..1).
    private func bigDropAt(xFrac: Double, dir: Double, points: [(Date, Double)]) -> Bool {
        guard points.count >= 2 else { return false }
        let ys = points.map(\.1)
        let yrange = max((ys.max() ?? 0) - (ys.min() ?? 0), 1)
        let n = points.count
        let f = Double(n - 1) * xFrac
        let i0 = max(0, min(n - 2, Int(f.rounded(.down))))
        let dy = points[i0 + 1].1 - points[i0].1
        guard abs(dy) >= 0.40 * yrange else { return false }
        // dy < 0: 우측이 더 낮음 → +방향(우향) 진행 시 내려감 → roll
        // dy > 0: 우측이 더 높음 → -방향(좌향) 진행 시 내려감 → roll
        return (dy < 0 && dir > 0) || (dy > 0 && dir < 0)
    }

    /// SwiftUI Color(PetTheme의 stop/line 색) → device RGB CGColor. opacity 포함.
    /// 하드코딩 HSB 테이블을 없애고 PetTheme를 단일 출처로 삼아 메뉴바가 절대 드리프트하지 않도록.
    private func cgColor(_ color: Color) -> CGColor {
        let ns = NSColor(color)
        return (ns.usingColorSpace(.deviceRGB) ?? ns).cgColor
    }

    /// 이로치(shiny) variant 색조를 sprite에 입힌다. in-app `WalkingCat`의
    /// `.hueRotation(.degrees(hueDegrees(for:)))` + `.saturation(1.15)`와 사실상 동일
    /// (SwiftUI와 Core Image의 색 파이프라인이 달라 픽셀 단위로는 근사). variant == 0이면
    /// 변환 비용 없이 원본을 그대로 돌려준다.
    private func tintedSprite(_ image: NSImage, kind: PetKind, action: PetController.Action,
                              frameIdx: Int, variant: Int) -> NSImage {
        guard variant != 0 else { return image }
        let key = TintedSpriteKey(kind: kind, action: action, frameIdx: frameIdx, variant: variant)
        if let cached = tintedSpriteCache[key] { return cached }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return image }
        let angle = Float(WalkingCat.hueDegrees(for: variant) * .pi / 180)
        let ci = CIImage(cgImage: cg)
            .applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: angle])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: Float(1.15)])
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { return image }
        let tinted = NSImage(cgImage: out, size: image.size)
        tintedSpriteCache[key] = tinted
        return tinted
    }

    /// 점들을 Catmull-Rom으로 잇는 부드러운 CGPath. tension 0.5 (Centripetal-ish).
    private func catmullRomPath(points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2 else { return path }
        path.move(to: points[0])
        if points.count == 2 { path.addLine(to: points[1]); return path }
        for i in 0..<(points.count - 1) {
            let p0 = i == 0 ? points[i] : points[i - 1]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = i + 2 < points.count ? points[i + 2] : points[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
