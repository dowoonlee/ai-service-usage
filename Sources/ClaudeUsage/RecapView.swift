import SwiftUI
import AppKit

// 연말 리캡 — 설정의 "2026 리캡" 섹션에서 여는 스토리 창.
//
// 문구(펫 내레이션)는 연말에 활성 유저들의 대표 펫을 보고 조건별 풀로 만들 예정이라
// 대사창은 비워 두고, 장면 제목에는 숫자 라벨만 둔다.

@MainActor
final class RecapWindowController: NSWindowController, SingleWindowPresenting {
    static let shared = RecapWindowController()

    convenience init() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "2026 Recap"
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    /// 열 때마다 사실을 새로 읽는다 — JSONL 전체 스캔이라 창 안에서 반복 호출하지 않는다.
    func present() {
        let host = NSHostingController(rootView: RecapStoryView(facts: RecapFacts.load()))
        window?.contentViewController = host
        window?.setContentSize(NSSize(width: RecapCanvasSize.width * RecapCanvasSize.scale,
                                      height: RecapCanvasSize.height * RecapCanvasSize.scale))
        window?.center()
        bringToFront()
    }
}

struct RecapStoryView: View {
    @State private var player: RecapPlayer
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let holdToPause: TimeInterval = 0.22

    init(facts: RecapFacts) {
        let p = RecapPlayer(facts: facts, scenes: RecapScenes.all)
        p.go(0)
        _player = State(initialValue: p)
    }

    /// 이미 준비된 플레이어로 띄운다 — 프리뷰에서 장면·시점을 고정해 찍을 때.
    init(player: RecapPlayer) {
        _player = State(initialValue: player)
    }

    var body: some View {
        TimelineView(.animation) { tl in
            // WalkingCat과 같은 방식 — 매 프레임 컨트롤러를 직접 진행시킨다(publish 없음).
            let _ = player.tick(tl.date)
            ZStack(alignment: .top) {
                Canvas { ctx, size in
                    MainActor.assumeIsolated { render(ctx, size) }
                }
                progressBar
                header
                VStack { Spacer(); dialog }
                if player.paused {
                    Text("❚❚ 일시정지").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 20).padding(.trailing, 14)
                }
            }
        }
        .frame(width: RecapCanvasSize.width * RecapCanvasSize.scale,
               height: RecapCanvasSize.height * RecapCanvasSize.scale)
        .background(Color.black)
        .contentShape(Rectangle())
        .gesture(tapAndHold)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) { player.go(player.index + 1); return .handled }
        .onKeyPress(.leftArrow) { player.go(player.index - 1); return .handled }
        .onKeyPress(.space) { player.paused.toggle(); return .handled }
    }

    @MainActor
    private func render(_ base: GraphicsContext, _ size: CGSize) {
        var ctx = base
        ctx.scaleBy(x: size.width / RecapCanvasSize.width, y: size.height / RecapCanvasSize.height)
        if player.shake > 0.2 {
            ctx.translateBy(x: Double.random(in: -player.shake...player.shake).rounded(),
                            y: Double.random(in: -player.shake...player.shake).rounded())
        }
        let painter = RecapPainter(ctx: ctx, player: player)
        player.scene.draw(painter, player.time)
        player.stepParticles()
        painter.drawParticles()
        painter.drawTransition()
    }

    // MARK: 오버레이

    private var progressBar: some View {
        HStack(spacing: 3) {
            ForEach(player.scenes.indices, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.22))
                        Rectangle().fill(.white).frame(width: g.size.width * progress(of: i))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 10).padding(.top, 8)
    }

    private func progress(of i: Int) -> Double {
        if i < player.index { return 1 }
        if i > player.index { return 0 }
        return recapClamp(player.time / player.scene.duration)
    }

    private var header: some View {
        let s = player.scene
        let reveal = recapClamp(player.time / 0.35)
        return VStack(spacing: 6) {
            Text(s.kicker(player.facts))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(RecapPalette.gold)
            Text(Self.countUp(s.title(player.facts), progress: recapEase((player.time - 0.3) / s.countDuration)))
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(2)
                .padding(.horizontal, 12)
        }
        .shadow(color: .black, radius: 0, x: 2, y: 2)
        // 계단식 등장(4단) — 부드러운 페이드 대신 도트 느낌.
        .opacity((reveal * 4).rounded(.down) / 4)
        .offset(y: -8 * (1 - (reveal * 4).rounded(.down) / 4))
        .padding(.top, 24)
    }

    private var dialog: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                narratorPortrait
                    .frame(width: 64, height: 64)
                    .background(Color(hex: 0x2B2540))
                    .border(Color(hex: 0x4A4266), width: 2)
                Text(player.facts.game.narrator.kind.displayName)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(RecapPalette.gold)
            }
            // 대사 자리 — 연말에 대표 펫별 문구 풀로 채운다.
            Text("…")
                .font(.system(size: 16, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(height: 150, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(RecapPalette.night[0])
        .overlay(Rectangle().strokeBorder(.white, lineWidth: 4))
        .overlay(Rectangle().inset(by: 4).strokeBorder(.black, lineWidth: 4))
        .padding(10)
    }

    private var narratorPortrait: some View {
        let sel = player.facts.game.narrator
        let frames = PetSprite.frames(for: sel.kind, action: .sit)
        return Group {
            if !frames.isEmpty {
                Image(nsImage: frames[Int(player.time * 10) % frames.count])
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .hueRotation(.degrees(sel.variant == 0 ? 0 : WalkingCat.hueDegrees(for: sel.variant)))
                    .scaleEffect(x: sel.kind.defaultFacingLeft ? -1 : 1)
                    .padding(6)
            }
        }
    }

    // MARK: 입력 — 오른쪽 탭 다음 / 왼쪽 탭 이전 / 길게 눌러 일시정지

    private var tapAndHold: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressStart == nil else { return }
                pressStart = Date()
                holdTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.holdToPause * 1e9))
                    if !Task.isCancelled { player.paused = true }
                }
            }
            .onEnded { value in
                holdTask?.cancel()
                defer { pressStart = nil }
                if let start = pressStart, Date().timeIntervalSince(start) >= Self.holdToPause {
                    player.paused = false
                    return
                }
                let half = RecapCanvasSize.width * RecapCanvasSize.scale / 2
                player.go(player.index + (value.location.x > half ? 1 : -1))
            }
    }

    /// 제목 속 숫자만 0부터 카운트업("1,802번" → "0번" … "1,802번").
    static func countUp(_ title: String, progress: Double) -> String {
        guard progress < 1 else { return title }
        let pattern = try! NSRegularExpression(pattern: #"[\d,]+(\.\d+)?"#)
        var out = title
        for m in pattern.matches(in: title, range: NSRange(title.startIndex..., in: title)).reversed() {
            guard let r = Range(m.range, in: title) else { continue }
            let token = String(title[r])
            guard let v = Double(token.replacingOccurrences(of: ",", with: "")) else { continue }
            let decimals = token.split(separator: ".").dropFirst().first?.count ?? 0
            let cur = v * progress
            let s = decimals > 0 ? String(format: "%.\(decimals)f", cur)
                                 : (token.contains(",") ? Int(cur).formatted() : String(Int(cur)))
            out.replaceSubrange(Range(m.range, in: out)!, with: s)
        }
        return out
    }
}
