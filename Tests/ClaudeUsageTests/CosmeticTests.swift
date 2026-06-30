import XCTest
@testable import ClaudeUsage

final class CosmeticTests: XCTestCase {
    // 신규 포함 10종이 카테고리에 올바르게 분포하는지 (category switch 누락은 컴파일로도 잡히지만 분포 확인).
    func testEffectCategoryDistribution() {
        XCTAssertEqual(EffectKind.allCases.count, 10)
        let byCat = Dictionary(grouping: EffectKind.allCases, by: { $0.category })
        XCTAssertEqual(byCat[.light]?.count, 2)     // glow, aura
        XCTAssertEqual(byCat[.trail]?.count, 4)     // trail, rainbow, stardust, flame
        XCTAssertEqual(byCat[.particle]?.count, 4)  // footsteps, heart, star, petal
    }

    // 신규 코스메틱이 displayName/iconName/price를 모두 갖춰야 한다(폴백 누락 방지).
    func testNewCosmeticsConfigured() {
        for e in [EffectKind.heart, .star, .petal, .stardust, .flame] {
            XCTAssertFalse(e.displayName.isEmpty, "\(e.rawValue) displayName")
            XCTAssertFalse(e.iconName.isEmpty, "\(e.rawValue) iconName")
            XCTAssertGreaterThan(e.price, 0, "\(e.rawValue) price")
        }
    }
}
