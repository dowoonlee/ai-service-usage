import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 화면 단위 시각 검수 — 가챠 창의 탭들, 월드맵, 길드 사무실, 배틀 재생.
///
/// 이 화면들은 전부 클릭으로만 도달하고, 대부분 진행도가 있어야 내용이 찬다. 데모 상태를 시드한
/// 샌드박스에서 실제 창 최소 폭(560)으로 렌더해서, 줄바꿈과 잘림이 실제와 같은 조건으로 보이게 한다.
///
/// 세로 잘림은 이 방식으로 **판정할 수 없다** — 탭은 `ScrollView`에 싸여 있어 렌더러가 콘텐츠
/// 전체 높이를 돌려주기 때문이다(CLAUDE.md "Windows and layout" 참조). 대신 렌더된 높이를
/// 갤러리에 같이 적어두므로, 창 최소 높이(640)보다 훨씬 크면 스크롤이 실제로 필요한 탭이라는
/// 뜻이고 최상위 ScrollView가 있는지 확인하면 된다.
///
///   bash scripts/render-previews.sh scene
@MainActor
final class ScenePreviews: SandboxedTestCase {

    /// 가챠 창 최소 크기 — `GachaWindowController`와 같은 값.
    private let windowWidth: CGFloat = 560
    private let windowHeight: CGFloat = 640

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { PreviewDemoState.seed() }
    }

    /// 탭 하나를 창 최소 크기 그대로 찍는다. 잘린다면 그게 실제로 사용자가 보는 화면이다.
    private func renderTab(_ view: some View, title: String, note: String) throws {
        try PreviewRenderer.renderInWindow(
            view, size: CGSize(width: windowWidth, height: windowHeight),
            section: "화면", title: title,
            note: "\(note) · 창 최소 \(Int(windowWidth))×\(Int(windowHeight)). 아래가 잘려 보이면 "
                + "최상위 ScrollView가 있는지 확인할 것.")
    }

    // MARK: - 가챠 창 탭

    func testRenderGachaTab() throws {
        try renderTab(GachaView(), title: "탭-1-가챠", note: "뽑기 대기 상태. 알·비용·잔액 배치")
    }

    func testRenderPartyTab() throws {
        try renderTab(PartyView(), title: "탭-2-파티", note: "3소스 파티가 각각 3마리 채워진 상태")
    }

    func testRenderGymTab() throws {
        try renderTab(GymView(), title: "탭-3-도장",
                      note: "지역별 뱃지 진행도가 섞인 상태. 카테고리 행이 잘리지 않는지")
    }

    func testRenderReportTab() throws {
        try renderTab(ReportView(), title: "탭-4-레포트", note: "트레이너 카드 + 꾸미기 상점")
    }

    func testRenderArenaTab() throws {
        try renderTab(ArenaView(), title: "탭-7-아레나", note: "연습 모드 기본 상태. 팀 슬롯과 강화 패널")
    }

    // MARK: - 월드맵

    /// 지역 하나하나가 아니라 전체 맵. 타운 위치가 자기 지형 위에 있는지는 `WorldMapTests`가
    /// 좌표로 검증하지만, 실제로 "읽히는 그림"인지는 눈으로만 판정된다.
    func testRenderWorldMap() throws {
        for region in BadgeRegion.allCases.prefix(4) {
            try PreviewRenderer.renderInWindow(
                WorldMapView(selected: .constant(region)),
                size: CGSize(width: windowWidth, height: 360),
                section: "월드맵", title: "map-\(region.rawValue)",
                note: "선택 지역 \(region.rawValue) — 카메라가 해당 지역을 담는지, 라벨이 겹치지 않는지.")
        }
    }

    // MARK: - 길드 사무실

    /// 사무실 뷰는 콜백을 7개 받는다. 프리뷰는 상호작용이 없으므로 전부 no-op을 넣는다 —
    /// 콜백이 하는 일(서버 반영)은 여기서 볼 대상이 아니고, 초기 배치 그림만 본다.
    private func officeView(info: RankingAPI.GuildInfoResponse,
                            rearrange: Bool, floor: Int?, wall: Int?) -> some View {
        GuildOfficeView(
            info: info,
            rearrangeMode: .constant(rearrange),
            previewFloorTheme: .constant(floor),
            previewWallTheme: .constant(wall),
            onSetFurniture: { _ in },
            onSetLogoPos: { _, _ in },
            onBuyFurniture: { _, _ in },
            onPlaceDecor: { _, _ in },
            onRemoveDecor: { _ in },
            onApplyTheme: {},
            purchaseSheetOpen: .constant(false))
    }

    /// 가구 배치·펫 배회·로고 배너가 한 화면에 겹치는 곳이라, 좌표 로직을 고칠 때마다
    /// 실제 그림을 봐야 한다. `GuildOfficeDemo`는 창을 띄우지만 여기선 뷰만 굽는다.
    func testRenderGuildOffice() throws {
        let info = PreviewDemoState.guildInfo()
        let view = officeView(info: info, rearrange: false, floor: nil, wall: nil)
        try PreviewRenderer.renderInWindow(
            view, size: CGSize(width: windowWidth, height: windowHeight),
            section: "길드", title: "사무실-기본",
            note: "가구 6개 배치 + 멤버 펫. 가구가 벽/바닥 경계를 넘지 않는지")
    }

    func testRenderGuildOfficeRearrangeMode() throws {
        let info = PreviewDemoState.guildInfo()
        let view = officeView(info: info, rearrange: true, floor: 3, wall: 1)
        try PreviewRenderer.renderInWindow(
            view, size: CGSize(width: windowWidth, height: windowHeight),
            section: "길드", title: "사무실-배치모드",
            note: "배치 모드 + 테마 프리뷰(바닥3/벽1). 슬롯 가이드가 보이는지")
    }

    // MARK: - 배틀 재생

    /// 관장전/아레나가 공유하는 재생 뷰. 팀 크기(3v3 / 5v5)와 결과 상태에 따라 높이가 달라지고,
    /// 그 높이가 시트 `minHeight`를 넘으면 아래가 잘린다(#223).
    func testRenderBattleReplay() throws {
        let cases: [(String, [PetKind], [PetKind])] = [
            ("배틀-3v3", [.fox, .wolf, .bear], [.slime, .goblin, .bat]),
            ("배틀-5v5", [.fox, .wolf, .bear, .warrior, .lancer], [.slime, .goblin, .bat, .zombie, .orc]),
        ]
        for (title, aKinds, bKinds) in cases {
            let a = aKinds.map { BattlePetSnapshot(kind: $0, variant: 1) }
            let b = bKinds.map { BattlePetSnapshot(kind: $0, variant: 0) }
            let result = BattleEngine.simulate(teamA: BattleTeam(a), teamB: BattleTeam(b), seed: 42)
            let view = BattleReplayView(aSnaps: a, bSnaps: b, result: result) { EmptyView() }
            let size = try PreviewRenderer.render(
                view, section: "배틀", title: title,
                note: "재생 초기 상태. 시트 minHeight(540) 안에 들어가는지는 GymBattleSizeProbe가 수치로 단언한다.",
                width: 430 - 32)
            print("PREVIEW \(title) height=\(size.height)")
        }
    }
}
