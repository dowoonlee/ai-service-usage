import XCTest
@testable import ClaudeUsage

@MainActor
final class PetSpriteTests: XCTestCase {
    // Mythic 특수 모션 strip이 cellSize와 정합해 올바른 frame 수로 로드되는지 검증.
    // (에셋 누락 또는 cellSize 불일치 시 sheet.width/cellW가 틀어져 frame 수로 잡힌다.)
    func testMythicSpecialFramesLoad() {
        let expected: [(PetKind, PetController.Action, Int)] = [
            (.warrior, .special1, 4),   // Warrior_Attack1 (120px ×4)
            (.warrior, .special2, 4),   // Warrior_Attack2 (118px ×4)
            (.lancer, .special1, 3),    // Lancer_Attack  (186px ×3)
            (.monk, .special1, 11),     // Monk_Heal      (121px ×11)
        ]
        for (kind, action, count) in expected {
            XCTAssertEqual(PetSprite.frames(for: kind, action: action).count, count,
                           "\(kind.rawValue) \(action.rawValue) frame count")
        }
    }

    // Mythic 3종만 specialMoves를 갖고 나머지는 비어 있어야 한다
    // (chooseNextAction의 special 분기가 일반 펫에서 절대 발동하지 않음을 보장).
    func testOnlyMythicHasSpecialMoves() {
        let mythic: Set<PetKind> = [.warrior, .lancer, .monk]
        for kind in PetKind.allCases {
            if mythic.contains(kind) {
                XCTAssertFalse(kind.def.specialMoves.isEmpty, "\(kind.rawValue) should have special moves")
            } else {
                XCTAssertTrue(kind.def.specialMoves.isEmpty, "\(kind.rawValue) must have no special moves")
            }
        }
    }
}
