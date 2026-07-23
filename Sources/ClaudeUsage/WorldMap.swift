import Foundation
import SwiftUI

// 월드 지오메트리 + 카메라 — v11 손디자인 맵(WorldMapData) 기반.
//
// 두 대륙(온대 본토 + 극한기후 제2 대륙)을 하나의 70×38 좌표계에 담는다.
// 지형/데코/마을은 Python 맵 디자이너가 만든 결정론적 데이터(WorldMapData)에서 읽고,
// 이 파일은 그 위의 기하 계산(code lookup, Voronoi 영토, 카메라 변환)만 담당한다.
// 렌더/입력은 WorldMapView.swift.

/// 월드 셀 좌표 (정수 격자).
struct WorldCell: Hashable {
    let col: Int
    let row: Int
}

enum WorldMap {
    static let cols = WorldMapData.cols   // 70
    static let rows = WorldMapData.rows   // 38

    /// terrain 문자열을 [[Int]]로 1회 파싱 — code()가 O(1)이 되도록.
    static let grid: [[Int]] = WorldMapData.terrain.map { line in
        line.map { Int(String($0)) ?? 0 }
    }

    /// 월드 좌표의 terrain code. 밖은 sea(0).
    /// 0 sea / 1 sand / 2 grass / 3 mountain / 4 lake / 5 dune / 6 snow / 7 lava / 8 rock.
    static func code(col: Int, row: Int) -> Int {
        guard row >= 0, row < rows, col >= 0, col < cols else { return 0 }
        return grid[row][col]
    }

    static let palette: [Color] = [
        Color(red: 0.34, green: 0.58, blue: 0.85),   // 0 sea
        Color(red: 0.93, green: 0.86, blue: 0.62),   // 1 sand
        Color(red: 0.50, green: 0.74, blue: 0.42),   // 2 grass
        Color(red: 0.45, green: 0.42, blue: 0.40),   // 3 mountain
        Color(red: 0.45, green: 0.72, blue: 0.92),   // 4 lake
        Color(red: 0.90, green: 0.78, blue: 0.42),   // 5 dune (Arena)
        Color(red: 0.82, green: 0.90, blue: 0.95),   // 6 snow (Daily)
        Color(red: 0.72, green: 0.20, blue: 0.15),   // 7 lava (OSS)
        Color(red: 0.55, green: 0.55, blue: 0.58),   // 8 rock (Guild)
    ]

    /// code → tile sprite 이름 (sea 제외). `Resources/intersect-tiles/`.
    static let tileImageNames: [Int: String] = [
        1: "tile_sand",
        2: "tile_grass",
        3: "tile_mountain",
        4: "tile_lake",
        5: "tile_dune",
        6: "tile_snow",
        7: "tile_lava",
        8: "tile_rock",
    ]

    /// 마을 — WorldMapData.towns(rawValue)에서 변환.
    static let towns: [BadgeRegion: WorldCell] = {
        var d: [BadgeRegion: WorldCell] = [:]
        for (k, v) in WorldMapData.towns {
            if let r = BadgeRegion(rawValue: k) { d[r] = WorldCell(col: v.col, row: v.row) }
        }
        return d
    }()

    /// 마을 간 도로(포켓몬식 루트). 병렬 진행이라 순서 강제가 아니라 연결의 기록.
    static let routes: [(BadgeRegion, BadgeRegion)] = [
        (.registry, .coffee), (.registry, .vibe), (.registry, .repo), (.registry, .cron),
        // 클라우드 제도 — 4 마을 순환 연결(guild/daily/oss/arena).
        (.guild, .daily), (.guild, .oss), (.oss, .arena), (.daily, .oss), (.arena, .guild),
        (.vibe, .guild),   // 두 대륙을 잇는 다리 위 도로
    ]

    /// 두 대륙을 잇는 다리 — vibe(본토)-guild(제도) 직선의 바다(sea) 셀들.
    static let bridgeCells: [WorldCell] = {
        guard let v = towns[.vibe], let g = towns[.guild] else { return [] }
        let steps = max(abs(g.col - v.col), abs(g.row - v.row))
        guard steps > 0 else { return [] }
        var out: [WorldCell] = []
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let col = Int((Double(v.col) + Double(g.col - v.col) * t).rounded())
            let row = Int((Double(v.row) + Double(g.row - v.row) * t).rounded())
            if code(col: col, row: row) == 0 { out.append(WorldCell(col: col, row: row)) }
        }
        return out
    }()

    /// 두 대륙을 가르는 경계 col — 서쪽 본토, 동쪽 제2 대륙.
    static let continentSplitCol = 40
    static func continentOf(col: Int) -> GymContinent {
        col < continentSplitCol ? .mainland : .cloud
    }

    /// 각 land cell이 어느 region 영토인지 — 같은 대륙 마을끼리만 Voronoi.
    /// key = row * cols + col. 정적 precompute.
    static let regionForCellMap: [Int: BadgeRegion] = {
        var dict: [Int: BadgeRegion] = [:]
        let mainRegions = GymContinent.mainland.regions
        let cloudRegions = GymContinent.cloud.regions
        for row in 0..<rows {
            for col in 0..<cols where code(col: col, row: row) > 0 {
                let pool = continentOf(col: col) == .mainland ? mainRegions : cloudRegions
                var best = pool[0]
                var bestDist = Double.infinity
                for region in pool {
                    guard let town = towns[region] else { continue }
                    let dx = Double(town.col - col)
                    let dy = Double(town.row - row)
                    let d = dx * dx + dy * dy
                    if d < bestDist { bestDist = d; best = region }
                }
                dict[row * cols + col] = best
            }
        }
        return dict
    }()

    static func regionForCell(col: Int, row: Int) -> BadgeRegion? {
        guard col >= 0, row >= 0, col < cols, row < rows else { return nil }
        return regionForCellMap[row * cols + col]
    }

    /// 영토 중심(구성 셀 좌표 평균) — 지역 뷰 카메라 타겟.
    static let territoryCenter: [BadgeRegion: CGPoint] = {
        var sums: [BadgeRegion: (x: Double, y: Double, n: Int)] = [:]
        for (key, region) in regionForCellMap {
            let row = key / cols
            let col = key % cols
            var s = sums[region] ?? (0, 0, 0)
            s.x += Double(col) + 0.5
            s.y += Double(row) + 0.5
            s.n += 1
            sums[region] = s
        }
        var out: [BadgeRegion: CGPoint] = [:]
        for (region, s) in sums where s.n > 0 {
            out[region] = CGPoint(x: s.x / Double(s.n), y: s.y / Double(s.n))
        }
        return out
    }()

    /// region별 도장 건물 스프라이트(지붕색으로 지역 구분). `building_<rawValue>.png`.
    static func buildingSprite(for region: BadgeRegion) -> String {
        "building_\(region.rawValue)"
    }

    /// 두 마을 사이 도로 최단 경로(routes 그래프 BFS). 결과는 from…to를 포함한 마을 순서.
    /// 마을→마을 카메라 전환이 도로를 따라 움직이도록 하는 waypoint용.
    static func shortestPath(from: BadgeRegion, to: BadgeRegion) -> [BadgeRegion] {
        if from == to { return [to] }
        var adj: [BadgeRegion: [BadgeRegion]] = [:]
        for (a, b) in routes {
            adj[a, default: []].append(b)
            adj[b, default: []].append(a)
        }
        var queue: [BadgeRegion] = [from]
        var prev: [BadgeRegion: BadgeRegion] = [:]
        var visited: Set<BadgeRegion> = [from]
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            if cur == to { break }
            for nb in adj[cur] ?? [] where !visited.contains(nb) {
                visited.insert(nb); prev[nb] = cur; queue.append(nb)
            }
        }
        guard visited.contains(to) else { return [from, to] }   // 미연결 → 직선 fallback
        var path: [BadgeRegion] = [to]
        var c = to
        while c != from, let p = prev[c] { path.append(p); c = p }
        return path.reversed()
    }
}

// MARK: - 카메라

/// 연속 좌표 카메라 — `center`는 월드 셀 좌표(연속), `zoom`은 화면 px / 셀. 셀은 항상 정사각.
struct MapCamera: Equatable {
    var center: CGPoint
    var zoom: CGFloat

    func origin(in size: CGSize) -> CGPoint {
        CGPoint(x: center.x - size.width / zoom / 2,
                y: center.y - size.height / zoom / 2)
    }
    func screenPoint(ofWorld p: CGPoint, in size: CGSize) -> CGPoint {
        let o = origin(in: size)
        return CGPoint(x: (p.x - o.x) * zoom, y: (p.y - o.y) * zoom)
    }
    func worldPoint(ofScreen p: CGPoint, in size: CGSize) -> CGPoint {
        let o = origin(in: size)
        return CGPoint(x: o.x + p.x / zoom, y: o.y + p.y / zoom)
    }
    func visibleCellRect(in size: CGSize) -> CGRect {
        let o = origin(in: size)
        return CGRect(x: o.x, y: o.y, width: size.width / zoom, height: size.height / zoom)
    }

    /// 월드 뷰 — 전체 월드가 뷰포트에 들어가도록 fit(두 대륙 다 보임), 중앙 정렬.
    static func worldView(in size: CGSize) -> MapCamera {
        let zoom = min(size.width / CGFloat(WorldMap.cols),
                       size.height / CGFloat(WorldMap.rows))
        return MapCamera(center: CGPoint(x: CGFloat(WorldMap.cols) / 2,
                                         y: CGFloat(WorldMap.rows) / 2),
                         zoom: zoom)
    }

    /// 지역 뷰 — 월드 뷰의 3×, 영토 중심을 향해 팬. 월드 밖이 보이지 않도록 클램프.
    static func regionView(_ region: BadgeRegion, in size: CGSize) -> MapCamera {
        let zoom = worldView(in: size).zoom * 3.0
        var c = WorldMap.territoryCenter[region] ?? .zero
        let visW = size.width / zoom
        let visH = size.height / zoom
        c.x = min(max(c.x, visW / 2), CGFloat(WorldMap.cols) - visW / 2)
        c.y = min(max(c.y, visH / 2), CGFloat(WorldMap.rows) - visH / 2)
        return MapCamera(center: c, zoom: zoom)
    }
}

/// 카메라 전환 tween — TimelineView 프레임마다 보간(무상태, WalkingCat 패턴).
/// waypoints 2개 = 직선(+선택 arc dip), 3개+ = 도로 폴리라인 따라 이동(followRoute).
struct CameraTween {
    var waypoints: [MapCamera]
    var start: Date
    var duration: TimeInterval = 0.28
    /// 2점 직선일 때 중간 줌아웃 dip.
    var arc: Bool = false
    /// 3점+ 폴리라인을 arc-length 등속으로 따라간다(도로 따라 팬).
    var followRoute: Bool = false

    /// 2점 편의 이니셜라이저 (기존 호출 호환).
    init(from: MapCamera, to: MapCamera, start: Date,
         duration: TimeInterval = 0.28, arc: Bool = false) {
        self.waypoints = [from, to]; self.start = start; self.duration = duration; self.arc = arc
    }
    init(waypoints: [MapCamera], start: Date,
         duration: TimeInterval = 0.28, followRoute: Bool = false) {
        self.waypoints = waypoints; self.start = start; self.duration = duration; self.followRoute = followRoute
    }

    func value(at now: Date) -> MapCamera {
        let raw = min(max(now.timeIntervalSince(start) / duration, 0), 1)
        guard let first = waypoints.first else { return MapCamera(center: .zero, zoom: 1) }
        guard waypoints.count > 1 else { return first }
        let e = CGFloat(raw * raw * (3 - 2 * raw))

        // 도로 따라 — 마을 center 폴리라인을 arc-length로 등속 통과.
        if followRoute && waypoints.count > 2 {
            let centers = waypoints.map { $0.center }
            var segLens: [CGFloat] = []
            for i in 0..<centers.count - 1 {
                segLens.append(hypot(centers[i + 1].x - centers[i].x, centers[i + 1].y - centers[i].y))
            }
            let total = max(segLens.reduce(0, +), 0.0001)
            let target = e * total
            var acc: CGFloat = 0
            for i in 0..<segLens.count {
                if acc + segLens[i] >= target || i == segLens.count - 1 {
                    let lt = segLens[i] > 0 ? min(1, (target - acc) / segLens[i]) : 0
                    let c = CGPoint(x: centers[i].x + (centers[i + 1].x - centers[i].x) * lt,
                                    y: centers[i].y + (centers[i + 1].y - centers[i].y) * lt)
                    let z = waypoints[i].zoom + (waypoints[i + 1].zoom - waypoints[i].zoom) * lt
                    return MapCamera(center: c, zoom: z)
                }
                acc += segLens[i]
            }
            return waypoints[waypoints.count - 1]
        }

        // 2점 직선 (+선택 arc dip).
        let a = waypoints[0], b = waypoints[waypoints.count - 1]
        let center = CGPoint(x: a.center.x + (b.center.x - a.center.x) * e,
                             y: a.center.y + (b.center.y - a.center.y) * e)
        var zoom = a.zoom + (b.zoom - a.zoom) * e
        if arc {
            let panDist = hypot(b.center.x - a.center.x, b.center.y - a.center.y)
            let dip = min(0.55, max(0.36, panDist / 45))
            zoom *= 1 - dip * CGFloat(sin(Double.pi * raw))
        }
        return MapCamera(center: center, zoom: zoom)
    }

    func finished(at now: Date) -> Bool {
        now.timeIntervalSince(start) >= duration
    }
}
