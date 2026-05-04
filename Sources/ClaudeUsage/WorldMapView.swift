import SwiftUI

// 도장 페이지 상단의 픽셀 월드맵 — 단일 대륙 + 4 region이 NW/NE/SW/SE 위치에 배치.
//
// 매트릭스 디자인이라 외부 에셋 0. 28×18 그리드, 각 셀이 픽셀 1개.
// 색은 sea / shore / grass / mountain / lake 5종이고 region marker는 PixelIconView로 위에 overlay.
// 사용자 클릭 hit area는 region 위치 ± `regionRadius` 안. 호버/선택 시 marker 강조.

@MainActor
struct WorldMapView: View {
    @Binding var selected: BadgeRegion
    /// 호버된 region — nil이면 전체 풀컬러, non-nil이면 그 region 외 land 영역 dim.
    @State private var hovered: BadgeRegion?

    var body: some View {
        GeometryReader { geo in
            let pxW = geo.size.width / CGFloat(WorldMapDesign.cols)
            let pxH = geo.size.height / CGFloat(WorldMapDesign.rows)

            ZStack {
                // base map — code 0 (sea)은 단색, 그 외(land)는 picture tile.
                // hover/selected region이 아닌 cell은 dim overlay로 어둡게.
                Canvas { context, _ in
                    let tileImages: [Int: GraphicsContext.ResolvedImage] = {
                        var d: [Int: GraphicsContext.ResolvedImage] = [:]
                        for (code, name) in WorldMapDesign.tileImageNames {
                            if let ns = NSImage.mapTile(named: name) {
                                d[code] = context.resolve(Image(nsImage: ns))
                            }
                        }
                        return d
                    }()
                    let seaColor = WorldMapDesign.palette[0]

                    for (row, line) in WorldMapDesign.tiles.enumerated() {
                        for (col, code) in line.enumerated() {
                            let cellRegion = WorldMapDesign.regionForCell(col: col, row: row)
                            let isBright = (cellRegion == hovered) || (cellRegion == selected)
                            let rect = CGRect(x: CGFloat(col) * pxW,
                                              y: CGFloat(row) * pxH,
                                              width: pxW + 0.5,
                                              height: pxH + 0.5)
                            if code == 0 {
                                // sea — 항상 단색.
                                context.fill(Path(rect), with: .color(seaColor))
                            } else if let img = tileImages[code] {
                                // tile image. nearest-neighbor 픽셀 톤 유지.
                                context.draw(img, in: rect)
                                if !isBright {
                                    context.fill(Path(rect), with: .color(.black.opacity(0.45)))
                                }
                            } else {
                                // sprite 로드 실패 fallback — 단색.
                                let base = WorldMapDesign.palette[code]
                                context.fill(Path(rect),
                                             with: .color(isBright ? base : base.opacity(0.4)))
                            }
                        }
                    }
                }
                // 마우스 위치 기반 단일 hover/tap 핸들러 — region별 overlay는 SwiftUI Path의
                // contentShape이 onHover boundary를 좁히지 못해 가장 위 region만 작동했음.
                // onContinuousHover로 좌표를 받아 직접 Voronoi lookup해서 모든 region 정상.
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            let col = Int(p.x / pxW)
                            let row = Int(p.y / pxH)
                            hovered = WorldMapDesign.regionForCell(col: col, row: row)
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture(coordinateSpace: .local) { p in
                        let col = Int(p.x / pxW)
                        let row = Int(p.y / pxH)
                        if let r = WorldMapDesign.regionForCell(col: col, row: row) {
                            selected = r
                        }
                    }

                // 4 region marker (위에 띄움). marker 자체 클릭도 그대로 동작.
                ForEach(BadgeRegion.allCases, id: \.self) { region in
                    if let pos = WorldMapDesign.regionPositions[region] {
                        regionMarker(region, col: pos.col, row: pos.row, pxW: pxW, pxH: pxH)
                    }
                }
            }
        }
        .background(WorldMapDesign.palette[0])
    }

    private func regionMarker(_ region: BadgeRegion, col: Int, row: Int,
                              pxW: CGFloat, pxH: CGFloat) -> some View {
        let isSelected = (region == selected)
        let progress = BadgeRegistry.progress(forRegion: region, Settings.shared)
        let center = CGPoint(x: (CGFloat(col) + 0.5) * pxW,
                             y: (CGFloat(row) + 0.5) * pxH)
        let size: CGFloat = isSelected ? 34 : 26
        // 색은 항상 검정 — 선택은 *halo + 크기*로만 강조해서 픽셀 톤 유지.
        let iconColor: Color = Color(white: 0.10)
        return Button {
            selected = region
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    if isSelected {
                        // 선택 강조 — 노란 halo + 옅은 white outer ring. 픽셀 위에 강한 시각 신호.
                        Circle()
                            .fill(Color.yellow.opacity(0.35))
                            .frame(width: size + 18, height: size + 18)
                            .blur(radius: 4)
                        Circle()
                            .stroke(Color.yellow, lineWidth: 2)
                            .frame(width: size + 6, height: size + 6)
                            .shadow(color: Color.yellow.opacity(0.8), radius: 6)
                    }
                    PixelIconView(icon: region.pixelIcon, color: iconColor)
                        .frame(width: size, height: size)
                        .shadow(color: .black.opacity(0.6), radius: 1.5, x: 1.5, y: 1.5)
                }
                Text("\(progress.cleared)/\(progress.total)")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.black.opacity(0.7))
                    )
            }
            .animation(.easeInOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .position(center)
        .help("\(region.displayName) — \(progress.cleared)/\(progress.total) 뱃지")
    }
}

/// 매트릭스 데이터. 28×18 셀, 단순한 단일 대륙 + 호수 1개 + 산 sprinkle.
enum WorldMapDesign {
    static let cols = 28
    static let rows = 18

    /// 0=sea / 1=shore / 2=grass / 3=mountain / 4=lake.
    /// 비대칭 디자인 — 본토는 좌측 큰 덩어리, 우상단에 작은 반도, 좌하단에 길쭉한 곶.
    /// 호수는 우중간(정확히 가운데 X), 산은 좌상단·좌하단에 군집.
    static let tiles: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0],
        [0,0,0,1,1,2,2,2,2,2,2,2,2,1,1,1,0,0,0,0,1,2,2,2,1,0,0,0],
        [0,0,1,1,2,2,2,2,3,3,2,2,2,2,2,2,1,1,1,1,2,2,2,2,2,1,0,0],
        [0,0,1,2,2,2,2,2,3,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,4,4,2,2,2,2,2,2,1,1,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,4,4,4,4,2,2,2,2,1,1,0,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,4,4,4,2,2,2,2,2,1,0,0,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,1,0,0,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0,0,0,0],
        [0,0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0,0,0,0,0],
        [0,0,0,1,2,2,3,2,2,2,2,2,2,2,2,2,2,2,2,2,1,1,0,0,0,0,0,0],
        [0,0,1,2,2,3,3,2,2,2,2,2,2,2,2,2,2,2,2,1,0,0,0,0,0,0,0,0],
        [0,0,1,2,2,2,3,2,2,2,2,2,2,2,2,2,2,2,1,0,0,0,0,0,0,0,0,0],
        [0,0,1,2,2,2,2,2,2,2,2,2,2,2,2,2,1,1,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
    ]

    /// 4 region marker 위치 (col, row). 비대칭 분포 — 4분면 원점대칭 X.
    /// Coffee: 본토 좌상단 / Vibe: 우상단 반도 안 / Cron: 좌하단 곶 끝 / Repo: 우중하단 본토.
    static let regionPositions: [BadgeRegion: (col: Int, row: Int)] = [
        .coffee: (col: 5,  row: 4),
        .vibe:   (col: 22, row: 3),
        .cron:   (col: 7,  row: 14),
        .repo:   (col: 17, row: 10),
    ]

    /// 각 land cell이 어느 region 영토에 속하는지 — voronoi (가장 가까운 region marker).
    /// region marker가 비대칭이라 영토도 비대칭. 4분면 분할이 아니라 진짜 국가 영토선.
    /// 정적 테이블 (precompute).
    static let regionForCellMap: [Int: BadgeRegion] = {
        var dict: [Int: BadgeRegion] = [:]
        for (row, line) in tiles.enumerated() {
            for (col, code) in line.enumerated() where code > 0 {
                var best: BadgeRegion = .coffee
                var bestDist = Double.infinity
                for region in BadgeRegion.allCases {
                    if let pos = regionPositions[region] {
                        let dx = Double(pos.col - col)
                        let dy = Double(pos.row - row)
                        let d = dx * dx + dy * dy
                        if d < bestDist {
                            bestDist = d
                            best = region
                        }
                    }
                }
                dict[row * cols + col] = best
            }
        }
        return dict
    }()

    static func regionForCell(col: Int, row: Int) -> BadgeRegion? {
        regionForCellMap[row * cols + col]
    }

    /// 한 region에 속하는 모든 cell의 좌표 리스트 (Voronoi 영토).
    static func cellsInRegion(_ region: BadgeRegion) -> [(col: Int, row: Int)] {
        var out: [(Int, Int)] = []
        for (key, r) in regionForCellMap where r == region {
            let row = key / cols
            let col = key % cols
            out.append((col, row))
        }
        return out
    }

    static let palette: [Color] = [
        Color(red: 0.34, green: 0.58, blue: 0.85),   // 0 sea
        Color(red: 0.93, green: 0.86, blue: 0.62),   // 1 shore
        Color(red: 0.50, green: 0.74, blue: 0.42),   // 2 grass
        Color(red: 0.45, green: 0.42, blue: 0.40),   // 3 mountain
        Color(red: 0.45, green: 0.72, blue: 0.92),   // 4 lake (밝은 sea)
    ]

    /// code → tile sprite 이름 매핑 (sea 제외 — sea는 단색 fill).
    /// `Resources/intersect-tiles/` 안 PNG (Intersect-Assets autotile에서 추출).
    static let tileImageNames: [Int: String] = [
        1: "tile_sand",
        2: "tile_grass",
        3: "tile_mountain",
        4: "tile_lake",
    ]
}
