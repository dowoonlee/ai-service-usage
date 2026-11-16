import XCTest
import SwiftUI
@testable import ClaudeUsage

@MainActor
final class OfficeDecorMovementTests: SandboxedTestCase {
    func testOldResponseKeepsItsSlotPositionAndDonor() throws {
        let json = Data(#"{"slotId":5,"itemKind":"CHRISTMAS_TREE","donorNickname":"donor"}"#.utf8)
        let item = try JSONDecoder().decode(RankingAPI.GuildFurnitureItem.self, from: json)
        XCTAssertNil(item.positionVersion)
        XCTAssertEqual(item.placement.resolvedPosition, CGPoint(x: 80, y: 112))
        XCTAssertEqual(item.donorNickname, "donor")
    }

    func testSavedResponseOverridesSlotCoordinates() throws {
        let json = Data(#"{"slotId":5,"itemKind":"CHRISTMAS_TREE","donorNickname":"donor","x":200,"y":140,"positionVersion":"test"}"#.utf8)
        let item = try JSONDecoder().decode(RankingAPI.GuildFurnitureItem.self, from: json)
        XCTAssertEqual(item.placement.resolvedPosition, CGPoint(x: 200, y: 140))
        XCTAssertEqual(item.positionVersion, "test")
        XCTAssertEqual(item.slotId, 5, "이동해도 기부 슬롯은 유지한다")
    }

    func testSeasonDecorClampsToItsMountAndStaysInsideRoom() {
        for item in OfficeLayout.decorCatalog.filter({ $0.season != nil }) {
            let a = OfficeLayout.clampDecorPosition(kind: item.kind, position: CGPoint(x: -100, y: -100))
            let b = OfficeLayout.clampDecorPosition(kind: item.kind, position: CGPoint(x: 999, y: 999))
            XCTAssertEqual(a.x, item.size.width / 2, item.kind)
            XCTAssertEqual(b.x, 280 - item.size.width / 2, item.kind)
            XCTAssertEqual(a.y, item.category == .wall ? item.size.height : 84, item.kind)
            XCTAssertEqual(b.y, item.category == .wall ? 60 : 140, item.kind)
        }
        XCTAssertEqual(OfficeLayout.clampDecorPosition(kind: "SNOWMAN", position: CGPoint(x: 150, y: 107)), CGPoint(x: 150, y: 112))
    }

    func testCollisionGridFollowsMovedDecoration() {
        let original = OfficeLayout.DecorPlacement(slotId: 5, kind: "CHRISTMAS_TREE")
        let moved = OfficeLayout.DecorPlacement(slotId: 5, kind: "CHRISTMAS_TREE", position: CGPoint(x: 200, y: 140))
        let before = OfficeLayout.collisionRects(placements: [], decor: [original])
        let after = OfficeLayout.collisionRects(placements: [], decor: [moved])
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].minX - before[0].minX, 120)
        XCTAssertEqual(after[0].minY - before[0].minY, 28)
        XCTAssertNotEqual(original.signature, moved.signature)
        XCTAssertTrue(OfficeLayout.collisionRects(placements: [], decor: [.init(slotId: 0, kind: "XMAS_LIGHTS")]).isEmpty)
    }

    func testDecorOverlapRespectsLanesAndWallHeight() {
        let tree = OfficeLayout.DecorPlacement(slotId: 5, kind: "CHRISTMAS_TREE", position: CGPoint(x: 100, y: 112))
        XCTAssertFalse(OfficeLayout.decorPlacementCollides(tree, furniture: [], decor: [tree]))
        XCTAssertTrue(OfficeLayout.decorPlacementCollides(tree, furniture: [], decor: [
            .init(slotId: 6, kind: "SNOWMAN", position: CGPoint(x: 108, y: 112))]))
        XCTAssertFalse(OfficeLayout.decorPlacementCollides(tree, furniture: [], decor: [
            .init(slotId: 6, kind: "SNOWMAN", position: CGPoint(x: 100, y: 140))]))
        XCTAssertTrue(OfficeLayout.decorPlacementCollides(tree, furniture: [
            .init(uid: 0, kind: 0, x: 100, lane: 1)], decor: []))
        let wall = OfficeLayout.DecorPlacement(slotId: 0, kind: "XMAS_LIGHTS", position: CGPoint(x: 100, y: 52))
        XCTAssertTrue(OfficeLayout.decorPlacementCollides(wall, furniture: [], decor: [
            .init(slotId: 1, kind: "XMAS_BANNER", position: CGPoint(x: 100, y: 52))]))
        XCTAssertFalse(OfficeLayout.decorPlacementCollides(wall, furniture: [], decor: [tree]))
    }
}

@MainActor
final class OfficeDecorMovementPreviews: SandboxedTestCase {
    func testMovedSeasonDecor() throws {
        _ = try PreviewRenderer.requireOutputDir()
        var info = PreviewDemoState.guildInfo()
        info.furniture = [
            .init(slotId: 5, itemKind: "CHRISTMAS_TREE", donorNickname: "donor", x: 110, y: 140, positionVersion: "test"),
            .init(slotId: 6, itemKind: "SNOWMAN", donorNickname: "donor", x: 180, y: 140, positionVersion: "test"),
            .init(slotId: 7, itemKind: "GIFT_BOXES", donorNickname: "donor", x: 230, y: 112, positionVersion: "test"),
            .init(slotId: 0, itemKind: "XMAS_LIGHTS", donorNickname: "donor", x: 60, y: 40, positionVersion: "test"),
            .init(slotId: 1, itemKind: "XMAS_BANNER", donorNickname: "donor", x: 155, y: 40, positionVersion: "test"),
            .init(slotId: 2, itemKind: "XMAS_WREATH", donorNickname: "donor", x: 240, y: 52, positionVersion: "test"),
        ]
        for editing in [false, true] {
            let view = GuildOfficeView(info: info, rearrangeMode: .constant(editing),
                previewFloorTheme: .constant(nil), previewWallTheme: .constant(nil),
                onSaveStudio: { _ in }, onSetLogoPos: { _, _ in }, onPlaceDecor: { _, _ in },
                onRemoveDecor: { _ in }, onApplyTheme: {},
                onMoveDecor: { _, p in .init(x: Int(p.x), y: Int(p.y), version: "test") },
                purchaseSheetOpen: .constant(false))
            try PreviewRenderer.renderInWindow(view, size: CGSize(width: 560, height: editing ? 620 : 340),
                section: "시즌 장식 이동", title: editing ? "편집" : "일반")
        }
    }
}
