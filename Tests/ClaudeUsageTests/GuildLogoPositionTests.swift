import XCTest
@testable import ClaudeUsage

/// 로고 위치는 클라 클램프 / 서버 검증(guild_policy.ts) / DB CHECK 3중으로 막는다.
/// 한 번 벽 밖으로 새면 화면에서 사라져 사용자가 되돌리기 어려워서다.
@MainActor
final class GuildLogoPositionTests: XCTestCase {
    private func guild(logoX: Int?, logoY: Int?) -> RankingAPI.GuildInfo {
        RankingAPI.GuildInfo(
            id: "g1", name: "테스트길드", inviteCode: "AAAA1111", isLeader: true,
            floorTheme: 0, wallTheme: 0, officeFurniture: nil,
            logo: GuildLogo.encode(sample: 0), logoX: logoX, logoY: logoY,
            createdAt: Date(), score: 0, rank: nil, memberCount: 1)
    }

    private var half: CGSize {
        CGSize(width: GuildOfficeView.logoSceneSize.width / 2,
               height: GuildOfficeView.logoSceneSize.height / 2)
    }

    // 좌표가 없으면(구버전 서버·신규 길드) 기본 자리로.
    func testDefaultPositionWhenUnset() {
        let p = GuildOfficeView.logoPosition(guild(logoX: nil, logoY: nil))
        XCTAssertEqual(p, GuildOfficeView.clampLogo(CGPoint(x: 46, y: 26)))
    }

    // x 하나만 온 반쪽 데이터도 기본 자리로 (둘 다 있어야 유효).
    func testPartialCoordinateFallsBackToDefault() {
        XCTAssertEqual(GuildOfficeView.logoPosition(guild(logoX: 100, logoY: nil)),
                       GuildOfficeView.logoPosition(guild(logoX: nil, logoY: nil)))
    }

    // 벽 밴드 위/왼쪽 밖으로 나가면 안쪽으로 당겨진다.
    func testClampTopLeft() {
        let p = GuildOfficeView.clampLogo(CGPoint(x: -500, y: -500))
        XCTAssertGreaterThanOrEqual(p.x, half.width)
        XCTAssertGreaterThanOrEqual(p.y, half.height)
    }

    // 오른쪽/아래(바닥 쪽)로 나가도 마찬가지 — 특히 y는 벽 하단(wallBottom)을 넘으면 안 된다.
    func testClampBottomRight() {
        let p = GuildOfficeView.clampLogo(CGPoint(x: 9999, y: 9999))
        XCTAssertLessThanOrEqual(p.x, OfficeLayout.sceneSize.width - half.width)
        XCTAssertLessThanOrEqual(p.y, OfficeLayout.wallBottom - half.height)
    }

    // 이미 유효한 좌표는 건드리지 않는다.
    func testValidPositionUnchanged() {
        let inside = CGPoint(x: 140, y: 26)
        XCTAssertEqual(GuildOfficeView.clampLogo(inside), inside)
    }

    // 클램프 결과는 항상 서버/DB가 받아들이는 범위(0..280, 0..60) 안이어야 한다.
    // 이게 깨지면 드래그가 서버에서 400 invalid_logo_pos로 조용히 거부된다.
    func testClampAlwaysWithinServerRange() {
        for x in stride(from: -400.0, through: 700.0, by: 37.0) {
            for y in stride(from: -400.0, through: 700.0, by: 37.0) {
                let p = GuildOfficeView.clampLogo(CGPoint(x: x, y: y))
                let rx = Int(p.x.rounded()), ry = Int(p.y.rounded())
                XCTAssertTrue((0...280).contains(rx), "x=\(rx) 범위 밖 (입력 \(x))")
                XCTAssertTrue((0...60).contains(ry), "y=\(ry) 범위 밖 (입력 \(y))")
            }
        }
    }

    // 로고는 벽 밴드 안에 들어가는 크기여야 한다 — 크기를 키우면 클램프 범위가 붕괴한다.
    func testLogoFitsInsideWallBand() {
        XCTAssertLessThan(GuildOfficeView.logoSceneSize.height, OfficeLayout.wallBottom)
        XCTAssertLessThan(GuildOfficeView.logoSceneSize.width, OfficeLayout.sceneSize.width)
        // 3:2 비율 유지 (GuildLogo와 같은 비율이어야 배너가 찌그러지지 않는다).
        let ratio = GuildOfficeView.logoSceneSize.width / GuildOfficeView.logoSceneSize.height
        XCTAssertEqual(ratio, CGFloat(GuildLogo.pixelWidth) / CGFloat(GuildLogo.pixelHeight),
                       accuracy: 0.001)
    }
}
