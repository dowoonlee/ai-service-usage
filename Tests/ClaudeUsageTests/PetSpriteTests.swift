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
            (.archer, .special1, 8),    // Archer_Shoot   (87px ×8)
            (.pawn, .special1, 3),      // Pawn_Hammer    (84px ×3)
            (.pawn, .special2, 6),      // Pawn_Pickaxe   (101px ×6)
        ]
        for (kind, action, count) in expected {
            XCTAssertEqual(PetSprite.frames(for: kind, action: action).count, count,
                           "\(kind.rawValue) \(action.rawValue) frame count")
        }
    }

    // Mythic 종만 MythicSpec을 갖고 나머지는 없어야 한다
    // (chooseNextAction의 special 분기가 일반 펫에서 절대 발동하지 않음을 보장).
    func testOnlyMythicHasSpec() {
        let mythic: Set<PetKind> = [.warrior, .lancer, .monk, .archer, .pawn]
        for kind in PetKind.allCases {
            if mythic.contains(kind) {
                XCTAssertNotNil(Mythic.spec(for: kind), "\(kind.rawValue) should have a MythicSpec")
            } else {
                XCTAssertNil(Mythic.spec(for: kind), "\(kind.rawValue) must not have a MythicSpec")
            }
        }
    }

    // mythic 종은 호버 도발·고부하 스트레스 대사 풀을 갖춰야 한다 (빈 풀이면 폴백되지만 의도상 채움).
    func testMythicHasTauntsAndStress() {
        for kind in [PetKind.warrior, .lancer, .monk, .archer, .pawn] {
            XCTAssertFalse(Mythic.spec(for: kind)?.taunts.isEmpty ?? true, "\(kind.rawValue) taunts")
            XCTAssertFalse(Mythic.spec(for: kind)?.stressQuotes.isEmpty ?? true, "\(kind.rawValue) stressQuotes")
        }
    }

    // 모든 PetKind는 종 전용 말풍선 대사(Quotes.perPet)를 갖춰야 한다.
    // 누락 시 random(for:)이 "..."로 폴백해 사실상 무음이 되므로, 펫 대량 추가 때
    // Quotes 항목 빠뜨리는 실수를 CI에서 즉시 잡는다.
    func testEveryKindHasQuotes() {
        for kind in PetKind.allCases {
            let pool = Quotes.perPet[kind]
            XCTAssertNotNil(pool, "\(kind.rawValue) missing from Quotes.perPet")
            XCTAssertFalse(pool?.isEmpty ?? true, "\(kind.rawValue) has empty quote pool")
        }
    }

    // 모든 PetKind는 도감 캐릭터 설명(PetDescriptions.perPet)도 갖춰야 한다 (동일 취지의 폴백 방지).
    func testEveryKindHasDescription() {
        for kind in PetKind.allCases {
            let desc = PetDescriptions.perPet[kind]
            XCTAssertNotNil(desc, "\(kind.rawValue) missing from PetDescriptions.perPet")
            XCTAssertFalse(desc?.isEmpty ?? true, "\(kind.rawValue) has empty description")
        }
    }

    // 스프라이트 strip에 **완전히 투명한 프레임**이 있으면 그 구간 동안 펫이 화면에서 사라진다.
    // 시트 결함 대부분은 자동 판정하면 오탐투성이지만(그래서 프리뷰로 눈으로 본다), "프레임이
    // 통째로 비었다"만은 예외 없이 결함이다 — 애니메이션 도중 사라지는 걸 의도할 리가 없다.
    //
    // 원인은 보통 strip 파일이 cellSize 기준 프레임 수보다 넓게 저장된 경우다. 렌더러는 폭을
    // cellSize로 나눠 프레임 수를 정하므로, 남는 빈 칸까지 애니메이션 프레임으로 세어버린다.
    func testNoBlankFramesInAnySprite() {
        var offenders: [String] = []
        for kind in PetKind.allCases {
            var actions: [PetController.Action] = [.sit, .walk, .run]
            if Mythic.spec(for: kind) != nil { actions += [.special1, .special2] }
            for action in actions {
                let frames = PetSprite.frames(for: kind, action: action)
                for (i, frame) in frames.enumerated() where Self.isFullyTransparent(frame) {
                    offenders.append("\(kind.rawValue).\(action.rawValue)[\(i)/\(frames.count)]")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "빈 프레임 — 재생 중 펫이 사라진다: \(offenders.joined(separator: ", "))")
    }

    /// alpha가 전부 0인지. 한 픽셀이라도 불투명하면 false.
    private static func isFullyTransparent(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.004 { return false }
            }
        }
        return true
    }
}
