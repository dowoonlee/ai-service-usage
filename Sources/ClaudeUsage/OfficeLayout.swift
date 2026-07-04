import AppKit
import SwiftUI

/// 길드 사무실 공간 정의 SSOT — 좌표계·포지션·가구 세트·충돌 (docs/plans/guild.md §5-2).
///
/// 논리 캔버스 280×150 (뷰가 가용 폭에 맞춰 균등 스케일). 위 0~60은 벽 밴드(장식 전용),
/// 60~150이 바닥. 레인 3개(baseline y = 84/112/140) × 4 = **포지션 12개**.
///
/// 포지션 vs 가구 세트 (가구 재배치의 핵심 분리):
///   - **포지션**: 장소 그 자체 — 좌표·이름("창가 자리")·벽 장식(붙박이)이 결부.
///     서버 `guild_members.office_slot`(0..11)은 포지션 id — 멤버는 "장소"에 앉는다.
///   - **가구 세트**: 바닥 가구(데스크+PC/소파/커피머신/…) 12세트. 길드별
///     `office_layout` 순열(layout[포지션] = 세트 id)로 포지션 위를 이동한다 (길드장 재배치).
///
/// 충돌 모델: 바닥은 자유 통행, 가구는 **같은 레인에서만** footprint 폭으로 blocking.
/// 자기 포지션의 가구는 자기에게 비충돌 (자리에 "앉아" 있어야 하므로). 펫 이동은 레인 내
/// 1D(x)라 판정이 구간 비교 하나로 끝난다. 재배치는 순열 교체뿐이라 겹침 검증이 불필요.
enum OfficeLayout {
    static let sceneSize = CGSize(width: 280, height: 150)
    static let wallBottom: CGFloat = 60
    /// 레인 baseline y (가구·펫의 바닥선). 인덱스 = lane.
    static let lanes: [CGFloat] = [84, 112, 140]
    /// 펫 산책 반경 (포지션 anchor ± 이 값, walkable로 클램프).
    static let wanderRadius: CGFloat = 40
    /// 씬 좌우 여백 — 펫이 화면 밖으로 나가지 않게.
    static let edgeMargin: CGFloat = 8
    /// 펫 기본 표시 높이 (논리 px). Mythic은 ×1.5 (기존 sizeScale 관례).
    static let petHeight: CGFloat = 22

    // MARK: - 포지션 (office_slot 0..11 — 고정)

    /// 이름은 장소 기반 — 가구가 이동해도 모순이 없도록 벽 장식(붙박이)·방향 기준으로만 짓는다.
    struct Spot: Identifiable {
        let id: Int          // office_slot = 포지션 id
        let name: String
        let lane: Int
        let anchorX: CGFloat
    }

    static let spots: [Spot] = [
        // 뒷레인 (0) — 벽 인접
        Spot(id: 0,  name: "창가 자리",     lane: 0, anchorX: 35),
        Spot(id: 1,  name: "화이트보드 앞", lane: 0, anchorX: 105),
        Spot(id: 2,  name: "안쪽 자리",     lane: 0, anchorX: 175),
        Spot(id: 3,  name: "시계 아래",     lane: 0, anchorX: 245),
        // 중간 레인 (1)
        Spot(id: 4,  name: "가운데 A",      lane: 1, anchorX: 45),
        Spot(id: 5,  name: "가운데 B",      lane: 1, anchorX: 115),
        Spot(id: 6,  name: "가운데 C",      lane: 1, anchorX: 185),
        Spot(id: 7,  name: "가운데 D",      lane: 1, anchorX: 245),
        // 앞레인 (2) — 입구 쪽
        Spot(id: 8,  name: "입구 A",        lane: 2, anchorX: 45),
        Spot(id: 9,  name: "입구 B",        lane: 2, anchorX: 115),
        Spot(id: 10, name: "입구 C",        lane: 2, anchorX: 185),
        Spot(id: 11, name: "입구 D",        lane: 2, anchorX: 245),
    ]

    static func spot(id: Int?) -> Spot? {
        guard let id, spots.indices.contains(id) else { return nil }
        return spots[id]
    }
    static func spotName(_ id: Int?) -> String? { spot(id: id)?.name }

    // MARK: - 가구 세트 (재배치 대상 — 순열로 포지션 위를 이동)

    /// 에셋 공백 3종 — CC0 팩에 없어 코드로 그린다 (research/office-assets.md 검증 결과).
    enum DrawKind { case serverRack, standingDesk, window }

    struct SetItem {
        let imageName: String?       // nil = drawKind로 코드 드로잉
        let drawKind: DrawKind?
        let size: CGSize
        let blockingWidth: CGFloat
    }

    /// 바닥 가구 세트. item == nil 은 "빈 자리 세트" (서서 일하는 오픈 스팟).
    struct FurnitureSet: Identifiable {
        let id: Int
        let name: String             // 재배치 UI 표시용
        let item: SetItem?
        let hasPC: Bool              // 데스크 세트 — 점유자 working 시 PC ON 애니
    }

    static let furnitureSets: [FurnitureSet] = [
        FurnitureSet(id: 0, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40),
                     hasPC: true),
        FurnitureSet(id: 1, name: "빈 자리", item: nil, hasPC: false),
        FurnitureSet(id: 2, name: "서버랙",
                     item: SetItem(imageName: nil, drawKind: .serverRack,
                                   size: CGSize(width: 20, height: 36), blockingWidth: 18),
                     hasPC: false),
        FurnitureSet(id: 3, name: "빈 자리", item: nil, hasPC: false),
        FurnitureSet(id: 4, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40),
                     hasPC: true),
        FurnitureSet(id: 5, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40),
                     hasPC: true),
        FurnitureSet(id: 6, name: "커피머신",
                     item: SetItem(imageName: "COFFEE", drawKind: nil,
                                   size: CGSize(width: 16, height: 16), blockingWidth: 12),
                     hasPC: false),
        FurnitureSet(id: 7, name: "책장",
                     item: SetItem(imageName: "DOUBLE_BOOKSHELF", drawKind: nil,
                                   size: CGSize(width: 32, height: 32), blockingWidth: 28),
                     hasPC: false),
        FurnitureSet(id: 8, name: "소파",
                     item: SetItem(imageName: "SOFA_FRONT", drawKind: nil,
                                   size: CGSize(width: 32, height: 16), blockingWidth: 28),
                     hasPC: false),
        FurnitureSet(id: 9, name: "벤치",
                     item: SetItem(imageName: "CUSHIONED_BENCH", drawKind: nil,
                                   size: CGSize(width: 16, height: 16), blockingWidth: 14),
                     hasPC: false),
        FurnitureSet(id: 10, name: "화분",
                     item: SetItem(imageName: "LARGE_PLANT", drawKind: nil,
                                   size: CGSize(width: 32, height: 48), blockingWidth: 16),
                     hasPC: false),
        FurnitureSet(id: 11, name: "스탠딩 데스크",
                     item: SetItem(imageName: nil, drawKind: .standingDesk,
                                   size: CGSize(width: 28, height: 26), blockingWidth: 24),
                     hasPC: false),
    ]

    /// 기본 배치 — 세트 id = 포지션 id.
    static let defaultLayout: [Int] = Array(0..<12)

    /// 서버 응답 검증 — 0..11 순열이 아니면 기본 배치로 폴백 (렌더 크래시 방지).
    static func sanitizedLayout(_ layout: [Int]?) -> [Int] {
        guard let layout, layout.count == spots.count,
              layout.sorted() == defaultLayout else { return defaultLayout }
        return layout
    }

    /// 해당 포지션에 현재 놓인 가구 세트.
    static func furnitureSet(at position: Int, layout: [Int]) -> FurnitureSet? {
        guard layout.indices.contains(position),
              furnitureSets.indices.contains(layout[position]) else { return nil }
        return furnitureSets[layout[position]]
    }

    static func hasPC(at position: Int, layout: [Int]) -> Bool {
        furnitureSet(at: position, layout: layout)?.hasPC ?? false
    }

    // MARK: - 벽 장식 (붙박이 — 재배치 무관)

    struct WallDecor {
        let imageName: String?
        let drawKind: DrawKind?
        let size: CGSize
        let anchorX: CGFloat
        let baselineY: CGFloat
    }

    static let wallDecor: [WallDecor] = [
        WallDecor(imageName: nil, drawKind: .window,
                  size: CGSize(width: 26, height: 20), anchorX: 35, baselineY: 46),
        WallDecor(imageName: "WHITEBOARD", drawKind: nil,
                  size: CGSize(width: 32, height: 32), anchorX: 105, baselineY: 52),
        WallDecor(imageName: "CLOCK", drawKind: nil,
                  size: CGSize(width: 16, height: 32), anchorX: 245, baselineY: 52),
    ]

    /// 데스크 위 PC 배치 — hasPC 세트가 놓인 포지션에서 (anchorX, 데스크 상판 y).
    static let pcSize = CGSize(width: 16, height: 32)
    static func pcBaselineY(deskBaselineY: CGFloat) -> CGFloat { deskBaselineY - 13 }

    // MARK: - 충돌 / 산책 범위 (layout 의존)

    /// 해당 레인의 blocked x-interval 목록 (excludingPosition의 가구 제외).
    static func blockedIntervals(lane: Int, layout: [Int],
                                 excludingPosition: Int?) -> [ClosedRange<CGFloat>] {
        spots.compactMap { pos in
            guard pos.lane == lane, pos.id != excludingPosition,
                  let item = furnitureSet(at: pos.id, layout: layout)?.item,
                  item.blockingWidth > 0 else { return nil }
            let half = item.blockingWidth / 2
            return (pos.anchorX - half)...(pos.anchorX + half)
        }
    }

    /// 포지션의 펫 산책 가능 범위 — anchor ± wanderRadius를 씬 여백과 이웃 가구(자기 포지션
    /// 가구 제외) 경계로 클램프. 막히면 방향 반전이 아니라 애초에 목표를 이 범위에서만 뽑는다.
    static func wanderRange(for spot: Spot, layout: [Int]) -> ClosedRange<CGFloat> {
        var lo = max(edgeMargin, spot.anchorX - wanderRadius)
        var hi = min(sceneSize.width - edgeMargin, spot.anchorX + wanderRadius)
        for interval in blockedIntervals(lane: spot.lane, layout: layout,
                                         excludingPosition: spot.id) {
            if interval.upperBound <= spot.anchorX {
                lo = max(lo, interval.upperBound + 2)
            } else if interval.lowerBound >= spot.anchorX {
                hi = min(hi, interval.lowerBound - 2)
            }
        }
        if lo > hi { return spot.anchorX...spot.anchorX }
        return lo...hi
    }

    // MARK: - 배경 (벽+바닥 타일 프리렌더)

    /// 벽/바닥 타일을 논리 크기 ×2로 1회 합성해 캐시 — 매 틱 타일 draw 반복을 피한다.
    /// (2dPig CC0 wall_0/floor_0. 리소스 로드는 PetSprite와 동일한 번들 경로.)
    @MainActor
    static let backgroundImage: NSImage? = {
        guard let wall = officeImage("wall_0"), let floor = officeImage("floor_0") else { return nil }
        let scale: CGFloat = 2
        let size = CGSize(width: sceneSize.width * scale, height: sceneSize.height * scale)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        // 벽 먼저 — 64×128 타일. 바닥이 나중에 위를 덮으므로 상단 60논리px만 남는다.
        // (순서를 바꾸면 벽 패널 무늬가 바닥을 덮는다 — 데모 검증에서 잡은 버그.)
        let wallW: CGFloat = 64 * scale
        let wallH: CGFloat = 128 * scale
        var wx: CGFloat = 0
        while wx < size.width {
            wall.draw(in: CGRect(x: wx, y: size.height - wallH, width: wallW, height: wallH))
            wx += wallW
        }
        // 바닥 — 16px 타일. flipped 아님 (NSImage 좌표: 아래가 0) → 아래에서부터 논리 90px 채움.
        let floorTile: CGFloat = 16 * scale
        let floorTop = size.height - wallBottom * scale   // 논리 y=60 아래가 바닥
        var y: CGFloat = 0
        while y < floorTop {
            var x: CGFloat = 0
            while x < size.width {
                floor.draw(in: CGRect(x: x, y: y, width: floorTile, height: floorTile))
                x += floorTile
            }
            y += floorTile
        }
        img.unlockFocus()
        return img
    }()

    /// pixel-office 리소스 로더 — PetSprite와 동일한 번들 fallback.
    @MainActor
    private static var imageCache: [String: NSImage] = [:]
    @MainActor
    static func officeImage(_ name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let bundle: Bundle = {
            if let url = Bundle.main.url(forResource: "ClaudeUsage_ClaudeUsage", withExtension: "bundle"),
               let b = Bundle(url: url) { return b }
            return .module
        }()
        guard let url = bundle.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            DebugLog.log("OfficeLayout: \(name).png 로드 실패")
            return nil
        }
        imageCache[name] = img
        return img
    }
}
