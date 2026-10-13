import XCTest
@testable import ClaudeUsage

final class OfficeStudioTests: XCTestCase {
    func testLegacyFurnitureIDsTextAndEmptyRoomArePreserved() throws {
        let room = OfficeStudioState(legacyLayout: "0:35:0;9:180:3:40:%EC%95%88%EB%85%95")
        XCTAssertEqual(room.items.map(\.id), ["legacy-0", "legacy-1"])
        XCTAssertEqual(room.items[1].text, "안녕")
        XCTAssertEqual(room.items[1].wallY, 40)
        XCTAssertEqual(OfficeStudioState(legacyLayout: nil).items.count, 5)
        XCTAssertTrue(OfficeStudioState(legacyLayout: "empty:v2").items.isEmpty)
        let decoded = try JSONDecoder().decode(OfficeStudioState.self, from: Data(room.encoded().utf8))
        XCTAssertEqual(decoded, room)
    }

    func testStorageRoundTripKeepsOwnershipAndFrameText() throws {
        var room = OfficeStudioState(legacyLayout: "9:100:3:40:hello")
        let id = room.items[0].id
        try room.store(id)
        XCTAssertEqual(room.placedCount, 0)
        XCTAssertEqual(room.storedCount, 1)
        XCTAssertEqual(OfficeLayout.serializePlacements(room.placements), "empty:v2")
        try room.restore(id)
        XCTAssertEqual(room.placedCount, 1)
        XCTAssertEqual(room.items[0].id, id)
        XCTAssertEqual(room.items[0].text, "hello")
    }

    func testPresetsMoveOwnedFurnitureAndNeverDuplicateDeletedItems() throws {
        var room = OfficeStudioState(legacyLayout: nil)
        try room.savePreset(name: "첫 배치")
        let preset = try XCTUnwrap(room.presets.first)
        let originalPositions = room.currentPositions
        try room.store("legacy-0")
        try room.applyPreset(preset.id)
        XCTAssertEqual(room.currentPositions, originalPositions)
        try room.delete("legacy-0")
        try room.applyPreset(preset.id)
        XCTAssertEqual(room.items.count, 4)
        XCTAssertFalse(room.items.contains { $0.id == "legacy-0" })
        XCTAssertFalse(room.presets[0].positions.contains { $0.itemID == "legacy-0" })
    }

    func testPresetApplicationLeavesFrameTextAndKeepsOtherFurnitureInStorage() throws {
        var room = OfficeStudioState(legacyLayout: "9:100:3:40:first;0:35:0")
        try room.store("legacy-1")
        try room.savePreset(name: "액자만")
        let id = try XCTUnwrap(room.presets.first?.id)
        room.items[0].text = "changed"
        try room.restore("legacy-1")
        try room.applyPreset(id)
        XCTAssertEqual(room.items[0].text, "changed")
        XCTAssertTrue(room.items[1].stored)
        XCTAssertEqual(room.items.count, 2)
    }

    func testStoragePurchaseAndPlacementLimitsAreIndependent() throws {
        var room = OfficeStudioState(legacyLayout: "empty:v2")
        let placement = OfficeLayout.FurniturePlacement(uid: 0, kind: 8, x: 40, lane: 3, text: nil, wallY: 40)
        for _ in 0..<60 { try room.purchase(placement) }
        XCTAssertThrowsError(try room.purchase(placement))
        for _ in 60..<180 { try room.purchase(placement, stored: true) }
        XCTAssertEqual(room.placedCount, 60)
        XCTAssertEqual(room.storedCount, 120)
        XCTAssertThrowsError(try room.purchase(placement, stored: true))
        XCTAssertThrowsError(try room.restore(room.items[60].id))
        for id in room.items.map(\.id) { try room.store(id) }
        XCTAssertEqual(room.storedCount, 180, "배치가 0개여도 모든 보유 가구를 보관할 수 있어야 한다")
    }

    func testWallPlacementUsesUpperSpaceWhenDefaultHeightIsFull() throws {
        let others = (0..<20).map {
            OfficeLayout.FurniturePlacement(uid: $0, kind: 8, x: CGFloat(14 + $0 * 13), lane: 3, text: nil, wallY: 52)
        }
        let position = try XCTUnwrap(OfficeLayout.freePlacement(kind: 8, uid: 20, others: others))
        XCTAssertNotEqual(position.wallY, 52)
        XCTAssertFalse(OfficeLayout.placementCollides(uid: 20, kind: 8, x: position.x, lane: 3,
                                                     wallY: position.wallY, others: others))
    }

    func testHistorySupportsUndoRedoAndClearsAtOwnershipBoundary() {
        let initial = OfficeStudioState(legacyLayout: nil).items
        var moved = initial; moved[0].x += 10
        var history = OfficeStudioHistory()
        history.record(initial)
        XCTAssertEqual(history.undo.last, initial)
        history.didUndo(current: moved)
        XCTAssertTrue(history.undo.isEmpty)
        XCTAssertEqual(history.redo.last, moved)
        history.didRedo(current: initial)
        XCTAssertEqual(history.undo.last, initial)
        XCTAssertTrue(history.redo.isEmpty)
        for _ in 0..<30 { history.record(initial) }
        XCTAssertEqual(history.undo.count, 20)
        history.clear()
        XCTAssertTrue(history.undo.isEmpty && history.redo.isEmpty)
    }

    func testPresetNamesAndCapacity() throws {
        var room = OfficeStudioState(legacyLayout: nil)
        XCTAssertThrowsError(try room.savePreset(name: "   "))
        XCTAssertThrowsError(try room.savePreset(name: String(repeating: "가", count: 21)))
        for index in 0..<5 { try room.savePreset(name: "배치 \(index)") }
        XCTAssertThrowsError(try room.savePreset(name: "여섯 번째"))
        let id = room.presets[0].id
        try room.savePreset(name: "새 이름", replacing: id)
        XCTAssertEqual(room.presets.count, 5)
        XCTAssertEqual(room.presets[0].name, "새 이름")
    }
}
