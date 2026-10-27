import SwiftUI
import AppKit

// 연말 리캡 스토리 엔진 — 장면 진행, 픽셀 캔버스 그리기 도구, 파티클·흔들림·전환.
//
// 모든 장면은 논리 해상도 240×360에서 정수 좌표로 그리고 화면에선 정수배로 확대한다.
// 블러·안티앨리어싱을 쓰지 않는 게 원칙이라(도트 화풍), 스프라이트는 interpolation(.none)으로,
// 그라데이션은 색 띠(bands)로 대신한다.

enum RecapCanvasSize {
    static let width: CGFloat = 240
    static let height: CGFloat = 360
    static let scale: CGFloat = 2
}

/// 장면 하나. 문구(대사)는 연말에 조건별 풀로 채울 예정이라 지금은 kicker/title(숫자 라벨)만 있다.
struct RecapScene {
    let id: String
    let duration: Double
    /// 데이터가 빈약하면 장면을 건너뛴다(예: Cursor 지출 0원).
    var isAvailable: (RecapFacts) -> Bool = { _ in true }
    let kicker: (RecapFacts) -> String
    let title: (RecapFacts) -> String
    /// 제목 숫자 카운트업 시간.
    var countDuration: Double = 1.2
    let draw: (RecapPainter, Double) -> Void
}

struct RecapParticle {
    var x, y, vx, vy: Double
    var life: Double
    var color: Color
    var size: Double
    var gravity: Double
    var wobble: Double?
}

enum RecapTransition: CaseIterable { case dither, blocks, wipe, flash }

/// 재생 상태. `TimelineView`가 매 프레임 본문을 다시 평가하므로 @Published 없이 그냥 읽는다
/// (프레임마다 publish하면 "view 업데이트 중 publish" 경고만 쌓인다).
@MainActor
final class RecapPlayer {
    let facts: RecapFacts
    let scenes: [RecapScene]
    private(set) var index = 0
    private(set) var time: Double = 0
    var paused = false
    var particles: [RecapParticle] = []
    var shake: Double = 0
    private(set) var transitionLeft: Double = 0
    private(set) var transition: RecapTransition = .dither
    private var fired: Set<String> = []
    private var lastTick: Date?

    static let transitionDuration = 0.5

    init(facts: RecapFacts, scenes: [RecapScene]) {
        self.facts = facts
        self.scenes = scenes.filter { $0.isAvailable(facts) }
    }

    var scene: RecapScene { scenes[index] }
    var isLast: Bool { index == scenes.count - 1 }

    func go(_ i: Int) {
        guard !scenes.isEmpty else { return }
        index = min(max(i, 0), scenes.count - 1)
        time = 0
        particles = []
        shake = 0
        fired = []
        transition = RecapTransition.allCases[index % RecapTransition.allCases.count]
        transitionLeft = Self.transitionDuration
    }

    /// 특정 시점에 멈춘 화면 — 프리뷰(시각 검수) 전용. 파티클처럼 그리는 중에 생기는 효과는 빠진다.
    func freeze(at t: Double) {
        time = t
        transitionLeft = 0
        paused = true
    }

    /// 프레임 진행. dt는 0.05로 자른다 — 창이 가려졌다 돌아오면 한 번에 몇 초가 흘러 장면이 건너뛰어진다.
    func tick(_ now: Date) {
        let dt = min(0.05, lastTick.map { now.timeIntervalSince($0) } ?? 0)
        lastTick = now
        guard !paused else { return }
        time += dt
        transitionLeft -= dt
        if shake > 0.2 { shake *= 0.88 } else { shake = 0 }
        if time >= scene.duration, !isLast { go(index + 1) }
    }

    /// 조건이 처음 참이 되는 프레임에 한 번만 실행(착지 먼지, 폭발 등).
    func once(_ key: String, _ condition: Bool, _ body: () -> Void) {
        guard condition, fired.insert(key).inserted else { return }
        body()
    }

    func stepParticles() {
        guard !paused else { return }
        for i in particles.indices {
            var p = particles[i]
            p.x += p.vx + (p.wobble.map { sin((p.life + $0) / 8) * 0.3 } ?? 0)
            p.y += p.vy
            p.vy += p.gravity
            p.life -= 1
            particles[i] = p
        }
        particles.removeAll { $0.life <= 0 || $0.y > RecapCanvasSize.height + 4 }
    }

    // MARK: 파티클 프리셋

    func burst(_ x: Double, _ y: Double, count: Int, colors: [Color], speed: Double = 2.2,
               gravity: Double = 0.08, life: Double = 40) {
        for i in 0..<count {
            let a = Double.random(in: 0..<(2 * .pi)), v = Double.random(in: 0.4...speed)
            particles.append(RecapParticle(x: x, y: y, vx: cos(a) * v, vy: sin(a) * v - 0.6,
                                           life: life + .random(in: -10...10), color: colors[i % colors.count],
                                           size: Double.random(in: 0..<1) < 0.3 ? 2 : 1, gravity: gravity))
        }
    }

    func confetti(_ count: Int) {
        for i in 0..<count {
            particles.append(RecapParticle(x: .random(in: 0...RecapCanvasSize.width), y: .random(in: -40...0),
                                           vx: .random(in: -0.3...0.3), vy: .random(in: 0.6...1.4), life: 260,
                                           color: RecapPalette.confetti[i % RecapPalette.confetti.count],
                                           size: 2, gravity: 0, wobble: .random(in: 0...6)))
        }
    }

    func firework(_ x: Double, _ y: Double) {
        let sets: [[Color]] = [[RecapPalette.red, RecapPalette.gold], [RecapPalette.blue, .white],
                               [RecapPalette.green, RecapPalette.gold], [RecapPalette.purple, .white]]
        burst(x, y, count: 34, colors: sets.randomElement()!, speed: 2.6, gravity: 0.04, life: 55)
        shake = max(shake, 1)
    }
}

enum RecapPalette {
    static let night = [Color(hex: 0x0D0B1A), Color(hex: 0x120F26), Color(hex: 0x17132F)]
    static let red = Color(hex: 0xFF6B6B)
    static let gold = Color(hex: 0xFFD93D)
    static let green = Color(hex: 0x6BCB77)
    static let blue = Color(hex: 0x4D96FF)
    static let purple = Color(hex: 0xC77DFF)
    static let ink = Color(hex: 0x1B1630)
    static let confetti: [Color] = [red, gold, green, blue, purple, .white]
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// 한 프레임을 그리는 도구 모음. 좌표는 논리 픽셀(240×360) 기준.
@MainActor
struct RecapPainter {
    let ctx: GraphicsContext
    let player: RecapPlayer
    var facts: RecapFacts { player.facts }
    var w: Double { RecapCanvasSize.width }
    var h: Double { RecapCanvasSize.height }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
        ctx.fill(Path(CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())), with: .color(color))
    }

    /// 세로 그라데이션 대신 쓰는 색 띠.
    func bands(_ colors: [Color], from y0: Double = 0, to y1: Double = RecapCanvasSize.height) {
        let bh = (y1 - y0) / Double(colors.count)
        for (i, c) in colors.enumerated() { rect(0, y0 + Double(i) * bh, w, bh + 1, c) }
    }

    func stars(_ t: Double, color: Color = .white) {
        for i in 0..<60 where (Int(t * 3) + i % 3) % 4 != 0 {
            rect(Double((i * 97) % 240), Double((i * 53) % 260), 1, 1, color)
        }
    }

    func ground(_ y: Double, top: Color = Color(hex: 0x4D3F78), body: Color = Color(hex: 0x2B2540)) {
        rect(0, y, w, h - y, body)
        rect(0, y, w, 3, top)
        for x in stride(from: 0.0, to: w, by: 6) { rect(x + (Int(x) % 12 == 0 ? 0 : 2), y - 2, 2, 2, top) }
    }

    /// 펫 한 프레임. (x, y) = 발밑 중앙. 원본이 왼쪽을 보면 뒤집어 오른쪽을 보게 한다.
    func pet(_ kind: PetKind, _ action: PetController.Action, t: Double, x: Double, y: Double,
             scale: Double = 1, faceLeft: Bool = false, variant: Int = 0, fps: Double = 12) {
        let frames = PetSprite.frames(for: kind, action: action)
        guard !frames.isEmpty else { return }
        let img = frames[Int(t * fps) % frames.count]
        let fw = img.size.width * scale, fh = img.size.height * scale
        var c = ctx
        c.translateBy(x: x.rounded(), y: (y - fh).rounded())
        if faceLeft != kind.defaultFacingLeft {
            c.scaleBy(x: -1, y: 1)
        }
        if variant > 0, variant < PetOwnership.prestigeVariant {
            c.addFilter(.hueRotation(.degrees(WalkingCat.hueDegrees(for: variant))))
        }
        c.draw(c.resolve(Image(nsImage: img).interpolation(.none)),
               in: CGRect(x: -(fw / 2).rounded(), y: 0, width: fw, height: fh))
    }

    /// 외곽선 있는 텍스트. 폰트는 임시로 시스템 모노 — 도트 폰트 번들 여부는 미정.
    func text(_ s: String, _ x: Double, _ y: Double, size: CGFloat = 11, color: Color = .white,
              bold: Bool = false, outline: Bool = true) {
        let font = Font.system(size: size, weight: bold ? .heavy : .bold, design: .monospaced)
        if outline {
            let back = ctx.resolve(Text(s).font(font).foregroundColor(.black))
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (1, 1)] {
                ctx.draw(back, at: CGPoint(x: x + dx, y: y + dy), anchor: .center)
            }
        }
        ctx.draw(ctx.resolve(Text(s).font(font).foregroundColor(color)), at: CGPoint(x: x, y: y), anchor: .center)
    }

    func image(_ name: String, x: Double, y: Double, size: Double) {
        guard let img = PetSprite.icon(named: name) else { return }
        ctx.draw(ctx.resolve(Image(nsImage: img).interpolation(.none)),
                 in: CGRect(x: x.rounded(), y: y.rounded(), width: size, height: size))
    }

    func drawParticles() {
        for p in player.particles { rect(p.x, p.y, p.size, p.size, p.color) }
    }

    /// 장면 진입 전환. 남은 시간 비율만큼 화면을 가린다.
    func drawTransition() {
        let p = player.transitionLeft / RecapPlayer.transitionDuration
        guard p > 0 else { return }
        let cover = player.transition == .flash ? Color.white : RecapPalette.night[0]
        switch player.transition {
        case .dither, .flash:
            let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
            for y in stride(from: 0, to: Int(h), by: 2) {
                for x in stride(from: 0, to: Int(w), by: 2) where bayer[((y / 2) % 4) * 4 + (x / 2) % 4] / 16 < p {
                    rect(Double(x), Double(y), 2, 2, cover)
                }
            }
        case .blocks:
            for y in stride(from: 0, to: Int(h), by: 12) {
                for x in stride(from: 0, to: Int(w), by: 12) where Double((x * 7 + y * 13) % 97) / 97 < p {
                    rect(Double(x), Double(y), 12, 12, cover)
                }
            }
        case .wipe:
            let edge = (1 - p) * (w + 60)
            for y in stride(from: 0, to: Int(h), by: 6) {
                rect(edge - Double((y / 6) % 5) * 6, Double(y), w, 6, cover)
            }
        }
    }
}

func recapEase(_ p: Double) -> Double { let c = min(max(p, 0), 1); return 1 - pow(1 - c, 3) }
func recapClamp(_ p: Double) -> Double { min(max(p, 0), 1) }
