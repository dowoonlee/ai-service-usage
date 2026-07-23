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
}
