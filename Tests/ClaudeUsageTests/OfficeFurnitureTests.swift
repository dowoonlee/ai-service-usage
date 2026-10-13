import XCTest
@testable import ClaudeUsage

final class OfficeFurnitureTests: XCTestCase {
    func testLegacyInitialStateAndExplicitEmptyRoomAreDistinct() {
        XCTAssertEqual(OfficeLayout.sanitizedPlacements(nil), OfficeLayout.defaultPlacements)
        XCTAssertEqual(OfficeLayout.sanitizedPlacements(""), OfficeLayout.defaultPlacements)
        let removedAll = OfficeLayout.serializePlacements([])
        XCTAssertFalse(removedAll.isEmpty)
        XCTAssertEqual(OfficeLayout.sanitizedPlacements(removedAll), [])
        XCTAssertEqual(OfficeLayout.sanitizedPlacements("malformed"), OfficeLayout.defaultPlacements)
    }

    func testSixtyFurnitureSurviveSaveAndReloadIncludingUnicodeFrames() {
        let placements = (0..<60).map { index in
            OfficeLayout.FurniturePlacement(uid: index, kind: 9,
                x: CGFloat(20 + index % 10 * 25), lane: 3,
                text: "가나다라마바사아자차", wallY: 30)
        }
        let serialized = OfficeLayout.serializePlacements(placements)
        XCTAssertGreaterThan(serialized.count, 1500, "기존 서버 길이 제한을 넘는 배치도 보존해야 한다")
        XCTAssertEqual(OfficeLayout.sanitizedPlacements(serialized), placements)
        XCTAssertEqual(OfficeLayout.furnitureMaxInstances, 60)
    }

    func testDeletingMiddleFurniturePreservesRemainingKindsPositionsAndText() {
        let stored = "9:40.0:3:30.0:first;0:35.0:0;9:180.0:3:42.0:last"
        var room = OfficeLayout.sanitizedPlacements(stored)
        room.remove(at: 1)
        let reloaded = OfficeLayout.sanitizedPlacements(OfficeLayout.serializePlacements(room))
        XCTAssertEqual(reloaded.map(\.uid), [0, 1])
        XCTAssertEqual(reloaded.map(\.text), ["first", "last"])
        XCTAssertEqual(reloaded.map(\.x), [40, 180])
        XCTAssertEqual(reloaded.map(\.wallY), [30, 42])
    }

    func testLegacyWallAndFloorCoordinatesRemainReadable() {
        let room = OfficeLayout.sanitizedPlacements("0:35:0;9:100:3:hello;8:220:3:40")
        XCTAssertEqual(room.count, 3)
        XCTAssertEqual(room[1].text, "hello")
        XCTAssertEqual(room[2].wallY, 40)
        XCTAssertEqual(OfficeLayout.sanitizedPlacements(OfficeLayout.serializePlacements(room)).map(\.kind), [0, 9, 8])
    }
    func testFurnitureSavePayloadIncludesVersionAndExpectedLayout() throws {
        let state = OfficeStudioState(legacyLayout: "empty:v2")
        let payload = RankingAPI.GuildManagePayload(
            action: "set_furniture", deviceId: "dev-1", targetDeviceId: "",
            layout: nil, layoutVersion: 3, expectedLayout: "0:35.0:0",
            studio: try state.encoded(), expectedRevision: 4, furnitureOperation: "arrange",
            targetNickname: nil, inviteId: nil, requestId: nil, newName: nil,
            logo: nil, logoX: nil, logoY: nil, ts: 42)
        let data = try JSONEncoder().encode(payload)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["layoutVersion"] as? Int, 3)
        XCTAssertEqual(json["expectedRevision"] as? Int, 4)
        XCTAssertEqual(json["expectedLayout"] as? String, "0:35.0:0")
        XCTAssertEqual(json["studio"] as? String, try state.encoded())
        XCTAssertEqual(json["furnitureOperation"] as? String, "arrange")
        XCTAssertNil(json["purchaseKind"])
        XCTAssertNil(json["layout"])
    }

    func testSixtyFurnitureCollisionGridPerformance() {
        let placements = (0..<60).map { index in
            OfficeLayout.FurniturePlacement(uid: index, kind: index % 8,
                x: CGFloat(20 + index % 10 * 25), lane: index % 3, text: nil)
        }
        measure {
            let grid = OfficePathGrid(blockedRects: OfficeLayout.collisionRects(placements: placements, decor: []))
            XCTAssertGreaterThan(grid.cols * grid.rows, 0)
        }
    }

}
