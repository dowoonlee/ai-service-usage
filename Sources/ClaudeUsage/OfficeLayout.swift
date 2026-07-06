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
/// 충돌 모델 (2D 자유 이동 — 사용자 피드백으로 레인 1D 산책에서 전환):
/// 펫은 `petWalkArea` 안을 상하좌우대각 자유 이동. 가구는 `PetPassing` 특성으로 3분류 —
/// `.avoid`(발밑 충돌 사각형을 피해감) / `.front`(펫이 항상 앞으로 지나감 = 펫이 위에 그려짐)
/// / `.behind`(펫이 항상 뒤로 지나감 = 가구가 펫을 가림). front/behind는 비충돌.
/// 재배치는 자유 드래그 — 같은 레인 내 시각 폭 기준 겹침을 `placementCollides`로 금지.
enum OfficeLayout {
    static let sceneSize = CGSize(width: 280, height: 150)
    static let wallBottom: CGFloat = 60
    /// 레인 baseline y (가구의 바닥선, 자리 anchor의 기준선). 인덱스 = lane.
    static let lanes: [CGFloat] = [84, 112, 140]
    /// 펫 산책 반경 (자리 anchor 중심 2D 반경, petWalkArea로 클램프).
    static let wanderRadius: CGFloat = 45
    /// 씬 좌우 여백 — 펫이 화면 밖으로 나가지 않게.
    static let edgeMargin: CGFloat = 8
    /// 펫 발(baseline)이 다닐 수 있는 바닥 영역 — 벽 밴드 아래 ~ 씬 하단.
    static let petWalkArea = CGRect(x: 8, y: 76, width: 264, height: 70)
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

    // MARK: - 멤버 자동 배치 (수동 자리 선택 폐기 — 사용자 피드백)

    /// 멤버 → 포지션 자동 랜덤 배정 (rendezvous 해시). 서버 왕복 없이 클라이언트에서
    /// 결정적으로 계산 — 같은 멤버 구성이면 모든 클라이언트·모든 새로고침에서 같은 씬.
    /// 멤버 추가/이탈 시에도 경합이 없는 한 기존 멤버의 자리는 유지된다.
    /// 포지션(12)보다 멤버가 많으면 앞선 순서(호출 측이 기여도순 정렬) 12명만 배치.
    static func autoAssignments(memberIds: [String], seed: String) -> [String: Int] {
        var free = Set(spots.map(\.id))
        var out: [String: Int] = [:]
        for member in memberIds {
            guard let pick = free.max(by: {
                fnv1a("\(seed)|\(member)|\($0)") < fnv1a("\(seed)|\(member)|\($1)")
            }) else { break }
            out[member] = pick
            free.remove(pick)
        }
        return out
    }

    /// FNV-1a 64 — String.hashValue는 실행마다 시드가 달라 재현 불가라 직접 구현.
    private static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    // MARK: - 가구 세트 (재배치 대상 — 순열로 포지션 위를 이동)

    /// 에셋 공백 3종 — CC0 팩에 없어 코드로 그린다 (research/office-assets.md 검증 결과).
    enum DrawKind { case serverRack, standingDesk, window }

    /// 펫-가구 통행 특성 (기획 §5-2 확장 — 사용자 요청 3분류):
    /// avoid = 피해감(발밑 충돌 사각형), front = 앞으로 지나감(펫이 가구 위에 그려짐),
    /// behind = 뒤로 지나감(가구가 펫을 가림). front/behind는 비충돌.
    enum PetPassing { case avoid, front, behind }

    struct SetItem {
        let imageName: String?       // nil = drawKind로 코드 드로잉
        let drawKind: DrawKind?
        let size: CGSize
        let blockingWidth: CGFloat   // avoid일 때 충돌 사각형 폭 (드래그 겹침 검사에도 사용)
        let passing: PetPassing
    }

    /// 바닥 가구 세트. item == nil 은 "빈 자리 세트" (서서 일하는 오픈 스팟).
    struct FurnitureSet: Identifiable {
        let id: Int
        let name: String             // 재배치 UI 표시용
        let item: SetItem?
        let hasPC: Bool              // 데스크 세트 — 점유자 working 시 PC ON 애니
    }

    /// passing 배정 기준: 몸통이 크고 높은 것(데스크/서버랙/책장/커피머신)은 피해가고,
    /// 낮은 좌석류(소파/벤치)는 앞으로 지나가며, 다리·잎 사이가 비치는 것(화분/스탠딩
    /// 데스크)은 뒤로 지나가 가려진다.
    static let furnitureSets: [FurnitureSet] = [
        FurnitureSet(id: 0, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40,
                                   passing: .avoid),
                     hasPC: true),
        FurnitureSet(id: 1, name: "빈 자리", item: nil, hasPC: false),
        FurnitureSet(id: 2, name: "서버랙",
                     item: SetItem(imageName: nil, drawKind: .serverRack,
                                   size: CGSize(width: 20, height: 36), blockingWidth: 18,
                                   passing: .avoid),
                     hasPC: false),
        FurnitureSet(id: 3, name: "빈 자리", item: nil, hasPC: false),
        FurnitureSet(id: 4, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40,
                                   passing: .avoid),
                     hasPC: true),
        FurnitureSet(id: 5, name: "데스크+PC",
                     item: SetItem(imageName: "DESK_FRONT", drawKind: nil,
                                   size: CGSize(width: 48, height: 32), blockingWidth: 40,
                                   passing: .avoid),
                     hasPC: true),
        FurnitureSet(id: 6, name: "커피머신",
                     item: SetItem(imageName: "COFFEE", drawKind: nil,
                                   size: CGSize(width: 16, height: 16), blockingWidth: 12,
                                   passing: .avoid),
                     hasPC: false),
        FurnitureSet(id: 7, name: "책장",
                     item: SetItem(imageName: "DOUBLE_BOOKSHELF", drawKind: nil,
                                   size: CGSize(width: 32, height: 32), blockingWidth: 28,
                                   passing: .avoid),
                     hasPC: false),
        FurnitureSet(id: 8, name: "소파",
                     item: SetItem(imageName: "SOFA_FRONT", drawKind: nil,
                                   size: CGSize(width: 32, height: 16), blockingWidth: 28,
                                   passing: .front),
                     hasPC: false),
        FurnitureSet(id: 9, name: "벤치",
                     item: SetItem(imageName: "CUSHIONED_BENCH", drawKind: nil,
                                   size: CGSize(width: 16, height: 16), blockingWidth: 14,
                                   passing: .front),
                     hasPC: false),
        FurnitureSet(id: 10, name: "화분",
                     item: SetItem(imageName: "LARGE_PLANT", drawKind: nil,
                                   size: CGSize(width: 32, height: 48), blockingWidth: 16,
                                   passing: .behind),
                     hasPC: false),
        FurnitureSet(id: 11, name: "스탠딩 데스크",
                     item: SetItem(imageName: nil, drawKind: .standingDesk,
                                   size: CGSize(width: 28, height: 26), blockingWidth: 24,
                                   passing: .behind),
                     hasPC: false),
    ]

    // MARK: - 가구 자유 배치 (드래그 — 사용자 피드백으로 스왑 방식에서 전환)

    /// 가구 세트 1개의 놓인 자리 — x 연속값, 바닥선은 레인에 스냅 (픽셀 씬 정합).
    /// 멤버 자리(spots 포지션)와는 독립 — 가구만 움직인다.
    struct FurniturePlacement: Equatable, Identifiable {
        let setId: Int
        var x: CGFloat
        var lane: Int
        var id: Int { setId }
    }

    /// 기본 배치 — 세트 id = 같은 id의 포지션 위.
    static let defaultPlacements: [FurniturePlacement] =
        spots.map { FurniturePlacement(setId: $0.id, x: $0.anchorX, lane: $0.lane) }

    /// 서버 직렬화("setId:x:lane;…") 파싱 — 형식/범위 벗어나면 기본 배치 폴백.
    /// 서버가 안 주는 세트(부분 저장)는 기본 위치로 보충해 항상 12세트 전부 렌더.
    static func sanitizedPlacements(_ raw: String?) -> [FurniturePlacement] {
        guard let raw, !raw.isEmpty else { return defaultPlacements }
        var byId: [Int: FurniturePlacement] = [:]
        for entry in raw.split(separator: ";") {
            let parts = entry.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { return defaultPlacements }
            let setId = Int(parts[0]); let x = CGFloat(parts[1]); let lane = Int(parts[2])
            guard furnitureSets.indices.contains(setId), byId[setId] == nil,
                  (0...sceneSize.width).contains(x), (0...2).contains(lane) else {
                return defaultPlacements
            }
            byId[setId] = FurniturePlacement(setId: setId, x: x, lane: lane)
        }
        return furnitureSets.map { byId[$0.id] ?? defaultPlacements[$0.id] }
    }

    /// 서버 전송용 직렬화 — x는 소수 1자리로 절사 (payload 크기·서버 600자 제한 고려).
    static func serializePlacements(_ placements: [FurniturePlacement]) -> String {
        placements.map { String(format: "%d:%.1f:%d", $0.setId, $0.x, $0.lane) }
            .joined(separator: ";")
    }

    /// 드롭 시 클램프 — 씬 여백 안, 레인 0..2.
    static func clampPlacement(x: CGFloat, laneY: CGFloat) -> (x: CGFloat, lane: Int) {
        let cx = min(max(x, edgeMargin), sceneSize.width - edgeMargin)
        // 가장 가까운 레인으로 스냅.
        let lane = lanes.enumerated().min { abs($0.element - laneY) < abs($1.element - laneY) }?.offset ?? 2
        return (cx, lane)
    }

    /// 드래그 중 가구 겹침 검사 — 같은 레인에서 두 가구의 시각 폭이 겹치면 true.
    /// (레인이 다르면 바닥 점유가 다르므로 허용 — 픽셀 씬의 원근 겹침은 자연스럽다.)
    static func placementCollides(setId: Int, x: CGFloat, lane: Int,
                                  others: [FurniturePlacement]) -> Bool {
        guard let myItem = furnitureSet(id: setId)?.item else { return false }
        return others.contains { p in
            guard p.setId != setId, p.lane == lane,
                  let item = furnitureSet(id: p.setId)?.item else { return false }
            return abs(x - p.x) < (myItem.size.width + item.size.width) / 2
        }
    }

    static func furnitureSet(id: Int) -> FurnitureSet? {
        furnitureSets.indices.contains(id) ? furnitureSets[id] : nil
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

    // MARK: - 데코 슬롯 + 카탈로그 (P2b 꾸미기 — 기부 모델, 기획 §2)

    enum DecorCategory: String { case wall, floor }

    /// 데코 슬롯 10개 — 벽 0..4(붙박이 장식 사이 빈 벽), 바닥 5..9(가구 포지션 사이 통로).
    /// id는 서버 guild_furniture.slot_id와 1:1 (서버 DECOR_SLOT_COUNT와 쌍).
    struct DecorSlot: Identifiable {
        let id: Int
        let category: DecorCategory
        let anchorX: CGFloat
        let baselineY: CGFloat
        let lane: Int?          // 바닥 슬롯의 레인 — 배치된 아이템의 blocking 적용용
    }

    static let decorSlots: [DecorSlot] = [
        DecorSlot(id: 0, category: .wall, anchorX: 70,  baselineY: 52, lane: nil),
        DecorSlot(id: 1, category: .wall, anchorX: 140, baselineY: 52, lane: nil),
        DecorSlot(id: 2, category: .wall, anchorX: 175, baselineY: 52, lane: nil),
        DecorSlot(id: 3, category: .wall, anchorX: 210, baselineY: 52, lane: nil),
        DecorSlot(id: 4, category: .wall, anchorX: 268, baselineY: 52, lane: nil),
        // 바닥 — 기본 배치 기준 가구 footprint 사이 여백. 재배치로 겹칠 수 있으나 데코는
        // 소품이라 시각적 겹침만 생기고 로직은 안전 (blocking은 구간 union).
        DecorSlot(id: 5, category: .floor, anchorX: 80,  baselineY: lanes[1], lane: 1),
        DecorSlot(id: 6, category: .floor, anchorX: 155, baselineY: lanes[1], lane: 1),
        DecorSlot(id: 7, category: .floor, anchorX: 80,  baselineY: lanes[2], lane: 2),
        DecorSlot(id: 8, category: .floor, anchorX: 210, baselineY: lanes[2], lane: 2),
        DecorSlot(id: 9, category: .floor, anchorX: 140, baselineY: lanes[0], lane: 0),
    ]

    static func decorSlot(id: Int) -> DecorSlot? {
        decorSlots.first { $0.id == id }
    }

    /// 구매 가능 데코 카탈로그 — kind = 서버 item_kind = 리소스 basename.
    /// 가격은 기획 §2 (소품 300 / 중형 500 / 대형 1,000).
    struct DecorItem: Identifiable {
        let kind: String
        let name: String
        let category: DecorCategory
        let price: Int
        let size: CGSize
        let blockingWidth: CGFloat   // passing == .avoid인 바닥 데코의 충돌 폭
        let passing: PetPassing      // 벽 데코는 펫 동선 밖이라 무의미 (behind로 통일)
        var id: String { kind }
        var imageName: String { kind }
    }

    static let decorCatalog: [DecorItem] = [
        // 벽
        DecorItem(kind: "SMALL_PAINTING", name: "작은 그림 A", category: .wall, price: 300,
                  size: CGSize(width: 16, height: 32), blockingWidth: 0, passing: .behind),
        DecorItem(kind: "SMALL_PAINTING_2", name: "작은 그림 B", category: .wall, price: 300,
                  size: CGSize(width: 16, height: 32), blockingWidth: 0, passing: .behind),
        DecorItem(kind: "LARGE_PAINTING", name: "큰 그림", category: .wall, price: 1000,
                  size: CGSize(width: 32, height: 32), blockingWidth: 0, passing: .behind),
        DecorItem(kind: "HANGING_PLANT", name: "행잉 플랜트", category: .wall, price: 500,
                  size: CGSize(width: 16, height: 32), blockingWidth: 0, passing: .behind),
        // 바닥 — 키 큰 식물류는 뒤로 지나가고(가려짐), 소품은 앞으로, 테이블은 피해간다.
        DecorItem(kind: "PLANT", name: "화분 A", category: .floor, price: 300,
                  size: CGSize(width: 16, height: 32), blockingWidth: 10, passing: .behind),
        DecorItem(kind: "PLANT_2", name: "화분 B", category: .floor, price: 300,
                  size: CGSize(width: 16, height: 32), blockingWidth: 10, passing: .behind),
        DecorItem(kind: "CACTUS", name: "선인장", category: .floor, price: 300,
                  size: CGSize(width: 16, height: 32), blockingWidth: 10, passing: .behind),
        DecorItem(kind: "POT", name: "도자기 화분", category: .floor, price: 300,
                  size: CGSize(width: 16, height: 16), blockingWidth: 10, passing: .front),
        DecorItem(kind: "BIN", name: "휴지통", category: .floor, price: 300,
                  size: CGSize(width: 16, height: 16), blockingWidth: 10, passing: .front),
        DecorItem(kind: "COFFEE_TABLE", name: "커피 테이블", category: .floor, price: 500,
                  size: CGSize(width: 32, height: 32), blockingWidth: 24, passing: .avoid),
    ]

    static func decorItem(kind: String) -> DecorItem? {
        decorCatalog.first { $0.kind == kind }
    }

    /// avoid 특성 가구·바닥 데코의 발밑 충돌 사각형 — 펫 2D 이동이 피해 다닐 영역.
    /// 사각형은 baseline 주변의 낮은 띠(높이 12) — 펫 "발" 기준 판정이라 몸통 겹침은 허용
    /// (뒤쪽을 스치듯 지나가는 픽셀 씬 특유의 원근이 살아 있게).
    static func collisionRects(placements: [FurniturePlacement],
                               decor: [(slotId: Int, kind: String)]) -> [CGRect] {
        var rects: [CGRect] = []
        for p in placements {
            guard let item = furnitureSet(id: p.setId)?.item, item.passing == .avoid else { continue }
            rects.append(CGRect(x: p.x - item.blockingWidth / 2, y: lanes[p.lane] - 10,
                                width: item.blockingWidth, height: 12))
        }
        for entry in decor {
            guard let slot = decorSlot(id: entry.slotId), slot.category == .floor,
                  let item = decorItem(kind: entry.kind), item.passing == .avoid else { continue }
            rects.append(CGRect(x: slot.anchorX - item.blockingWidth / 2, y: slot.baselineY - 10,
                                width: item.blockingWidth, height: 12))
        }
        return rects
    }

    // MARK: - 인테리어 테마 (P2b — 길드장 전용, 가격은 기획 §2 테마 2,000)

    static let floorThemeCount = 9         // 2dPig floor_0..floor_8 (서버 FLOOR_THEME_MAX와 쌍)
    static let themePrice = 2_000
    /// 벽지 틴트 변형 — 0=기본, 이후는 벽 밴드 위 컬러 오버레이 (서버 WALL_THEME_MAX와 쌍).
    static let wallTints: [Color] = [
        .clear,
        Color(red: 0.95, green: 0.75, blue: 0.45),   // 웜톤
        Color(red: 0.45, green: 0.65, blue: 0.95),   // 쿨톤
        Color(red: 0.55, green: 0.85, blue: 0.55),   // 그린
    ]

    // MARK: - 배경 (벽+바닥 타일 프리렌더)

    /// 기본 배경 — floorTheme 0. (기존 호출부 호환용 별칭.)
    @MainActor
    static var backgroundImage: NSImage? { backgroundImage(floorTheme: 0) }

    @MainActor
    private static var backgroundCache: [Int: NSImage] = [:]

    /// 벽/바닥 타일을 논리 크기 ×2로 합성해 테마별 1회 캐시 — 매 틱 타일 draw 반복을 피한다.
    /// (2dPig CC0 wall_0/floor_0..8. 리소스 로드는 PetSprite와 동일한 번들 경로.)
    @MainActor
    static func backgroundImage(floorTheme: Int) -> NSImage? {
        let theme = (0..<floorThemeCount).contains(floorTheme) ? floorTheme : 0
        if let cached = backgroundCache[theme] { return cached }
        guard let img = renderBackground(floorName: "floor_\(theme)") else { return nil }
        backgroundCache[theme] = img
        return img
    }

    @MainActor
    private static func renderBackground(floorName: String) -> NSImage? {
        guard let wall = officeImage("wall_0"), let floor = officeImage(floorName) else { return nil }
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
    }

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
