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
    //
    // 검사는 **PNG 파일을 직접 디코딩**해서 한다. `PetSprite.frames`가 돌려주는 NSImage는 strip을
    // 잘라 다시 그린 결과라 색공간·디스플레이 프로파일이 개입하고, 실제로 같은 파일이 로컬에서는
    // 통과하고 CI에서는 걸렸다. 파일 바이트를 보면 환경이 달라도 답이 같다.
    func testNoBlankFramesInAnySprite() {
        var offenders: [String] = []
        var checked = 0
        for kind in PetKind.allCases {
            let def = kind.def
            for suffix in Set([def.walkSuffix, def.runSuffix, def.idleSuffix]).sorted() {
                let name = "\(def.prefix)_\(suffix)"
                guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
                      let data = try? Data(contentsOf: url),
                      let rep = NSBitmapImageRep(data: data) else {
                    offenders.append("\(name): 리소스를 못 읽음")
                    continue
                }
                checked += 1
                let cw = def.cellSize.w
                guard cw > 0, rep.pixelsWide >= cw else {
                    offenders.append("\(name): 폭 \(rep.pixelsWide) < cell \(cw)")
                    continue
                }
                let frames = rep.pixelsWide / cw
                for i in 0..<frames where Self.cellIsBlank(rep, originX: i * cw, width: cw) {
                    offenders.append("\(kind.rawValue)/\(name)[\(i)/\(frames)]")
                }
            }
        }
        XCTAssertGreaterThan(checked, 150, "검사한 strip이 너무 적다 — 리소스 조회가 깨진 것")
        XCTAssertTrue(offenders.isEmpty,
                      "빈 프레임 — 재생 중 펫이 사라진다: \(offenders.joined(separator: ", "))")
    }

    /// strip의 [originX, originX+width) 열이 전부 투명한지. 알파 바이트를 직접 본다.
    private static func cellIsBlank(_ rep: NSBitmapImageRep, originX: Int, width: Int) -> Bool {
        guard rep.hasAlpha, let base = rep.bitmapData else { return false }
        let spp = rep.samplesPerPixel
        let alpha = spp - 1          // 알파는 마지막 샘플(RGBA / GA 공통)
        for y in 0..<rep.pixelsHigh {
            let row = base + y * rep.bytesPerRow
            for x in originX..<min(originX + width, rep.pixelsWide) where row[x * spp + alpha] != 0 {
                return false
            }
        }
        return true
    }
}
