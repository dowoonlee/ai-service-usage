import XCTest
@testable import ClaudeUsage

/// WorldMap 지오메트리 + MapCamera — v11 손디자인 맵(WorldMapData) 기반.
final class WorldMapTests: XCTestCase {

    private let viewport = CGSize(width: 528, height: 220)

    // 마을 수 = region 수(9), 모두 land 위 + 자기 영토.
    func testTownsSitOnTheirOwnLand() {
        XCTAssertEqual(WorldMap.towns.count, BadgeRegion.allCases.count)
        for (region, town) in WorldMap.towns {
            XCTAssertGreaterThan(WorldMap.code(col: town.col, row: town.row), 0,
                                 "\(region.rawValue) 마을이 sea 위")
            XCTAssertEqual(WorldMap.regionForCell(col: town.col, row: town.row), region,
                           "\(region.rawValue) 마을이 자기 영토 밖")
        }
    }

    // 모든 region이 비지 않은 영토 + 중심을 가진다.
    func testEveryRegionHasTerritory() {
        for region in BadgeRegion.allCases {
            let count = WorldMap.regionForCellMap.values.filter { $0 == region }.count
            XCTAssertGreaterThan(count, 0, "\(region.rawValue) 영토 없음")
            XCTAssertNotNil(WorldMap.territoryCenter[region])
        }
    }

    // grid 차원 = WorldMapData와 일치.
    func testGridDimensions() {
        XCTAssertEqual(WorldMap.grid.count, WorldMap.rows)
        XCTAssertEqual(WorldMap.grid.first?.count, WorldMap.cols)
        XCTAssertEqual(WorldMap.rows, WorldMapData.rows)
        XCTAssertEqual(WorldMap.cols, WorldMapData.cols)
    }

    // 대륙 분할 — 본토 5(서쪽), 제2 대륙 4(동쪽).
    func testContinentPartition() {
        XCTAssertEqual(GymContinent.mainland.regions.count, 5)
        XCTAssertEqual(GymContinent.cloud.regions.count, 4)
        for r in GymContinent.mainland.regions {
            if let t = WorldMap.towns[r] {
                XCTAssertLessThan(t.col, WorldMap.continentSplitCol, "\(r.rawValue) 본토인데 동쪽")
            }
        }
        for r in GymContinent.cloud.regions {
            if let t = WorldMap.towns[r] {
                XCTAssertGreaterThanOrEqual(t.col, WorldMap.continentSplitCol, "\(r.rawValue) 제도인데 서쪽")
            }
        }
    }

    // 제2 대륙 마을은 신규 바이옴(dune/snow/lava/rock = 5~8) 위.
    func testCloudBiomeTowns() {
        for region in GymContinent.cloud.regions {
            guard let t = WorldMap.towns[region] else { XCTFail("\(region.rawValue) 없음"); continue }
            XCTAssertGreaterThanOrEqual(WorldMap.code(col: t.col, row: t.row), 5,
                                        "\(region.rawValue) 마을이 신규 바이옴 아님")
        }
    }

    // 데코는 모두 유효 셀 범위 안.
    func testDecosInBounds() {
        for d in WorldMapData.decos {
            XCTAssertTrue(d.col >= 0 && d.col < WorldMap.cols && d.row >= 0 && d.row < WorldMap.rows,
                          "데코 (\(d.col),\(d.row)) 범위 밖")
        }
    }

    // 카메라 좌표 왕복 — world → screen → world 항등.
    func testCameraRoundtrip() {
        let cam = MapCamera(center: CGPoint(x: 35, y: 19), zoom: 12)
        let w = CGPoint(x: 5.25, y: 12.5)
        let back = cam.worldPoint(ofScreen: cam.screenPoint(ofWorld: w, in: viewport), in: viewport)
        XCTAssertEqual(back.x, w.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, w.y, accuracy: 1e-9)
    }

    // 월드 뷰 — 전체 월드가 뷰포트에 들어간다(두 대륙 다 보임).
    func testWorldViewFitsWholeWorld() {
        let cam = MapCamera.worldView(in: viewport)
        let vis = cam.visibleCellRect(in: viewport)
        XCTAssertLessThanOrEqual(vis.minX, 0.01)
        XCTAssertLessThanOrEqual(vis.minY, 0.01)
        XCTAssertGreaterThanOrEqual(vis.maxX, CGFloat(WorldMap.cols) - 0.01)
        XCTAssertGreaterThanOrEqual(vis.maxY, CGFloat(WorldMap.rows) - 0.01)
    }

    // 지역 뷰 — 월드 밖으로 나가지 않게 클램프 + 확실히 줌인.
    func testRegionViewClamped() {
        let worldZoom = MapCamera.worldView(in: viewport).zoom
        for region in BadgeRegion.allCases {
            let cam = MapCamera.regionView(region, in: viewport)
            let vis = cam.visibleCellRect(in: viewport)
            XCTAssertGreaterThanOrEqual(vis.minX, -0.01, "\(region.rawValue) 서쪽 이탈")
            XCTAssertGreaterThanOrEqual(vis.minY, -0.01, "\(region.rawValue) 북쪽 이탈")
            XCTAssertLessThanOrEqual(vis.maxX, CGFloat(WorldMap.cols) + 0.01, "\(region.rawValue) 동쪽 이탈")
            XCTAssertLessThanOrEqual(vis.maxY, CGFloat(WorldMap.rows) + 0.01, "\(region.rawValue) 남쪽 이탈")
            XCTAssertGreaterThan(cam.zoom, worldZoom * 2)
        }
    }

    // tween 경계값 — 시작=from, 종료=to.
    func testTweenEndpoints() {
        let a = MapCamera(center: .zero, zoom: 6)
        let b = MapCamera(center: CGPoint(x: 30, y: 15), zoom: 18)
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let tw = CameraTween(from: a, to: b, start: t0)
        XCTAssertEqual(tw.value(at: t0), a)
        // duration 경계는 부동소수점 오차가 있으므로 여유를 둔다(value는 clamp되어 b, finished는 true).
        let end = t0.addingTimeInterval(tw.duration + 0.01)
        XCTAssertEqual(tw.value(at: end), b)
        XCTAssertTrue(tw.finished(at: end))
        let mid = tw.value(at: t0.addingTimeInterval(tw.duration * 0.5))
        XCTAssertGreaterThan(mid.zoom, a.zoom)
        XCTAssertLessThan(mid.zoom, b.zoom)
    }

    // MARK: - 이벤트 섬 (시즌 보스 진입점)

    /// 섬은 mapgen 지형 밖 하늘 띠(row < 0)에만 있어야 한다 — 지상 셀과 겹치면 영토 lookup과 충돌한다.
    func testEventIslandLivesInSkyBandOnly() {
        let island = EventIsland.winter
        var cells = 0
        for r in 0..<island.rows {
            for c in 0..<island.cols {
                let col = island.originCol + c, row = island.originRow + r
                guard island.contains(col: col, row: row) else { continue }
                cells += 1
                XCTAssertLessThan(row, 0)
                XCTAssertGreaterThanOrEqual(row, -EventIsland.skyRows)
                XCTAssertTrue(col >= 0 && col < WorldMap.cols)
                XCTAssertNotNil(WorldMap.tileImageNames[island.code(col: col, row: row)])
            }
        }
        XCTAssertGreaterThan(cells, 60, "지역 하나로 읽힐 만큼은 커야 한다")
        XCTAssertFalse(island.contains(col: island.originCol - 1, row: island.originRow))
        XCTAssertFalse(island.contains(col: 20, row: 20))                      // 지상
        XCTAssertNil(WorldMap.regionForCell(col: island.town.col, row: island.town.row))
        XCTAssertTrue(island.contains(col: island.town.col, row: island.town.row))
        for d in island.decos {
            XCTAssertTrue(island.contains(col: d.col, row: d.row), "\(d.image) (\(d.col),\(d.row))가 섬 밖")
            XCTAssertNotNil(NSImage.mapTile(named: d.image), "\(d.image) 리소스 없음")
        }
        XCTAssertNotNil(NSImage.mapTile(named: island.building))
    }

    /// 흰 스킨 보스가 걷는 도장 앞 줄은 눈(6)이 아니어야 보인다.
    func testEventIslandBossWalksOnPlazaNotSnow() {
        let island = EventIsland.winter
        let walkRow = Int(floor(Double(island.town.row) + 1.45))
        for col in (island.town.col - 1)...(island.town.col + 2) {
            let code = island.code(col: col, row: walkRow)
            XCTAssertTrue(code > 0 && code != 6, "(\(col),\(walkRow)) code=\(code)")
        }
    }

    /// 밑동 바위는 하늘 띠 안에서 끝나거나 지상 land와 겹치지 않아야 한다.
    func testEventIslandUndersideDoesNotCoverLand() {
        let island = EventIsland.winter
        for c in island.originCol..<(island.originCol + island.cols) {
            guard let bottom = island.bottomRow(col: c) else { continue }
            let depth = island.undersideDepth(col: c)
            XCTAssertTrue((1...4).contains(depth))
            for d in 1...depth {
                XCTAssertEqual(WorldMap.code(col: c, row: bottom + d), 0, "밑동이 (\(c),\(bottom + d)) 지상을 덮음")
            }
        }
    }

    /// 섬이 있을 때 맵을 키우는 이유: 지상 지역이 평소보다 작아지면 안 된다. 그리고 월드 뷰에 섬 전체가 들어온다.
    func testSkyBandKeepsGroundScaleAndShowsWholeIsland() {
        let width: CGFloat = 528
        let base = MapCamera.worldView(in: CGSize(width: width, height: GymView.mapHeight(hasIsland: false)))
        let size = CGSize(width: width, height: GymView.mapHeight(hasIsland: true))
        let cam = MapCamera.worldView(in: size, skyRows: EventIsland.skyRows)
        XCTAssertGreaterThanOrEqual(cam.zoom, base.zoom - 0.05)
        let vis = cam.visibleCellRect(in: size)
        let island = EventIsland.winter
        XCTAssertLessThanOrEqual(vis.minY, CGFloat(island.originRow))
        XCTAssertLessThanOrEqual(vis.minX, CGFloat(island.originCol))
        XCTAssertGreaterThanOrEqual(vis.maxX, CGFloat(island.originCol + island.cols))
        XCTAssertGreaterThanOrEqual(vis.maxY, CGFloat(WorldMap.rows) - 0.01)
        // 평소(섬 없음)엔 기본값 그대로 — 기존 카메라 계약이 안 바뀐다.
        XCTAssertEqual(GymView.mapHeight(hasIsland: false), 220)
        XCTAssertEqual(MapCamera.worldView(in: size), MapCamera.worldView(in: size, skyRows: 0))
    }

    func testIslandViewCentersIslandWithinExtendedWorld() {
        let size = CGSize(width: 528, height: GymView.mapHeight(hasIsland: true))
        let island = EventIsland.winter
        let cam = MapCamera.islandView(island, in: size)
        XCTAssertEqual(cam.zoom, MapCamera.worldView(in: size, skyRows: EventIsland.skyRows).zoom * 3, accuracy: 0.001)
        let vis = cam.visibleCellRect(in: size)
        XCTAssertGreaterThanOrEqual(vis.minY, -CGFloat(EventIsland.skyRows) - 0.01)
        XCTAssertTrue(vis.contains(CGPoint(x: CGFloat(island.town.col) + 0.5, y: CGFloat(island.town.row) + 0.5)))
        // 지상 지역 뷰는 하늘 띠가 있어도 월드 밖으로 나가지 않는다.
        for region in BadgeRegion.allCases {
            let v = MapCamera.regionView(region, in: size, skyRows: EventIsland.skyRows).visibleCellRect(in: size)
            XCTAssertGreaterThanOrEqual(v.minY, -CGFloat(EventIsland.skyRows) - 0.01)
            XCTAssertLessThanOrEqual(v.maxY, CGFloat(WorldMap.rows) + 0.01)
        }
    }
}
