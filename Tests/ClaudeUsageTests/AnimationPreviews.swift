import XCTest
import SwiftUI
import Charts
@testable import ClaudeUsage

/// 움직이는 것들의 검수 — GIF로 굽는다.
///
/// 정지 컷으로는 애니메이션의 실패가 안 보인다. 프레임 순서가 뒤집혔는지, 중간 프레임이 튀는지,
/// 반복 이음매가 끊기는지, 펫이 진행 방향과 반대로 걷는지는 **움직여봐야** 안다. 앱에서 그걸
/// 확인하려면 창을 띄우고 타이밍을 기다려야 해서 반복이 비쌌다.
///
/// 갤러리의 `<img>`가 GIF를 그대로 재생하므로 별도 플레이어가 필요 없다.
///
///   bash scripts/render-previews.sh anim
@MainActor
final class AnimationPreviews: SandboxedTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { PreviewDemoState.seed() }
    }

    // MARK: - 스프라이트 애니메이션

    /// 컬렉션별로 멤버 전원을 한 줄에 세우고 동시에 걷게 한다.
    ///
    /// 프레임이 이미 그림으로 존재하므로 창을 띄울 필요 없이 이어 붙이면 된다. 종마다 프레임 수가
    /// 달라서 각자 자기 길이로 순환시킨다 — 그래야 "이 종만 유독 빨리/느리게 돈다"가 눈에 띈다.
    ///
    /// 걷기 fps는 앱의 기본값(mood.neutral, `6 + walkSpeed*30`)에 맞춘다. 여기서 속도를 임의로
    /// 정하면 "앱에서 어떻게 보이는지"를 검수할 수 없다.
    func testRenderWalkCyclesByCollection() throws {
        _ = try PreviewRenderer.requireOutputDir()
        let fps = 6 + PetMood.neutral.walkSpeed * 30

        for collection in PetCollection.allCases {
            let members = collection.members
            let strips = members.map { PetSprite.frames(for: $0, action: .walk) }
            let maxFrames = strips.map(\.count).max() ?? 0
            guard maxFrames > 0 else { continue }

            // 순환 주기는 멤버 프레임 수의 최소공배수가 이상적이지만 커질 수 있어 상한을 둔다.
            let cycle = min(members.map { PetSprite.frames(for: $0, action: .walk).count }
                                    .reduce(1) { lcm($0, $1) }, 24)
            var canvasFrames: [NSImage] = []
            for f in 0..<cycle {
                let row = zip(members, strips).map { kind, strip -> (String, [NSImage]) in
                    guard !strip.isEmpty else { return (kind.rawValue, []) }
                    return (kind.rawValue, [strip[f % strip.count]])
                }
                canvasFrames.append(
                    PreviewRenderer.contactSheet(rows: row.map { (label: $0.0, images: $0.1) },
                                                 cell: CGSize(width: 48, height: 48)))
            }
            try PreviewRenderer.writeAnimation(
                canvasFrames, frameDelay: 1.0 / fps,
                section: "애니 · 걷기", title: collection.rawValue,
                note: "\(collection.displayName) — 앱과 같은 걷기 fps(\(String(format: "%.1f", fps))). "
                    + "프레임이 튀거나 이음매가 끊기는 종, 유독 빠르거나 느린 종을 찾는다.")
        }
    }

    /// Mythic 특수 모션 — 발동 빈도가 낮아 앱에서 눈으로 잡기 가장 어려운 애니메이션이다.
    func testRenderMythicSpecials() throws {
        _ = try PreviewRenderer.requireOutputDir()

        for kind in Gacha.pool[.mythic] ?? [] {
            for action in [PetController.Action.special1, .special2] {
                let strip = PetSprite.frames(for: kind, action: action)
                guard strip.count > 1 else { continue }
                let frames = strip.map {
                    PreviewRenderer.contactSheet(rows: [(label: "\(kind.rawValue).\(action.rawValue)",
                                                         images: [$0])],
                                                 cell: CGSize(width: 96, height: 96), labelWidth: 190)
                }
                try PreviewRenderer.writeAnimation(
                    frames, frameDelay: 1.0 / 8.0,   // special fps = 8
                    section: "애니 · 특수모션", title: "\(kind.rawValue)-\(action.rawValue)",
                    note: "\(strip.count)프레임 · 앱과 같은 8fps. 동작이 끝까지 이어지는지, 중간이 비지 않는지.")
            }
        }
    }

    // MARK: - 메뉴바

    /// 메뉴바 아이콘 — 사용률 스파크라인 위를 펫이 걷는다. 30Hz로 다시 그려지는 데다 크기가
    /// 20px 남짓이라, 실제로 어떻게 보이는지 앱에서 확인하기가 가장 까다로운 화면이다.
    ///
    /// `render(feed:now:)`가 시각을 받으므로 창 없이 시간만 흘려서 프레임을 만든다.
    func testRenderMenuBarWalk() throws {
        _ = try PreviewRenderer.requireOutputDir()

        let history: [(Date, Double)] = (0..<40).map {
            // 큰 낙차를 하나 심는다 — 펫이 구르거나 튀는 반응(bigDropDescent)이 보이도록.
            let pct: Double = $0 < 20 ? Double($0) * 4 : max(5, 80 - Double($0 - 20) * 7)
            return (Date(timeIntervalSince1970: 1_800_000_000 + Double($0) * 300), pct)
        }
        let cases: [(String, PetKind, Int)] = [
            ("여우-기본", .fox, 0),
            ("전사-이로치", .warrior, 2),
            ("슬라임-프레스티지", .slime, PetOwnership.prestigeVariant),
        ]
        for (title, kind, variant) in cases {
            let renderer = MenuBarRenderer()
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            renderer.reset(now: start)
            let feed = MenuBarRenderer.Feed(pct: 62, history: history, kind: kind,
                                            variant: variant, theme: PetTheme.defaultFor(kind))
            // 30Hz로 3초 — 걷기 한 바퀴와 방향 전환이 들어갈 정도의 길이.
            //
            // render는 보이는 것이 안 바뀐 틱에 nil을 준다(렌더 키로 재합성을 건너뛴다). 그 틱을
            // 빼먹으면 GIF가 실제보다 빨리 돌아 "앱에서 어떻게 보이는지"를 검수할 수 없으므로,
            // 직전 프레임을 그대로 한 칸 더 넣어 시간축을 보존한다.
            var frames: [NSImage] = []
            for i in 0..<90 {
                if let img = renderer.render(feed: feed, now: start.addingTimeInterval(Double(i) / 30.0)) {
                    frames.append(img)
                } else if let last = frames.last {
                    frames.append(last)
                }
            }
            guard !frames.isEmpty else { continue }
            try PreviewRenderer.writeAnimation(
                frames, frameDelay: 1.0 / 30.0,
                section: "애니 · 메뉴바", title: title,
                note: "30Hz 3초. 펫이 선 위를 따라가는지, 진행 방향과 그림 방향이 맞는지, "
                    + "낙차 구간에서 반응하는지.")
        }
    }

    // MARK: - 배틀 재생

    /// 배틀 재생은 로그를 한 스텝씩 흘리며 돌진·피격·KO 애니메이션을 붙인다. 타이밍이 겹치거나
    /// 배너가 늦게 사라지는 문제는 정지 컷으로 안 잡힌다.
    ///
    /// `onAppear`에서 재생이 시작되므로 창에 올려두기만 하면 실제 속도로 진행한다.
    func testRenderBattleReplay() throws {
        _ = try PreviewRenderer.requireOutputDir()

        let a = [PetKind.fox, .wolf, .bear].map { BattlePetSnapshot(kind: $0, variant: 1) }
        let b = [PetKind.slime, .goblin, .bat].map { BattlePetSnapshot(kind: $0, variant: 0) }
        let result = BattleEngine.simulate(teamA: BattleTeam(a), teamB: BattleTeam(b), seed: 42)
        let view = BattleReplayView(aSnaps: a, bSnaps: b, result: result) { EmptyView() }

        // 10fps × 60프레임 = 6초. 로그 한 스텝이 360ms라 초반 십수 턴이 담긴다.
        try PreviewRenderer.renderAnimated(
            view, size: CGSize(width: 398, height: 420),
            frameCount: 60, frameInterval: 0.1,
            section: "애니 · 배틀", title: "재생-3v3",
            note: "실제 재생 속도. 돌진→피격→체력바 감소가 순서대로 붙는지, 궁극기 배너가 "
                + "제때 사라지는지.")
    }

    // MARK: - 길드 사무실

    /// 사무실 펫은 A* 경로로 가구를 피해 돌아다닌다. 가구를 통과하거나 벽에 끼는 건 움직여야 보인다.
    func testRenderGuildOfficeIdleLoop() throws {
        _ = try PreviewRenderer.requireOutputDir()

        let info = PreviewDemoState.guildInfo()
        let view = GuildOfficeView(
            info: info,
            rearrangeMode: .constant(false),
            previewFloorTheme: .constant(nil),
            previewWallTheme: .constant(nil),
            onSetFurniture: { _ in }, onSetLogoPos: { _, _ in }, onBuyFurniture: { _, _ in },
            onPlaceDecor: { _, _ in }, onRemoveDecor: { _ in }, onApplyTheme: {},
            purchaseSheetOpen: .constant(false))

        // 10fps × 55프레임 ≈ 5.5초. 펫이 자리에서 일어나 한 바퀴 도는 데 충분하고, 이보다 길게
        // 잡으면 GIF 한 장이 2MB를 넘어 갤러리 한 페이지를 혼자 무겁게 만든다.
        try PreviewRenderer.renderAnimated(
            view, size: CGSize(width: 560, height: 400),
            frameCount: 55, frameInterval: 0.1,
            section: "애니 · 길드", title: "사무실-배회",
            note: "펫이 가구를 통과하지 않는지, 벽에 끼지 않는지, 걷는 방향과 그림 방향이 맞는지.")
    }

    // MARK: - RP 이펙트

    /// 깃발 이펙트 — 길드 로고가 있을 때와 없을 때.
    ///
    /// 정지 컷으로는 판별이 안 되는 게 정확히 이 이펙트다. 천의 파동은 깃대 쪽 진폭이 0에 가깝고
    /// 자유단만 크게 흔들려야 "매달린 천"으로 읽히는데, 한 프레임만 보면 그냥 물결친 사각형이다.
    /// 로고판은 66×44 도트를 컬럼 단위로 잘라 그리므로 이음매(세로 줄무늬)도 여기서 확인한다.
    func testRenderFlagEffect() throws {
        _ = try PreviewRenderer.requireOutputDir()
        let cases: [(String, NSImage?, String)] = [
            ("이펙트-깃발-길드로고", GuildLogo.image(for: "s:2", guildID: "preview"),
             "길드 소속 펫 — 로고가 물결을 타는지, 컬럼 이음매가 세로줄로 보이지 않는지."),
            ("이펙트-깃발-기본", nil,
             "무소속(또는 길드를 모르는 남의 펫) — 기본 2색 깃발로 폴백하는지."),
        ]
        for (title, logo, note) in cases {
            try PreviewRenderer.renderAnimated(
                FlagEffectPreviewStage(guildFlag: logo),
                size: CGSize(width: 220, height: 130),
                frameCount: 40, frameInterval: 1.0 / 15.0,
                section: "애니 · 이펙트", title: title, note: note)
        }
    }

    /// 깃발 — **좁은 호출부** 재현. 위 무대(220×130)는 여유가 많아 잘림이 드러나지 않는다.
    ///
    /// 이 이펙트가 실제로 깨진 곳이 정확히 여기였다. 그리는 주체가 `Canvas`라 자기 bounds 밖은
    /// 잘려 나가는데, 깃발만 펫 밖으로 크게 뻗어서(발끝 위로 1.5×펫높이) 44pt 차트에서는 펫이
    /// 라인 위쪽에 있을 때 통째로 사라졌고 110pt 상점 셀에서는 천이 반토막 났다.
    /// 검수 포인트는 하나 — **점선 안(=실제 셀)에서 깃발이 온전한가.**
    func testRenderFlagEffectTightCanvas() throws {
        _ = try PreviewRenderer.requireOutputDir()

        for facingRight in [true, false] {
            try PreviewRenderer.renderAnimated(
                FlagShopCellStage(facingRight: facingRight),
                size: CGSize(width: 130, height: 130),
                frameCount: 30, frameInterval: 1.0 / 15.0,
                section: "애니 · 이펙트", title: "깃발-상점셀-\(facingRight ? "우향" : "좌향")",
                note: "상점 미리보기 셀(110×110, 점선). 천이 셀 밖으로 나가 잘리지 않는지.")
        }

        // 사용량이 높을수록 펫이 라인 위쪽 = 깃발이 쓸 세로 여유가 없다. 셋 다 깃발이 보여야 한다.
        for peak in [95.0, 55.0, 15.0] {
            try PreviewRenderer.renderAnimated(
                FlagChartStage(peak: peak),
                size: CGSize(width: 320, height: 92),
                frameCount: 30, frameInterval: 1.0 / 12.0,
                section: "애니 · 이펙트", title: "깃발-차트-\(Int(peak))%",
                note: "44pt sparkline. 깃발이 보이는지 + 차트 위아래 텍스트를 침범하지 않는지.")
        }
    }

    private func lcm(_ a: Int, _ b: Int) -> Int {
        guard a > 0, b > 0 else { return max(a, b, 1) }
        return a / gcd(a, b) * b
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}


/// 깃발 이펙트 검수용 무대 — `WalkingCat`이 하는 합성(backdrop 이펙트 → 펫 → particles 이펙트)을
/// 같은 좌표 규약(center/footY/petHeight)으로 최소 재현한다. 실제 렌더는 `PetEffectOverlay`가 한다.
@MainActor
private struct FlagEffectPreviewStage: View {
    let guildFlag: NSImage?

    private let petHeight: CGFloat = 54
    private var center: CGPoint { CGPoint(x: 130, y: 76) }
    private var footY: CGFloat { 103 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let frames = PetSprite.frames(for: .fox, action: .walk)
            ZStack {
                PetEffectOverlay(
                    effects: [.flag], placement: .backdrop,
                    center: center, footY: footY, petHeight: petHeight,
                    facingRight: true, isMoving: true, guildFlag: guildFlag)
                if !frames.isEmpty,
                   let img = PetSprite.image(for: .fox, action: .walk,
                                             frameIndex: Int(t * 8) % frames.count) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: petHeight, height: petHeight)
                        .position(center)
                }
            }
        }
    }
}


/// 상점 미리보기 셀 재현 — `GachaView.PetPreviewView`의 좌표를 그대로 옮겼다(110×110 셀,
/// center(55,55), footY 95, petHeight 70). 점선이 실제 셀 경계라 잘림이 눈에 보인다.
@MainActor
private struct FlagShopCellStage: View {
    let facingRight: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let frames = PetSprite.frames(for: .fox, action: .walk)
            ZStack {
                PetEffectOverlay(effects: [.flag], placement: .backdrop,
                                 center: CGPoint(x: 55, y: 55), footY: 95,
                                 petHeight: 70, facingRight: facingRight, isMoving: true,
                                 guildFlag: GuildLogo.myFlagImage)
                if !frames.isEmpty,
                   let img = PetSprite.image(for: .fox, action: .walk,
                                             frameIndex: Int(t * 8) % frames.count) {
                    Image(nsImage: img).interpolation(.none).resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 84)
                        .scaleEffect(x: facingRight ? -1 : 1, y: 1)
                        .position(x: 55, y: 55)
                }
            }
            .frame(width: 110, height: 110)
            .border(Color.secondary.opacity(0.6), width: 1)
        }
    }
}

/// 차트 재현 — `MainView.chartPet`이 하는 배선(chartOverlay → plotFrame → WalkingCat)을 같은
/// 높이(44pt)로 옮겼다. 위아래 텍스트는 깃발이 차트 밖 이웃을 침범하는지 보기 위한 것.
@MainActor
private struct FlagChartStage: View {
    let peak: Double

    private var data: [(Date, Double)] {
        let now = Date()
        return (0..<12).map { i in
            (now.addingTimeInterval(Double(i - 12) * 600), peak * (0.75 + 0.25 * sin(Double(i))))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("윗줄 — 침범 확인용").font(.system(size: 10)).foregroundStyle(.secondary)
            Chart {
                ForEach(data, id: \.0) { item in
                    AreaMark(x: .value("t", item.0), y: .value("v", item.1))
                        .foregroundStyle(.blue.opacity(0.2))
                    LineMark(x: .value("t", item.0), y: .value("v", item.1))
                        .foregroundStyle(.blue)
                }
            }
            .chartYScale(domain: 0...100)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    WalkingCat(points: data, proxy: proxy, plotFrame: geo[proxy.plotAreaFrame],
                               kind: .fox, effects: [.flag])
                }
            }
            .frame(height: 44)
            Text("아랫줄 — 침범 확인용").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(8)
    }
}
