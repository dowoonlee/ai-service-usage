import AppKit
import SwiftUI

/// 길드 사무실 공간 정의 SSOT — 좌표계·스팟·가구·충돌 (docs/plans/guild.md §5-2).
///
/// 논리 캔버스 280×150 (뷰가 가용 폭에 맞춰 균등 스케일). 위 0~60은 벽 밴드(장식 전용),
/// 60~150이 바닥. 레인 3개(baseline y = 84/112/140) × 스팟 4개 = 12자리 — 서버
/// `guild_members.office_slot`(0..11)과 인덱스로 1:1 대응. 스팟/가구 배치는 전 길드 공통
/// 고정 레이아웃 (꾸미기는 P2b).
///
/// 충돌 모델: 바닥은 자유 통행, 가구는 **같은 레인에서만** footprint 폭으로 blocking.
/// 펫 이동은 레인 내 1D(x)라 판정이 구간 비교 하나로 끝난다. 자기 스팟의 가구는
/// 자기에게는 비충돌 (자리에 "앉아" 있어야 하므로) — `wanderRange(for:)`가 처리.
enum OfficeLayout {
    static let sceneSize = CGSize(width: 280, height: 150)
    static let wallBottom: CGFloat = 60
    /// 레인 baseline y (가구·펫의 바닥선). 인덱스 = lane.
    static let lanes: [CGFloat] = [84, 112, 140]
    /// 펫 산책 반경 (스팟 anchor ± 이 값, walkable로 클램프).
    static let wanderRadius: CGFloat = 40
    /// 씬 좌우 여백 — 펫이 화면 밖으로 나가지 않게.
    static let edgeMargin: CGFloat = 8
    /// 펫 기본 표시 높이 (논리 px). Mythic은 ×1.5 (기존 sizeScale 관례).
    static let petHeight: CGFloat = 22

    // MARK: - 스팟 (office_slot 0..11)

    struct Spot: Identifiable {
        let id: Int          // office_slot
        let name: String
        let lane: Int
        let anchorX: CGFloat
        /// working 모드 점유자가 있으면 데스크의 PC를 ON 애니로 전환.
        let hasPC: Bool
    }

    static let spots: [Spot] = [
        // 뒷레인 (0) — 벽 인접
        Spot(id: 0,  name: "창가 자리",     lane: 0, anchorX: 35,  hasPC: true),
        Spot(id: 1,  name: "화이트보드 앞", lane: 0, anchorX: 105, hasPC: false),
        Spot(id: 2,  name: "서버랙 옆",     lane: 0, anchorX: 175, hasPC: false),
        Spot(id: 3,  name: "시계 아래",     lane: 0, anchorX: 245, hasPC: false),
        // 중간 레인 (1)
        Spot(id: 4,  name: "데스크 A",      lane: 1, anchorX: 45,  hasPC: true),
        Spot(id: 5,  name: "데스크 B",      lane: 1, anchorX: 115, hasPC: true),
        Spot(id: 6,  name: "커피머신 앞",   lane: 1, anchorX: 185, hasPC: false),
        Spot(id: 7,  name: "책장 앞",       lane: 1, anchorX: 245, hasPC: false),
        // 앞레인 (2) — 라운지
        Spot(id: 8,  name: "소파",          lane: 2, anchorX: 45,  hasPC: false),
        Spot(id: 9,  name: "벤치",          lane: 2, anchorX: 115, hasPC: false),
        Spot(id: 10, name: "화분 옆",       lane: 2, anchorX: 185, hasPC: false),
        Spot(id: 11, name: "스탠딩 데스크", lane: 2, anchorX: 245, hasPC: false),
    ]

    static func spot(id: Int?) -> Spot? {
        guard let id, spots.indices.contains(id) else { return nil }
        return spots[id]
    }
    static func spotName(_ id: Int?) -> String? { spot(id: id)?.name }

    // MARK: - 가구

    /// 2dPig Pixel Office(CC0) PNG 또는 코드 드로잉. 좌표는 논리 px, baselineY = 이미지 하단.
    /// blockingWidth 0 = 비충돌 (벽걸이 장식). ownerSpot은 "자기 자리 가구는 자기에게 비충돌"
    /// 규칙의 키 — 스팟 기능 가구에만 지정.
    struct FurnitureItem {
        let imageName: String?       // nil = drawKind로 코드 드로잉
        let drawKind: DrawKind?
        let size: CGSize
        let anchorX: CGFloat
        let baselineY: CGFloat
        let blockingWidth: CGFloat
        let lane: Int?               // blocking 적용 레인. nil = 벽 장식 (비충돌)
        let ownerSpot: Int?
    }

    /// 에셋 공백 3종 — CC0 팩에 없어 코드로 그린다 (research/office-assets.md 검증 결과).
    enum DrawKind { case serverRack, standingDesk, window }

    static let furniture: [FurnitureItem] = [
        // 벽 장식 (비충돌)
        FurnitureItem(imageName: nil, drawKind: .window, size: CGSize(width: 26, height: 20),
                      anchorX: 35, baselineY: 46, blockingWidth: 0, lane: nil, ownerSpot: nil),
        FurnitureItem(imageName: "WHITEBOARD", drawKind: nil, size: CGSize(width: 32, height: 32),
                      anchorX: 105, baselineY: 52, blockingWidth: 0, lane: nil, ownerSpot: nil),
        FurnitureItem(imageName: "CLOCK", drawKind: nil, size: CGSize(width: 16, height: 32),
                      anchorX: 245, baselineY: 52, blockingWidth: 0, lane: nil, ownerSpot: nil),
        // 뒷레인 (0)
        FurnitureItem(imageName: "DESK_FRONT", drawKind: nil, size: CGSize(width: 48, height: 32),
                      anchorX: 35, baselineY: 84, blockingWidth: 40, lane: 0, ownerSpot: 0),
        FurnitureItem(imageName: nil, drawKind: .serverRack, size: CGSize(width: 20, height: 36),
                      anchorX: 175, baselineY: 84, blockingWidth: 18, lane: 0, ownerSpot: 2),
        // 중간 레인 (1)
        FurnitureItem(imageName: "DESK_FRONT", drawKind: nil, size: CGSize(width: 48, height: 32),
                      anchorX: 45, baselineY: 112, blockingWidth: 40, lane: 1, ownerSpot: 4),
        FurnitureItem(imageName: "DESK_FRONT", drawKind: nil, size: CGSize(width: 48, height: 32),
                      anchorX: 115, baselineY: 112, blockingWidth: 40, lane: 1, ownerSpot: 5),
        FurnitureItem(imageName: "COFFEE", drawKind: nil, size: CGSize(width: 16, height: 16),
                      anchorX: 185, baselineY: 112, blockingWidth: 12, lane: 1, ownerSpot: 6),
        FurnitureItem(imageName: "DOUBLE_BOOKSHELF", drawKind: nil, size: CGSize(width: 32, height: 32),
                      anchorX: 245, baselineY: 112, blockingWidth: 28, lane: 1, ownerSpot: 7),
        // 앞레인 (2)
        FurnitureItem(imageName: "SOFA_FRONT", drawKind: nil, size: CGSize(width: 32, height: 16),
                      anchorX: 45, baselineY: 140, blockingWidth: 28, lane: 2, ownerSpot: 8),
        FurnitureItem(imageName: "CUSHIONED_BENCH", drawKind: nil, size: CGSize(width: 16, height: 16),
                      anchorX: 115, baselineY: 140, blockingWidth: 14, lane: 2, ownerSpot: 9),
        FurnitureItem(imageName: "LARGE_PLANT", drawKind: nil, size: CGSize(width: 32, height: 48),
                      anchorX: 185, baselineY: 140, blockingWidth: 16, lane: 2, ownerSpot: 10),
        FurnitureItem(imageName: nil, drawKind: .standingDesk, size: CGSize(width: 28, height: 26),
                      anchorX: 245, baselineY: 140, blockingWidth: 24, lane: 2, ownerSpot: 11),
    ]

    /// 데스크 위 PC 배치 — hasPC 스팟에서 (anchorX, 데스크 상판 y). ON/OFF는 뷰가 결정.
    static let pcSize = CGSize(width: 16, height: 32)
    static func pcBaselineY(deskBaselineY: CGFloat) -> CGFloat { deskBaselineY - 13 }

    // MARK: - 충돌 / 산책 범위

    /// 해당 레인의 blocked x-interval 목록 (excludingSpot 소유 가구 제외).
    static func blockedIntervals(lane: Int, excludingSpot: Int?) -> [ClosedRange<CGFloat>] {
        furniture.compactMap { f in
            guard f.lane == lane, f.blockingWidth > 0, f.ownerSpot != excludingSpot else { return nil }
            let half = f.blockingWidth / 2
            return (f.anchorX - half)...(f.anchorX + half)
        }
    }

    /// 스팟의 펫 산책 가능 범위 — anchor ± wanderRadius를 씬 여백과 이웃 가구(자기 가구 제외)
    /// 경계로 클램프. 막히면 roomba식 방향 반전이 아니라 애초에 목표를 이 범위에서만 뽑는다.
    static func wanderRange(for spot: Spot) -> ClosedRange<CGFloat> {
        var lo = max(edgeMargin, spot.anchorX - wanderRadius)
        var hi = min(sceneSize.width - edgeMargin, spot.anchorX + wanderRadius)
        for interval in blockedIntervals(lane: spot.lane, excludingSpot: spot.id) {
            // anchor 왼쪽의 가구 → 하한을 가구 오른쪽 끝으로, 오른쪽 가구 → 상한을 왼쪽 끝으로.
            if interval.upperBound <= spot.anchorX {
                lo = max(lo, interval.upperBound + 2)
            } else if interval.lowerBound >= spot.anchorX {
                hi = min(hi, interval.lowerBound - 2)
            }
        }
        // 방어: 범위가 뒤집히면 anchor 고정.
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
