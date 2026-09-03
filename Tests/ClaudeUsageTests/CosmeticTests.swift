import XCTest
@testable import ClaudeUsage

final class CosmeticTests: XCTestCase {
    // 신규 포함 11종이 카테고리에 올바르게 분포하는지 (category switch 누락은 컴파일로도 잡히지만 분포 확인).
    func testEffectCategoryDistribution() {
        XCTAssertEqual(EffectKind.allCases.count, 11)
        let byCat = Dictionary(grouping: EffectKind.allCases, by: { $0.category })
        XCTAssertEqual(byCat[.light]?.count, 2)     // glow, aura
        XCTAssertEqual(byCat[.trail]?.count, 5)     // trail, rainbow, stardust, flame, flag
        XCTAssertEqual(byCat[.particle]?.count, 4)  // footsteps, heart, star, petal
    }

    // 신규 코스메틱이 displayName/iconName/price를 모두 갖춰야 한다(폴백 누락 방지).
    func testNewCosmeticsConfigured() {
        for e in [EffectKind.heart, .star, .petal, .stardust, .flame, .flag] {
            XCTAssertFalse(e.displayName.isEmpty, "\(e.rawValue) displayName")
            XCTAssertFalse(e.iconName.isEmpty, "\(e.rawValue) iconName")
            XCTAssertGreaterThan(e.price, 0, "\(e.rawValue) price")
        }
    }

    // MARK: - 깃발 기하 (PetEffectOverlay.flagGeometry)

    /// 실제 호출부 좌표 — (이름, 캔버스, center.x, footY, petHeight, flagScale).
    /// 값은 각 호출부에서 그대로 옮겨온 것이라, 호출부가 바뀌면 여기도 같이 바뀌어야 한다.
    private static let flagCallSites: [(name: String, canvas: CGSize, centerX: CGFloat,
                                        footY: CGFloat, petHeight: CGFloat, scale: CGFloat)] = [
        ("상점 미리보기 셀", CGSize(width: 110, height: 110), 55, 95, 70, 1.0),
        ("트레이너 카드 셀", CGSize(width: 110, height: 110), 55, 84, 54, 0.78),
        ("랭킹 시상대 1위", CGSize(width: 46, height: 46), 23, 46 * 0.92, 46 * 0.62, 1.0),
        ("랭킹 시상대 2·3위", CGSize(width: 34, height: 34), 17, 34 * 0.92, 34 * 0.62, 1.0),
        ("차트 sparkline", CGSize(width: 300, height: 44), 150, 30, 18, 1.0),
        ("길드 사무실", CGSize(width: 560, height: 400), 280, 300, 26, 1.0),
    ]

    /// 깃발은 이펙트 중 유일하게 펫 밖으로 크게 뻗는데(발끝 위로 1.5×펫높이, 옆으로 1.24×펫높이)
    /// 그리는 곳이 `Canvas`라 **bounds 밖은 잘려 나간다**. 좁은 호출부에서 조용히 반쪽이 되거나
    /// 통째로 사라졌던 회귀를 고정한다 — 차트에서는 펫이 라인 위쪽에 있으면 아예 안 보였고,
    /// 상점 미리보기 셀에서는 천의 절반 이상이 셀 밖이었다.
    func testFlagStaysInsideCanvas() {
        for site in Self.flagCallSites {
            let bounds = CGRect(origin: .zero, size: site.canvas)
            // 펫이 캔버스 위/아래 어디에 있어도 성립해야 한다 (차트 펫은 라인을 따라 오르내린다).
            for footRatio in [0.05, 0.3, 0.6, 0.95] {
                // 좌우 끝단도 — 펫은 plot 가장자리까지 걸어간다.
                for xRatio in [0.02, 0.5, 0.98] {
                    for facingRight in [true, false] {
                        let g = PetEffectOverlay.flagGeometry(
                            center: CGPoint(x: site.canvas.width * xRatio, y: 0),
                            footY: site.canvas.height * footRatio,
                            petHeight: site.petHeight,
                            facingRight: facingRight, scale: site.scale, in: bounds)
                        let label = "\(site.name) foot=\(footRatio) x=\(xRatio) right=\(facingRight)"
                        // 0.5pt 여유 — 컬럼 이음매 메움(+0.5)과 반올림 몫.
                        XCTAssertTrue(bounds.insetBy(dx: -0.51, dy: -0.51).contains(g.drawnRect),
                                      "\(label): \(g.drawnRect) ⊄ \(bounds)")
                        XCTAssertGreaterThan(g.cols, 0, label)
                        XCTAssertGreaterThan(g.clothH, 1, "\(label): 천이 도트로 뭉갤 만큼 작아짐")
                    }
                }
            }
        }
    }

    /// 여유가 있는 캔버스에서는 자연 크기 그대로여야 한다. 맞춤 로직이 "항상 조금씩 줄이는"
    /// 쪽으로 새면 이미 손으로 맞춰둔 화면(트레이너 카드 0.78)의 그림이 조용히 달라진다.
    func testFlagKeepsNaturalGeometryWhenRoomy() {
        let bounds = CGRect(x: 0, y: 0, width: 220, height: 130)
        let g = PetEffectOverlay.flagGeometry(center: CGPoint(x: 130, y: 76), footY: 103,
                                              petHeight: 54, facingRight: true, scale: 1,
                                              in: bounds)
        XCTAssertEqual(g.poleX, 130 - 54 * 0.38, accuracy: 0.001)
        XCTAssertEqual(g.poleTop, 103 - 54 * 1.5, accuracy: 0.001)
        XCTAssertEqual(g.clothW, 54 * 0.86, accuracy: 0.001)
        XCTAssertTrue(g.onLeft, "진행 방향 반대편(등 뒤)에 깃대")
    }

    /// 등 뒤가 좁으면 반대편으로 넘긴다 — 억지로 밀어 넣으면 깃대가 펫을 뚫고 반대편까지 간다.
    func testFlagMirrorsToRoomierSide() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 44)
        // 왼쪽 끝에 붙은 펫이 오른쪽을 보는 중 → 등 뒤(왼쪽)에는 자리가 없다.
        let g = PetEffectOverlay.flagGeometry(center: CGPoint(x: 6, y: 0), footY: 30,
                                              petHeight: 18, facingRight: true, scale: 1,
                                              in: bounds)
        XCTAssertFalse(g.onLeft, "왼쪽 끝에서는 천이 오른쪽으로 걸려야 한다")
        XCTAssertTrue(bounds.insetBy(dx: -0.51, dy: -0.51).contains(g.drawnRect))
    }
}
