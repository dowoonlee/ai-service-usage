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

    /// 실제 호출부 좌표 — (이름, 캔버스, center.x, footY, petHeight, flagScale, flagHeadroom).
    /// 값은 각 호출부에서 그대로 옮겨온 것이라, 호출부가 바뀌면 여기도 같이 바뀌어야 한다.
    /// 차트만 headroom이 있다 — 펫이 라인을 오르내리는 유일한 호출부라, 캔버스를 위로 늘려 깃발을
    /// 펫에 붙여 둔다(`WalkingCat.effectLayer`). 나머지는 셀 안에 가둬야 해서 0.
    private static let flagCallSites: [FlagCallSite] = [
        FlagCallSite("상점 미리보기 셀", CGSize(width: 110, height: 110), 55, 95, 70, 1.0, 0),
        FlagCallSite("트레이너 카드 셀", CGSize(width: 110, height: 110), 55, 84, 54, 0.78, 0),
        FlagCallSite("랭킹 시상대 1위", CGSize(width: 46, height: 46), 23, 46 * 0.92, 46 * 0.62, 1.0, 0),
        FlagCallSite("랭킹 시상대 2·3위", CGSize(width: 34, height: 34), 17, 34 * 0.92, 34 * 0.62, 1.0, 0),
        FlagCallSite("차트 sparkline", CGSize(width: 300, height: 44), 150, 30, 18, 1.0,
                     PetEffectOverlay.flagReach(petHeight: 18)),
        FlagCallSite("길드 사무실", CGSize(width: 560, height: 400), 280, 300, 26, 1.0, 0),
    ]

    private struct FlagCallSite {
        let name: String
        let canvas: CGSize
        let centerX: CGFloat
        let footY: CGFloat
        let petHeight: CGFloat
        let scale: CGFloat
        let headroom: CGFloat

        init(_ name: String, _ canvas: CGSize, _ centerX: CGFloat, _ footY: CGFloat,
             _ petHeight: CGFloat, _ scale: CGFloat, _ headroom: CGFloat) {
            self.name = name; self.canvas = canvas; self.centerX = centerX; self.footY = footY
            self.petHeight = petHeight; self.scale = scale; self.headroom = headroom
        }

        /// headroom만큼 위로 늘어난 캔버스 — `flagGeometry`가 실제로 받는 bounds다.
        var bounds: CGRect {
            CGRect(x: 0, y: -headroom, width: canvas.width, height: canvas.height + headroom)
        }
    }

    /// 깃발은 이펙트 중 유일하게 펫 밖으로 크게 뻗는데(발끝 위로 1.5×펫높이, 옆으로 1.24×펫높이)
    /// 그리는 곳이 `Canvas`라 **bounds 밖은 잘려 나간다**. 좁은 호출부에서 조용히 반쪽이 되거나
    /// 통째로 사라졌던 회귀를 고정한다 — 차트에서는 펫이 라인 위쪽에 있으면 아예 안 보였고,
    /// 상점 미리보기 셀에서는 천의 절반 이상이 셀 밖이었다.
    func testFlagStaysInsideCanvas() {
        for site in Self.flagCallSites {
            let bounds = site.bounds
            // 펫이 라인을 따라 오르내리는 호출부(headroom > 0)는 캔버스 위/아래 어디서든 성립해야 한다.
            // 발 위치가 고정된 호출부는 실제 값에서만 본다 — 거기서 벗어난 높이에서는 깃대 하한이
            // "위가 잘리는 쪽"을 택하므로(`testFlagPoleShorteningStopsAboveBelly`) 캔버스 안이 아니어도 맞다.
            let footYs: [CGFloat] = site.headroom > 0
                ? [0.05, 0.3, 0.6, 0.95].map { site.canvas.height * $0 }
                : [site.footY]
            for footY in footYs {
                // 좌우 끝단도 — 펫은 plot 가장자리까지 걸어간다.
                for xRatio in [0.02, 0.5, 0.98] {
                    for facingRight in [true, false] {
                        let g = PetEffectOverlay.flagGeometry(
                            center: CGPoint(x: site.canvas.width * xRatio, y: 0),
                            footY: footY,
                            petHeight: site.petHeight,
                            facingRight: facingRight, scale: site.scale, in: bounds)
                        let label = "\(site.name) foot=\(footY) x=\(xRatio) right=\(facingRight)"
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

    /// 차트 — 깃발은 펫이 라인 위 어디에 있든 **자연 기하 그대로** 펫에 붙어 있어야 한다. 캔버스를 위로
    /// 늘리지 않고 세로 클램프에 맡겼더니 깃발이 캔버스 꼭대기에 못 박혀, 펫이 오르내려도 깃발은
    /// 제자리였고 천은 발밑에 걸렸다(v0.17.36 회귀). 깃대 길이가 펫 위치와 무관해야 "따라다니는" 것이다.
    func testChartFlagFollowsPet() {
        let site = Self.flagCallSites.first { $0.name == "차트 sparkline" }!
        let bounds = site.bounds
        for footY in stride(from: CGFloat(0), through: site.canvas.height, by: 2) {
            for facingRight in [true, false] {
                let g = PetEffectOverlay.flagGeometry(
                    center: CGPoint(x: site.centerX, y: footY - site.petHeight / 2),
                    footY: footY, petHeight: site.petHeight,
                    facingRight: facingRight, scale: site.scale, in: bounds)
                XCTAssertEqual(footY - g.poleTop, site.petHeight * 1.5, accuracy: 0.001,
                               "footY=\(footY): 깃대 길이가 펫 위치에 따라 달라짐 — 깃발이 펫을 안 따라간다")
                XCTAssertTrue(bounds.insetBy(dx: -0.51, dy: -0.51).contains(g.drawnRect),
                              "footY=\(footY): \(g.drawnRect) ⊄ \(bounds)")
            }
        }
    }

    /// 캔버스를 위로 늘릴 수 없는 호출부에서 펫이 꼭대기에 붙으면, 깃대는 하한까지만 짧아지고 그 밑으로는
    /// 위가 잘리는 쪽을 택한다. 천이 펫 배 아래·발밑까지 내려오면 더는 "든 깃발"로 안 읽힌다.
    func testFlagPoleShorteningStopsAboveBelly() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 44)
        let h: CGFloat = 18
        for footY: CGFloat in [2, 6, 10] {
            let g = PetEffectOverlay.flagGeometry(center: CGPoint(x: 150, y: footY - h / 2), footY: footY,
                                                  petHeight: h, facingRight: true, scale: 1, in: bounds)
            let clothBottom = g.clothTop + g.clothH + g.sway
            XCTAssertLessThanOrEqual(clothBottom, footY - h * PetEffectOverlay.flagClothClearance + 0.001,
                                     "footY=\(footY): 천 아랫단(\(clothBottom))이 펫 배 아래로 내려옴")
            XCTAssertLessThan(g.poleTop, bounds.minY,
                              "footY=\(footY): 하한에 걸렸으면 캔버스 위로 잘리는 게 정상 — 더 줄이면 안 된다")
        }
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
