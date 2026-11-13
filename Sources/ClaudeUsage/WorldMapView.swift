import SwiftUI

// 도장 페이지 상단의 픽셀 월드맵 — 단일 연속 월드 + 2단 카메라 (M1 엔진).
//
// docs/plans/gym-map-redesign.md 확정안의 M1 슬라이스. 기존 28×18 대륙을 96×40 월드
// 서쪽에 그대로 배치(시각 동등성)하고 카메라 두 모드를 얹었다:
//   · 월드 뷰 — 항해 밴드(48×20) 서쪽 정렬. 대륙 전체 + 동쪽 빈 바다(M3 Cloud 제도 자리).
//   · 지역 뷰 — region 클릭 시 영토 중심으로 팬+줌(2.1×). 바다 클릭 / "월드" 버튼 /
//     선택 마을 재클릭으로 복귀.
// 지오메트리·카메라 계산은 WorldMap.swift(순수, unit test 대상) — 이 파일은 렌더/입력만.
//
// 렌더는 기존과 동일하게 Canvas + nearest-neighbor 타일. sea는 배경 단색 1회 fill로
// 대체해 셀 draw 수를 줄였다(구 구현은 sea 셀도 개별 fill). 카메라 전환 중에만
// TimelineView 프레임 루프가 돌고(paused 제어), 정지 상태에선 재렌더가 없다.

@MainActor
struct WorldMapView: View {
    /// 창이 안 보이면 프레임 루프를 멈춘다 (WindowVisibility.swift).
    @Environment(\.windowIsVisible) private var windowIsVisible
    @Binding var selected: BadgeRegion
    /// 시즌 이벤트 섬 — nil이면 평소 월드(70×38). 있으면 월드가 위로 `EventIsland.skyRows`만큼 늘고
    /// 그 하늘 띠에 섬이 뜬다. 섬은 region이 아니라서 선택 상태를 따로 든다.
    var island: EventIsland? = nil
    @Binding var islandSelected: Bool
    /// 섬 지역 뷰에서 걸어다닐 보스 선봉(스킨·모자 포함). nil이면 아바타 없음.
    var islandAvatar: SkinnedPet? = nil
    /// 맵 전체에 눈을 내릴지 — 시즌 연출이 켜졌을 때. 섬(보스 창)과 따로 받는다.
    var snowing: Bool = false
    /// 호버된 region — nil이면 selected만 강조, non-nil이면 그 region도 강조.
    @State private var hovered: BadgeRegion?
    @State private var islandHovered = false

    /// `initiallyZoomed` — 지역 뷰로 시작(프리뷰용. 앱은 항상 월드 뷰에서 시작한다).
    init(selected: Binding<BadgeRegion>, island: EventIsland? = nil,
         islandSelected: Binding<Bool> = .constant(false), islandAvatar: SkinnedPet? = nil,
         snowing: Bool = false, initiallyZoomed: Bool = false) {
        self.snowing = snowing
        self._selected = selected
        self.island = island
        self._islandSelected = islandSelected
        self.islandAvatar = islandAvatar
        self._mode = State(initialValue: initiallyZoomed ? .region : .world)
    }

    private var skyRows: Int { island == nil ? 0 : EventIsland.skyRows }
    /// 섬이 사라진 뒤(시즌 종료)에도 바인딩이 true로 남아 있을 수 있어 섬 유무와 함께 본다.
    private var onIsland: Bool { island != nil && islandSelected }

    /// 월드 뷰 ↔ 지역 뷰. selected와 독립 — 월드 뷰에서도 선택 region은 유지·강조된다.
    private enum Mode { case world, region }
    @State private var mode: Mode = .world

    /// 카메라 전환 tween. nil이면 정지 상태(타겟 카메라 직접 렌더).
    @State private var tween: CameraTween?
    /// TimelineView 프레임 루프 제어 — 전환 중에만 돈다.
    @State private var animating = false
    /// 연속 클릭 시 이전 예약(asyncAfter)이 새 tween을 지우지 않도록 하는 세대 카운터.
    @State private var camGen = 0

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // 지역 뷰에선 트레이너 아바타가 걸어다니므로 계속 프레임을 돌린다(전환 중에도).
            // 섬이 있으면 구름이 흐르고 눈이 내리므로 월드 뷰에서도 프레임을 돌린다.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !windowIsVisible
                                        || (!animating && mode != .region && island == nil))) { timeline in
                let cam = currentCamera(at: timeline.date, size: size)
                ZStack {
                    MapTileCanvas(camera: cam, highlighted: highlightedRegions,
                                  townProgress: townProgresses, discovered: discoveredSet,
                                  mastered: masteredRegions,
                                  island: island, islandHighlighted: onIsland || islandHovered,
                                  snowing: snowing,
                                  time: timeline.date.timeIntervalSinceReferenceDate)
                    inputLayer(cam: cam, size: size)
                    avatarCanvas(cam: cam, date: timeline.date, size: size)
                }
                .overlay(alignment: .topLeading) {
                    if mode == .region {
                        backButton(size: size)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if mode == .region {
                        minimap(fullSize: size)
                    }
                }
            }
        }
        .background(WorldMap.palette[0])
    }

    /// 밝게(dim 없이) 그릴 region — 선택 + 호버.
    private var highlightedRegions: Set<BadgeRegion> {
        // 섬을 고른 동안엔 지상 지역은 전부 어둡게(호버만 밝게) — 선택이 하나로 읽히게.
        var s: Set<BadgeRegion> = onIsland ? [] : [selected]
        if let hovered { s.insert(hovered) }
        return s
    }

    /// 마스터(8/8)한 region — 테라포밍 렌더용.
    private var masteredRegions: Set<String> { Settings.shared.masteredRegions }

    /// 마을별 진행 스냅샷 — Canvas에 값으로 넘겨 클로저의 actor 격리를 피한다.
    private var townProgresses: [BadgeRegion: TownProgress] {
        var d: [BadgeRegion: TownProgress] = [:]
        for r in BadgeRegion.allCases {
            let p = BadgeRegistry.progress(forRegion: r, Settings.shared)
            d[r] = TownProgress(cleared: p.cleared, total: p.total)
        }
        return d
    }

    /// 발견된 region — 구름 fog 해제 상태. (gym-map-redesign.md 소프트 게이트)
    /// coffee는 온보딩 시작점으로 항상 발견. 진행이 있는 region은 자동 발견(기존 유저 마이그레이션 겸).
    /// 클라우드 제도는 본토 뱃지 8개 이상('항구 개방') 시 발견.
    private var discoveredSet: Set<String> {
        let prog = townProgresses
        var s = Settings.shared.discoveredRegions
        s.insert(BadgeRegion.coffee.rawValue)
        for r in BadgeRegion.allCases where (prog[r]?.cleared ?? 0) > 0 {
            s.insert(r.rawValue)
        }
        let mainlandCleared = BadgeRegion.allCases
            .filter { $0.continent == .mainland }
            .reduce(0) { $0 + (prog[$1]?.cleared ?? 0) }
        if mainlandCleared >= 8 {
            for r in GymContinent.cloud.regions { s.insert(r.rawValue) }
        }
        return s
    }

    /// 관장 아바타 — 선택 도장 앞 도로 위를 걷는 그 지역 관장 캐릭터.
    /// 지역 뷰에서만(월드 뷰는 너무 작음). WalkingCat과 같은 시간 기반 무상태 위치 계산.
    /// Canvas로 그린다(SwiftUI Image는 ImageRenderer 스냅샷과 상성 이슈).
    private func avatarCanvas(cam: MapCamera, date: Date, size: CGSize) -> some View {
        Canvas { context, sz in
            guard cam.zoom > 14 else { return }
            let t = date.timeIntervalSinceReferenceDate
            if onIsland, let island {
                // 섬에선 보스 선봉(스킨·모자)이 도장 앞 눈밭을 걷는다.
                guard let pet = islandAvatar else { return }
                let phase = CGFloat(sin(t * 0.8))
                let wx = CGFloat(island.town.col) + 0.5 + phase * 1.6
                let wy = CGFloat(island.town.row) + 1.45
                let p = cam.screenPoint(ofWorld: CGPoint(x: wx, y: wy), in: sz)
                // 지상 관장(1.05셀)보다 크게 — 흰 스킨이라 같은 크기론 광장 위에서도 잘 안 보인다. 발밑 그림자도 둔다.
                let s = max(20, cam.zoom * 1.9)
                context.fill(Path(ellipseIn: CGRect(x: p.x - s * 0.28, y: p.y - s * 0.09, width: s * 0.56, height: s * 0.16)),
                             with: .color(.black.opacity(0.28)))
                guard let img = PetSprite.composedImage(for: pet.kind, action: .walk, frameIndex: Int(t * 8) % 4,
                                                        skin: pet.skin, headwear: pet.headwear) else { return }
                let goingLeft = phase < 0
                let flip = pet.kind.defaultFacingLeft ? !goingLeft : goingLeft
                let rect = CGRect(x: p.x - s / 2, y: p.y - s, width: s, height: s)
                context.drawLayer { layer in
                    if flip {
                        layer.translateBy(x: p.x, y: 0)
                        layer.scaleBy(x: -1, y: 1)
                        layer.translateBy(x: -p.x, y: 0)
                    }
                    layer.draw(context.resolve(Image(nsImage: img)), in: rect)
                }
                return
            }
            guard let town = WorldMap.towns[selected],
                  discoveredSet.contains(selected.rawValue) else { return }
            let kind = GymLeader.leader(for: selected).kind
            let phase = CGFloat(sin(t * 0.8))            // -1…1 좌우 왕복
            let wx = CGFloat(town.col) + 0.5 + phase * 1.6
            let wy = CGFloat(town.row) + 1.45            // 마을 밑동 앞(도로변)
            let p = cam.screenPoint(ofWorld: CGPoint(x: wx, y: wy), in: sz)
            let s = max(12, cam.zoom * 1.05)
            let frame = Int(t * 8) % 4
            guard let img = PetSprite.image(for: kind, action: .walk, frameIndex: frame) else { return }
            let resolved = context.resolve(Image(nsImage: img))
            let goingLeft = phase < 0
            let flip = kind.defaultFacingLeft ? !goingLeft : goingLeft
            let rect = CGRect(x: p.x - s / 2, y: p.y - s, width: s, height: s)
            context.drawLayer { layer in
                if flip {
                    layer.translateBy(x: p.x, y: 0)
                    layer.scaleBy(x: -1, y: 1)
                    layer.translateBy(x: -p.x, y: 0)
                }
                layer.draw(resolved, in: rect)
            }
        }
        .allowsHitTesting(false)
    }

    /// 지역 뷰 우측 하단 미니맵 — 전체 월드 축소 + 현재 뷰포트 사각형.
    private func minimap(fullSize: CGSize) -> some View {
        let mmSize = CGSize(width: 96, height: 54)
        let worldCam = MapCamera.worldView(in: mmSize, skyRows: skyRows)
        let regionCam = focusCamera(size: fullSize)
        let vis = regionCam.visibleCellRect(in: fullSize)
        let tl = worldCam.screenPoint(ofWorld: CGPoint(x: vis.minX, y: vis.minY), in: mmSize)
        let br = worldCam.screenPoint(ofWorld: CGPoint(x: vis.maxX, y: vis.maxY), in: mmSize)
        return ZStack(alignment: .topLeading) {
            MapTileCanvas(camera: worldCam, highlighted: Set(BadgeRegion.allCases),
                          showBuildings: false, discovered: discoveredSet, mastered: masteredRegions,
                          island: island, islandHighlighted: true)
            Rectangle()
                .stroke(Color.white, lineWidth: 1)
                .frame(width: max(4, br.x - tl.x), height: max(4, br.y - tl.y))
                .offset(x: tl.x, y: tl.y)
        }
        .frame(width: mmSize.width, height: mmSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.55), lineWidth: 1))
        .padding(7)
    }

    // MARK: - 입력 (hover / tap)

    /// 마우스 좌표 → 카메라 역변환 → 셀 lookup. 구 구현의 Voronoi 직접 lookup 패턴을
    /// 카메라 좌표계로 일반화한 것 — region별 overlay hit-test 이슈(가장 위 region만
    /// 작동)를 피하는 단일 핸들러 구조는 그대로 유지.
    private func inputLayer(cam: MapCamera, size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let w = cam.worldPoint(ofScreen: p, in: size)
                    let col = Int(floor(w.x)), row = Int(floor(w.y))
                    islandHovered = island?.contains(col: col, row: row) ?? false
                    hovered = islandHovered ? nil : WorldMap.regionForCell(col: col, row: row)
                case .ended:
                    hovered = nil
                    islandHovered = false
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let w = cam.worldPoint(ofScreen: p, in: size)
                let col = Int(floor(w.x)), row = Int(floor(w.y))
                if island?.contains(col: col, row: row) == true {
                    handleIslandTap(size: size)
                } else {
                    handleTap(WorldMap.regionForCell(col: col, row: row), size: size)
                }
            }
    }

    /// 섬 클릭 → 섬 선택 + 섬 뷰로 줌인. 지상에서 올 땐 도로가 없으니 줌아웃했다 들어가는 arc.
    private func handleIslandTap(size: CGSize) {
        guard !(mode == .region && onIsland) else { return }
        let fromRegion = mode == .region
        islandSelected = true
        go(.region, arc: fromRegion, size: size)
    }

    private func handleTap(_ region: BadgeRegion?, size: CGSize) {
        switch (mode, region) {
        case (_, .some(let r)) where onIsland:
            // 섬에서 지상 영토로 — 도로가 없으니 직선(arc)으로 내려간다.
            let wasRegionMode = mode == .region
            islandSelected = false
            selected = r
            go(.region, arc: wasRegionMode, size: size)
        case (.world, .some(let r)):
            // 월드 뷰에서 영토 클릭 → 선택 + 지역 뷰로 줌인.
            selected = r
            go(.region, size: size)
        case (.region, .some(let r)) where r != selected:
            // 지역 뷰에서 다른 영토 클릭 → 도로를 따라 카메라 이동.
            let path = WorldMap.shortestPath(from: selected, to: r)
            selected = r
            go(.region, route: path, size: size)
        case (.region, .none):
            // 바다 클릭 → 월드 뷰 복귀.
            go(.world, size: size)
        default:
            break
        }
    }

    // MARK: - 마을 마커

    // MARK: - 월드 복귀 버튼 (지역 뷰 전용)

    private func backButton(size: CGSize) -> some View {
        Button {
            go(.world, size: size)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .bold))
                Text("월드")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.65)))
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("월드 뷰로 돌아가기")
    }

    // MARK: - 카메라 상태

    private func targetCamera(size: CGSize) -> MapCamera {
        switch mode {
        case .world:  return .worldView(in: size, skyRows: skyRows)
        case .region: return focusCamera(size: size)
        }
    }

    /// 지역 뷰의 타겟 — 섬을 골랐으면 섬, 아니면 선택 region.
    private func focusCamera(size: CGSize) -> MapCamera {
        if onIsland, let island { return .islandView(island, in: size) }
        return .regionView(selected, in: size, skyRows: skyRows)
    }

    private func currentCamera(at now: Date, size: CGSize) -> MapCamera {
        if let tween, !tween.finished(at: now) {
            return tween.value(at: now)
        }
        return targetCamera(size: size)
    }

    /// 모드 전환 + 카메라 tween 시작. from은 현재 보간값이라 전환 중 재클릭도 매끄럽다.
    private func go(_ newMode: Mode, arc: Bool = false, route: [BadgeRegion] = [], size: CGSize) {
        let now = Date()
        let from = currentCamera(at: now, size: size)
        mode = newMode
        var tw: CameraTween
        if route.count > 1 {
            // 도로 따라 — route[0]=출발 마을 카메라부터 목적지까지 폴리라인 팬.
            // (go 시점엔 selected가 이미 목적지라 currentCamera를 쓰면 왔다갔다 하므로 route를 그대로 사용)
            let wps = route.map { MapCamera.regionView($0, in: size, skyRows: skyRows) }
            tw = CameraTween(waypoints: wps, start: now, followRoute: true)
            tw.duration = 0.34 + Double(route.count - 1) * 0.14   // 경로 길수록 오래
        } else {
            tw = CameraTween(from: from, to: targetCamera(size: size), start: now, arc: arc)
            if arc { tw.duration = 0.52 }
        }
        tween = tw
        animating = true
        camGen += 1
        let gen = camGen
        // tween 종료 후 프레임 루프 정지. 세대 검사로 연속 클릭 레이스 방지.
        DispatchQueue.main.asyncAfter(deadline: .now() + tw.duration + 0.08) {
            guard camGen == gen else { return }
            animating = false
            tween = nil
        }
    }
}

/// 카메라 하나로 월드 타일을 그리는 순수 렌더 뷰 — WorldMapView가 카메라 tween 프레임마다
/// 주입한다. 타일 레이어를 분리해 두면 M2의 루트·건물·아바타·구름 오버레이를 같은 좌표계
/// 위에 겹치기 쉽고, 오프스크린 스냅샷(ImageRenderer)으로 임의 카메라를 렌더할 수 있다.
/// 입력/마커/카메라 상태는 WorldMapView 소관 — 이 뷰는 terrain만.
struct MapTileCanvas: View {
    let camera: MapCamera
    /// dim 없이(밝게) 그릴 region. 나머지 land는 0.45 어둡게.
    var highlighted: Set<BadgeRegion> = []
    /// 마을별 진행(cleared,total) — Canvas 클로저의 actor 격리를 피하려 미리 받아둔다.
    var townProgress: [BadgeRegion: TownProgress] = [:]
    /// 도장 건물·도로를 그릴지 (미니맵 등에서 끌 수 있게).
    var showBuildings: Bool = true
    /// 발견된 region(rawValue) — 미발견은 구름으로 덮는다(fog of war). 빈 집합이면 fog 미적용.
    var discovered: Set<String> = []
    /// 마스터(8/8)한 region(rawValue) — 테라포밍 색 오버레이 + 정복 왕관.
    var mastered: Set<String> = []
    /// 시즌 이벤트 섬(하늘 띠에 뜬다). nil이면 그리지 않는다.
    var island: EventIsland? = nil
    var islandHighlighted: Bool = false
    var snowing: Bool = false
    /// 구름 흐름·눈 낙하용 시각. 정지 렌더(미니맵)는 0.
    var time: TimeInterval = 0

    var body: some View {
        Canvas { context, size in
            // sea — 전체 배경 1회 fill (sea 셀 개별 draw 제거).
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(WorldMap.palette[0]))
            let tileImages: [Int: GraphicsContext.ResolvedImage] = {
                var d: [Int: GraphicsContext.ResolvedImage] = [:]
                for (code, name) in WorldMap.tileImageNames {
                    if let ns = NSImage.mapTile(named: name) {
                        d[code] = context.resolve(Image(nsImage: ns))
                    }
                }
                return d
            }()
            // 보이는 셀만 순회 — 월드가 커져도 렌더 비용은 뷰포트에 비례.
            let visible = camera.visibleCellRect(in: size)
            let c0 = max(0, Int(visible.minX.rounded(.down)))
            let c1 = min(WorldMap.cols - 1, Int(visible.maxX.rounded(.up)))
            let r0 = max(0, Int(visible.minY.rounded(.down)))
            let r1 = min(WorldMap.rows - 1, Int(visible.maxY.rounded(.up)))
            guard c0 <= c1, r0 <= r1 else { return }
            for row in r0...r1 {
                for col in c0...c1 {
                    let code = WorldMap.code(col: col, row: row)
                    if code == 0 { continue }
                    let cellRegion = WorldMap.regionForCell(col: col, row: row)
                    let isBright = cellRegion.map { highlighted.contains($0) } ?? false
                    let sp = camera.screenPoint(ofWorld: CGPoint(x: CGFloat(col), y: CGFloat(row)),
                                                in: size)
                    // +0.5 겹침 — 셀 사이 sub-pixel 이음매 방지 (구 구현과 동일).
                    let rect = CGRect(x: sp.x, y: sp.y,
                                      width: camera.zoom + 0.5, height: camera.zoom + 0.5)
                    if let img = tileImages[code] {
                        context.draw(img, in: rect)
                        if !isBright {
                            context.fill(Path(rect), with: .color(.black.opacity(0.45)))
                        }
                    } else {
                        // sprite 로드 실패 fallback — 단색.
                        let base = WorldMap.palette[code]
                        context.fill(Path(rect),
                                     with: .color(isBright ? base : base.opacity(0.4)))
                    }
                    // 테라포밍 — 마스터한 region의 바이옴 진화 색.
                    if let cr = cellRegion, mastered.contains(cr.rawValue),
                       let tint = WorldMap.terraformTint(cr) {
                        context.fill(Path(rect), with: .color(tint))
                    }
                    // 미발견 region — 구름으로 덮는다(fog of war, 테마=Cloud).
                    if !discovered.isEmpty, let cr = cellRegion,
                       !discovered.contains(cr.rawValue) {
                        context.fill(Path(rect), with: .color(Color(white: 0.92).opacity(0.72)))
                    }
                }
            }

            if let island {
                drawIslandGround(island, in: &context, size: size)
            }
            guard showBuildings else { return }
            defer {
                // 섬 위 구조물과 눈은 지상 건물·데코까지 다 그린 뒤 맨 위에.
                if let island {
                    drawIslandProps(island, in: &context, size: size)
                }
                if snowing { drawSnowfall(in: &context, size: size) }
            }

            // 다리 — vibe(본토)-guild(제도) 두 대륙을 잇는 바다 위 나무 판자.
            if !WorldMap.bridgeCells.isEmpty,
               discovered.isEmpty || (discovered.contains(BadgeRegion.vibe.rawValue)
                                      && discovered.contains(BadgeRegion.guild.rawValue)),
               let bns = NSImage.mapTile(named: "tile_bridge") {
                let bimg = context.resolve(Image(nsImage: bns))
                for cell in WorldMap.bridgeCells {
                    let sp = camera.screenPoint(ofWorld: CGPoint(x: CGFloat(cell.col), y: CGFloat(cell.row)),
                                                in: size)
                    context.draw(bimg, in: CGRect(x: sp.x, y: sp.y,
                                                  width: camera.zoom + 0.5, height: camera.zoom + 0.5))
                }
            }

            // 도로 — 마을 간 연결(포켓몬식 루트). 타일 위, 건물 아래.
            // 양쪽 마을에 진행이 있으면 '포장된 길'(황토), 아니면 희미한 점선.
            for (a, b) in WorldMap.routes {
                guard let ta = WorldMap.towns[a], let tb = WorldMap.towns[b] else { continue }
                if !discovered.isEmpty,
                   !(discovered.contains(a.rawValue) && discovered.contains(b.rawValue)) { continue }
                let pa = camera.screenPoint(ofWorld: CGPoint(x: CGFloat(ta.col) + 0.5,
                                                             y: CGFloat(ta.row) + 0.5), in: size)
                let pb = camera.screenPoint(ofWorld: CGPoint(x: CGFloat(tb.col) + 0.5,
                                                             y: CGFloat(tb.row) + 0.5), in: size)
                var path = Path(); path.move(to: pa); path.addLine(to: pb)
                let lit = (townProgress[a]?.cleared ?? 0) > 0 && (townProgress[b]?.cleared ?? 0) > 0
                let w = max(1.5, camera.zoom * 0.16)
                // 모든 도로 동일 스타일(tan 포장 + 얇은 어두운 케이싱) — 대륙/지형/진행도 무관하게 같은
                // 이미지로 읽힌다. 개통(양쪽 마을 진행) 도로만 살짝 밝고 굵게(미세한 진행 신호), 미개통은
                // 같은 tan을 흐리게 — 흰 점선/검은 실선 같은 딴판 스타일을 없앴다.
                let roadW = lit ? w : w * 0.85
                context.stroke(path, with: .color(.black.opacity(0.35)),
                               style: StrokeStyle(lineWidth: roadW + 1.6, lineCap: .round))
                let fill = lit ? Color(red: 0.86, green: 0.70, blue: 0.44)
                               : Color(red: 0.74, green: 0.63, blue: 0.47).opacity(0.7)
                context.stroke(path, with: .color(fill),
                               style: StrokeStyle(lineWidth: roadW, lineCap: .round))
            }

            // 데코 — 나무/바위/선인장 (타일 위, 밑동 anchor). 발견 지역만.
            let decoSizes: [String: (CGFloat, CGFloat)] = [
                "tree": (1.9, 1.9), "tree2": (1.1, 2.2), "bush": (0.95, 1.9),
                "pine": (1.0, 2.0), "rock": (0.8, 0.8), "cactus": (0.85, 1.7),
            ]
            for d in WorldMapData.decos {
                if !discovered.isEmpty,
                   let r = WorldMap.regionForCell(col: d.col, row: d.row),
                   !discovered.contains(r.rawValue) { continue }
                guard let sz = decoSizes[d.kind],
                      let ns = NSImage.mapTile(named: "deco_\(d.kind)") else { continue }
                let w = sz.0 * camera.zoom, h = sz.1 * camera.zoom
                let foot = camera.screenPoint(
                    ofWorld: CGPoint(x: CGFloat(d.col) + 0.5 + CGFloat(d.ox),
                                     y: CGFloat(d.row) + 1 + CGFloat(d.oy)), in: size)
                if foot.x < -w || foot.x > size.width + w { continue }
                context.draw(context.resolve(Image(nsImage: ns)),
                             in: CGRect(x: foot.x - w / 2, y: foot.y - h, width: w, height: h))
            }

            // region별 도장 건물 — 지붕색으로 지역 구분(조립 건물 96×128).
            let cellW: CGFloat = 1.6
            let bw = cellW * camera.zoom
            let bh = bw * 128.0 / 96.0
            for region in BadgeRegion.allCases {
                guard let town = WorldMap.towns[region] else { continue }
                if !discovered.isEmpty, !discovered.contains(region.rawValue) { continue }
                guard let ns = NSImage.mapTile(named: WorldMap.buildingSprite(for: region)) else { continue }
                let bimg = context.resolve(Image(nsImage: ns))
                let foot = camera.screenPoint(
                    ofWorld: CGPoint(x: CGFloat(town.col) + 0.5, y: CGFloat(town.row) + 0.95),
                    in: size)
                if foot.x < -bw || foot.x > size.width + bw { continue }
                if highlighted.contains(region) {
                    let gw = bw * 1.25, gh = bw * 0.42
                    context.fill(Path(ellipseIn: CGRect(x: foot.x - gw / 2, y: foot.y - gh * 0.5,
                                                        width: gw, height: gh)),
                                 with: .color(.yellow.opacity(0.55)))
                }
                context.draw(bimg, in: CGRect(x: foot.x - bw / 2, y: foot.y - bh,
                                              width: bw, height: bh))
                // 정복 표식 — 마스터(전 tier 격파)면 왕관, 관장을 한 번이라도 격파(≥localhost)했으면 깃발.
                if mastered.contains(region.rawValue) {
                    let cw = bw * 0.55
                    let icon = BadgePixelIcons.crown
                    let ch = cw * icon.viewBox.height / icon.viewBox.width
                    let ox = foot.x - cw / 2, oy = foot.y - bh - ch - 2
                    let sx = cw / icon.viewBox.width, sy = ch / icon.viewBox.height
                    for rr in icon.rects() {
                        context.fill(Path(CGRect(x: ox + rr.minX * sx, y: oy + rr.minY * sy,
                                                 width: rr.width * sx, height: rr.height * sy)),
                                     with: .color(.yellow))
                    }
                } else if (townProgress[region]?.cleared ?? 0) > 0 {
                    // 관장 격파 페넌트 — 지붕 우측 깃대 + 삼각 깃발(정복 중 표식).
                    let poleW = max(1, bw * 0.03)
                    let poleH = bh * 0.30
                    let px = foot.x + bw * 0.20
                    let topY = foot.y - bh - 2
                    context.fill(Path(CGRect(x: px, y: topY, width: poleW, height: poleH)),
                                 with: .color(.white.opacity(0.9)))
                    let fw = bw * 0.28, fh = poleH * 0.5
                    var tri = Path()
                    tri.move(to: CGPoint(x: px + poleW, y: topY))
                    tri.addLine(to: CGPoint(x: px + poleW + fw, y: topY + fh * 0.5))
                    tri.addLine(to: CGPoint(x: px + poleW, y: topY + fh))
                    tri.closeSubpath()
                    context.fill(tri, with: .color(Color(red: 0.95, green: 0.35, blue: 0.30)))
                }
                if camera.zoom > 16, let prog = townProgress[region] {
                    let txt = Text("\(prog.cleared)/\(prog.total)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    let r = context.resolve(txt)
                    let ts = r.measure(in: CGSize(width: 200, height: 50))
                    let cy = foot.y + 3
                    let bg = CGRect(x: foot.x - ts.width / 2 - 4, y: cy,
                                    width: ts.width + 8, height: ts.height + 2)
                    context.fill(Path(roundedRect: bg, cornerRadius: 5),
                                 with: .color(.black.opacity(0.7)))
                    context.draw(r, at: CGPoint(x: foot.x, y: cy + (ts.height + 2) / 2),
                                 anchor: .center)
                }
            }
        }
    }
}

// MARK: - 이벤트 섬 렌더

extension MapTileCanvas {
    private func cellRect(col: CGFloat, row: CGFloat, size: CGSize) -> CGRect {
        let sp = camera.screenPoint(ofWorld: CGPoint(x: col, y: row), in: size)
        return CGRect(x: sp.x, y: sp.y, width: camera.zoom + 0.5, height: camera.zoom + 0.5)
    }

    /// 바다에 드리운 그림자 → 밑동 바위 → 지면 타일 → 섬을 감싼 구름. 지상 타일 다음, 도로·건물 전에 그린다.
    fileprivate func drawIslandGround(_ island: EventIsland, in context: inout GraphicsContext, size: CGSize) {
        let z = camera.zoom
        // 그림자 — 섬 바로 아래 바다 위. 섬이 "떠 있다"는 유일한 깊이 단서라 넉넉히.
        let shadowCenter = camera.screenPoint(
            ofWorld: CGPoint(x: island.center.x, y: CGFloat(island.originRow + island.rows) + 6.2), in: size)
        let sw = CGFloat(island.cols) * z * 0.86, sh = z * 2.3
        context.fill(Path(ellipseIn: CGRect(x: shadowCenter.x - sw / 2, y: shadowCenter.y - sh / 2,
                                            width: sw, height: sh)),
                     with: .color(.black.opacity(0.17)))

        // 밑동 — 열마다 가운데로 갈수록 깊어지는 바위. 아래로 갈수록 어둡게.
        let rock = NSImage.mapTile(named: "tile_rock").map { context.resolve(Image(nsImage: $0)) }
        for c in island.originCol..<(island.originCol + island.cols) {
            guard let bottom = island.bottomRow(col: c) else { continue }
            let depth = island.undersideDepth(col: c)
            for d in 1...depth {
                let rect = cellRect(col: CGFloat(c), row: CGFloat(bottom + d), size: size)
                if let rock { context.draw(rock, in: rect) }
                else { context.fill(Path(rect), with: .color(WorldMap.palette[8])) }
                let shade = 0.22 + 0.5 * Double(d) / Double(depth + 1)
                context.fill(Path(rect), with: .color(Color(red: 0.10, green: 0.12, blue: 0.22).opacity(shade)))
            }
        }

        // 지면.
        var tiles: [Int: GraphicsContext.ResolvedImage] = [:]
        for r in 0..<island.rows {
            for c in 0..<island.cols {
                let col = island.originCol + c, row = island.originRow + r
                let code = island.code(col: col, row: row)
                guard code > 0 else { continue }
                if tiles[code] == nil, let name = WorldMap.tileImageNames[code],
                   let ns = NSImage.mapTile(named: name) {
                    tiles[code] = context.resolve(Image(nsImage: ns))
                }
                let rect = cellRect(col: CGFloat(col), row: CGFloat(row), size: size)
                if let img = tiles[code] { context.draw(img, in: rect) }
                else { context.fill(Path(rect), with: .color(WorldMap.palette[code])) }
                if !islandHighlighted {
                    // 지상 region의 비선택 dim(0.45)보다 옅게 — 이벤트 섬은 고르지 않아도 눈에 띄어야 한다.
                    context.fill(Path(rect), with: .color(.black.opacity(0.14)))
                }
            }
        }

        // 구름 — 섬 양옆과 밑동을 감싼다. 시간에 따라 좌우로 느리게 흐른다.
        let puffs: [(dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat, speed: Double)] = [
            (-2.2, 2.6, 5.0, 1.7, 0.21), (CGFloat(island.cols) - 2.6, 3.2, 5.6, 1.8, 0.17),
            (1.5, CGFloat(island.rows) + 2.3, 4.4, 1.5, 0.26), (CGFloat(island.cols) - 6.0, CGFloat(island.rows) + 3.0, 5.2, 1.6, 0.19),
            (-4.5, -0.6, 3.6, 1.2, 0.15), (CGFloat(island.cols) + 1.0, 0.2, 4.0, 1.3, 0.23),
        ]
        for (i, p) in puffs.enumerated() {
            let drift = CGFloat(sin(time * p.speed + Double(i) * 1.7)) * 0.7
            let center = camera.screenPoint(
                ofWorld: CGPoint(x: CGFloat(island.originCol) + p.dx + p.w / 2 + drift,
                                 y: CGFloat(island.originRow) + p.dy), in: size)
            // 겹친 타원 3개로 뭉게구름 실루엣.
            for (ox, oy, sx, sy) in [(-0.28, 0.12, 0.62, 0.72), (0.0, -0.10, 0.70, 1.0), (0.30, 0.14, 0.58, 0.68)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                let w = p.w * z * sx, h = p.h * z * sy
                context.fill(Path(ellipseIn: CGRect(x: center.x + ox * p.w * z - w / 2,
                                                    y: center.y + oy * p.h * z - h / 2, width: w, height: h)),
                             with: .color(.white.opacity(0.82)))
            }
        }
    }

    /// 섬 위 구조물 — 선택 글로우, 데코, 도장 건물, 이름표.
    fileprivate func drawIslandProps(_ island: EventIsland, in context: inout GraphicsContext, size: CGSize) {
        let z = camera.zoom
        for d in island.decos.sorted(by: { $0.row < $1.row }) {
            guard let ns = NSImage.mapTile(named: d.image) else { continue }
            let w = d.width * z, h = d.height * z
            let foot = camera.screenPoint(ofWorld: CGPoint(x: CGFloat(d.col) + 0.5, y: CGFloat(d.row) + 1), in: size)
            context.draw(context.resolve(Image(nsImage: ns)),
                         in: CGRect(x: foot.x - w / 2, y: foot.y - h, width: w, height: h))
        }
        let foot = camera.screenPoint(
            ofWorld: CGPoint(x: CGFloat(island.town.col) + 0.5, y: CGFloat(island.town.row) + 0.95), in: size)
        var topY = foot.y
        if let ns = NSImage.mapTile(named: island.building) {
            let bw = 1.6 * z
            let bh = bw * ns.size.height / max(1, ns.size.width)
            if islandHighlighted {
                let gw = bw * 1.25, gh = bw * 0.42
                context.fill(Path(ellipseIn: CGRect(x: foot.x - gw / 2, y: foot.y - gh * 0.5, width: gw, height: gh)),
                             with: .color(.yellow.opacity(0.55)))
            }
            context.draw(context.resolve(Image(nsImage: ns)),
                         in: CGRect(x: foot.x - bw / 2, y: foot.y - bh, width: bw, height: bh))
            topY = foot.y - bh
        }
        // 이름표 — 월드 뷰에서도 "저기 뭔가 있다"가 읽혀야 진입점 구실을 한다.
        let label = context.resolve(
            Text("❄ \(island.label)").font(.system(size: 9, weight: .bold)).foregroundColor(.white))
        let ts = label.measure(in: CGSize(width: 200, height: 50))
        let bg = CGRect(x: foot.x - ts.width / 2 - 5, y: topY - ts.height - 6,
                        width: ts.width + 10, height: ts.height + 3)
        context.fill(Path(roundedRect: bg, cornerRadius: 5),
                     with: .color(Color(red: 0.75, green: 0.16, blue: 0.16).opacity(0.92)))
        context.draw(label, at: CGPoint(x: bg.midX, y: bg.midY), anchor: .center)
    }

    /// 맵 전체에 내리는 눈 — 화면 좌표. 오피스 창밖 눈과 같은 무상태 함수를 쓴다.
    fileprivate func drawSnowfall(in context: inout GraphicsContext, size: CGSize) {
        for f in WindowSnow.flakes(at: time * 0.45) {
            let side = max(1, (f.size * 1.3).rounded())
            let rect = CGRect(x: (f.x * size.width).rounded(), y: (f.y * size.height).rounded(),
                              width: side, height: side)
            context.fill(Path(rect), with: .color(.white.opacity(f.opacity * 0.9)))
        }
    }
}

/// 마을 진행 스냅샷 — MapTileCanvas에 값으로 전달(Canvas 클로저 actor 격리 회피).
struct TownProgress {
    let cleared: Int
    let total: Int
}
