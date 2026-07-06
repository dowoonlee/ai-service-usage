import AppKit
import SwiftUI

/// 길드 사무실 공간 정의 SSOT — 좌표계·포지션·가구 세트·충돌 (docs/plans/guild.md §5-2).
///
/// 논리 캔버스 280×150 (뷰가 가용 폭에 맞춰 균등 스케일). 위 0~60은 벽 밴드(장식 전용),
/// 60~150이 바닥. 레인 3개(baseline y = 84/112/140) × 4 = **포지션 12개**.
///
/// 가구 모델 (카탈로그 + 보유 인스턴스 — 사용자 피드백으로 고정 12세트에서 전환):
///   - **포지션(spots)**: 멤버 자동 배치의 home 좌표 12개 (자리 이름 포함). 가구와 무관.
///   - **카탈로그(furnitureCatalog)**: 구매 가능한 가구 종류. 기본 제공 = 데스크+PC ×4 +
///     책장 ×1 (`defaultPlacements`), 나머지는 길드장이 코인으로 구매해 추가.
///   - **인스턴스(FurniturePlacement)**: 길드가 보유한 가구 1점 — kind·좌표·(액자)문구.
///     서버 `guilds.office_furniture`에 "kind:x:lane[:text]" 직렬화로 저장.
///
/// 충돌·통행 모델 (2D 자유 이동): 펫은 `petWalkArea` 안을 상하좌우대각 자유 이동하며
/// A* 최단경로로 avoid 밴드를 우회한다. `PetPassing` 4분류 —
///   `.avoid`   피해감: 발밑 전 구간 충돌 (커피머신 등)
///   `.front`   앞으로만: 뒤쪽 밴드 충돌 + 펫이 항상 위에 그려짐 (책장/소파/벤치)
///   `.behind`  뒤로만: 앞쪽 밴드 충돌 + 가구가 펫을 가림 (화분)
///   `.through` 앞뒤 모두: 비충돌, baseline 기준 painter 겹침 (데스크/서버랙/스탠딩)
/// 벽 가구(lane 3)는 펫 동선 밖. 겹침은 `placementCollides` — 단 canStack 가구는
/// isSurface 가구(데스크류) 위에 올려놓기 허용 (컵/커피머신을 책상 위에).
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

    // MARK: - 가구 카탈로그 (기본 5점 + 코인 구매 — 사용자 요청)

    /// 에셋 공백 — CC0 팩에 없어 코드로 그린다 (research/office-assets.md 검증 결과).
    /// 액자는 supportsText 플래그로 `TextFrameView`가 문구와 함께 렌더.
    enum DrawKind { case serverRack, standingDesk, window }

    /// 펫-가구 통행 특성 (사용자 요청 — 가구별 파라미터):
    /// avoid = 피해감, front = 앞으로만 지나감, behind = 뒤로만 지나감, through = 앞뒤 모두.
    /// front/behind는 반대쪽 밴드에 충돌을 둬 "그쪽으로만" 지나가게 강제한다.
    enum PetPassing { case avoid, front, behind, through }

    enum FurnitureMount { case floor, wall }

    /// 구매 가능한 가구 종류. id = 직렬화의 kind (서버 검증과 쌍 — 순서 재배열 금지).
    struct FurnitureKind: Identifiable {
        let id: Int
        let name: String
        let price: Int               // 코인. 기본 제공분과 무관하게 추가 구매 가능
        let mount: FurnitureMount    // wall = 벽 전용 (lane 3, 시계/액자/화이트보드)
        let passing: PetPassing
        let imageName: String?       // nil = drawKind 또는 supportsText 코드 드로잉
        let drawKind: DrawKind?
        let size: CGSize
        let blockingWidth: CGFloat   // 충돌 밴드 폭 (avoid/front/behind)
        let hasPC: Bool              // 데스크 — 근처 자리 점유자 working 시 PC ON 애니
        let isSurface: Bool          // 위에 canStack 가구를 올릴 수 있음 (데스크류)
        let surfaceInsetY: CGFloat   // 상판 높이 — 올려진 가구의 baseline 올림량
        let canStack: Bool           // isSurface 가구 위 배치 가능 (커피머신 등 탁상 소품)
        let supportsText: Bool       // 액자 — 10자 문구 (FurniturePlacement.text)
        /// 아트 셀 하단의 투명 여백(px) — 렌더 시 이만큼 내려 그려 "떠 보임"을 없앤다
        /// (에셋 alpha 실측: PC 9, 책장 8, 커피머신 9, 화이트보드 8, 벽시계 11 등).
        let artBottomInset: CGFloat

        init(id: Int, name: String, price: Int, mount: FurnitureMount, passing: PetPassing,
             imageName: String? = nil, drawKind: DrawKind? = nil,
             size: CGSize, blockingWidth: CGFloat,
             hasPC: Bool = false, isSurface: Bool = false, surfaceInsetY: CGFloat = 0,
             canStack: Bool = false, supportsText: Bool = false, artBottomInset: CGFloat = 0) {
            self.id = id; self.name = name; self.price = price; self.mount = mount
            self.passing = passing; self.imageName = imageName; self.drawKind = drawKind
            self.size = size; self.blockingWidth = blockingWidth; self.hasPC = hasPC
            self.isSurface = isSurface; self.surfaceInsetY = surfaceInsetY
            self.canStack = canStack; self.supportsText = supportsText
            self.artBottomInset = artBottomInset
        }
    }

    static let furnitureCatalog: [FurnitureKind] = [
        FurnitureKind(id: 0, name: "데스크+PC", price: 1_500, mount: .floor, passing: .through,
                      imageName: "DESK_FRONT",
                      size: CGSize(width: 48, height: 32), blockingWidth: 40,
                      hasPC: true, isSurface: true, surfaceInsetY: 8),
        FurnitureKind(id: 1, name: "책장", price: 1_000, mount: .floor, passing: .front,
                      imageName: "DOUBLE_BOOKSHELF",
                      size: CGSize(width: 32, height: 32), blockingWidth: 28,
                      artBottomInset: 8),
        FurnitureKind(id: 2, name: "서버랙", price: 1_200, mount: .floor, passing: .through,
                      drawKind: .serverRack,
                      size: CGSize(width: 20, height: 36), blockingWidth: 18),
        FurnitureKind(id: 3, name: "커피머신", price: 800, mount: .floor, passing: .avoid,
                      imageName: "COFFEE",
                      size: CGSize(width: 16, height: 16), blockingWidth: 12,
                      canStack: true, artBottomInset: 9),
        FurnitureKind(id: 4, name: "소파", price: 1_000, mount: .floor, passing: .front,
                      imageName: "SOFA_FRONT",
                      size: CGSize(width: 32, height: 16), blockingWidth: 28),
        FurnitureKind(id: 5, name: "벤치", price: 500, mount: .floor, passing: .front,
                      imageName: "CUSHIONED_BENCH",
                      size: CGSize(width: 16, height: 16), blockingWidth: 14),
        FurnitureKind(id: 6, name: "화분", price: 500, mount: .floor, passing: .behind,
                      imageName: "LARGE_PLANT",
                      size: CGSize(width: 32, height: 48), blockingWidth: 16,
                      artBottomInset: 1),
        FurnitureKind(id: 7, name: "스탠딩 데스크", price: 800, mount: .floor, passing: .through,
                      drawKind: .standingDesk,
                      size: CGSize(width: 28, height: 26), blockingWidth: 24,
                      isSurface: true, surfaceInsetY: 19),
        FurnitureKind(id: 8, name: "벽시계", price: 500, mount: .wall, passing: .through,
                      imageName: "CLOCK",
                      size: CGSize(width: 16, height: 32), blockingWidth: 14,
                      artBottomInset: 11),
        FurnitureKind(id: 9, name: "액자", price: 800, mount: .wall, passing: .through,
                      size: CGSize(width: 30, height: 22), blockingWidth: 28,
                      supportsText: true),
        FurnitureKind(id: 10, name: "화이트보드", price: 800, mount: .wall, passing: .through,
                      imageName: "WHITEBOARD",
                      size: CGSize(width: 32, height: 32), blockingWidth: 30,
                      artBottomInset: 8),
    ]

    static func furnitureKind(id: Int) -> FurnitureKind? {
        furnitureCatalog.indices.contains(id) ? furnitureCatalog[id] : nil
    }

    /// 벽 가구의 직렬화 lane 값 + 벽 baseline (벽 밴드 하단 근처).
    static let wallLane = 3
    static let wallFurnitureBaselineY: CGFloat = 52
    /// 액자 문구 최대 길이 (서버 FURNITURE_TEXT_MAX와 쌍).
    static let furnitureTextMax = 10
    /// 보유 인스턴스 상한 (서버 FURNITURE_MAX_INSTANCES와 쌍).
    static let furnitureMaxInstances = 30

    // MARK: - 가구 인스턴스 (보유분 — 드래그 자유 배치 + 구매로 추가)

    /// 길드가 보유한 가구 1점. uid = 직렬화 순서 인덱스 (추가는 append라 세션 내 안정).
    struct FurniturePlacement: Equatable, Identifiable {
        let uid: Int
        let kind: Int                // furnitureCatalog id
        var x: CGFloat
        var lane: Int                // 0..2 바닥 레인, 3 = 벽(wallLane)
        var text: String?            // 액자 문구 (supportsText 전용)
        /// 벽 가구의 자유 baseline y (벽 밴드 안). 바닥 가구는 nil (레인에서 유도).
        var wallY: CGFloat? = nil
        var id: Int { uid }
    }

    /// 기본 제공 가구 — 데스크+PC ×4 (뒷레인) + 책장 ×1. office_furniture가 비면 이 배치.
    static let defaultPlacements: [FurniturePlacement] = [
        FurniturePlacement(uid: 0, kind: 0, x: 35, lane: 0, text: nil),
        FurniturePlacement(uid: 1, kind: 0, x: 105, lane: 0, text: nil),
        FurniturePlacement(uid: 2, kind: 0, x: 175, lane: 0, text: nil),
        FurniturePlacement(uid: 3, kind: 0, x: 245, lane: 0, text: nil),
        FurniturePlacement(uid: 4, kind: 1, x: 250, lane: 1, text: nil),
    ]

    /// 서버 직렬화("kind:x:lane[:y[:text]];…") 파싱 — 형식/범위 위반 항목은 버리고, 전부
    /// 무효거나 빈 값이면 기본 배치 폴백. 벽 가구는 4번째 필드 y(자유 배치), 액자는 5번째 text.
    /// (레거시 4필드 "kind:x:3:text"는 y가 숫자가 아니면 text로 폴백 해석.)
    static func sanitizedPlacements(_ raw: String?) -> [FurniturePlacement] {
        guard let raw, !raw.isEmpty else { return defaultPlacements }
        var out: [FurniturePlacement] = []
        for entry in raw.split(separator: ";").prefix(furnitureMaxInstances) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard (3...5).contains(parts.count),
                  let kindId = Int(parts[0]), let kind = furnitureKind(id: kindId),
                  let x = Double(parts[1]), (0...Double(sceneSize.width)).contains(x),
                  let lane = Int(parts[2]),
                  kind.mount == .wall ? lane == wallLane : (0...2).contains(lane)
            else { continue }
            let isWall = lane == wallLane
            var wallY: CGFloat?
            var textField: Substring?
            if parts.count == 5 {
                if isWall, let y = Double(parts[3]) { wallY = clampWallY(CGFloat(y), for: kind) }
                textField = parts[4]
            } else if parts.count == 4 {
                if isWall, let y = Double(parts[3]) {
                    wallY = clampWallY(CGFloat(y), for: kind)      // 벽 y (신형)
                } else {
                    textField = parts[3]                            // 레거시 4필드 text 폴백
                }
            }
            var text: String?
            if let textField, kind.supportsText {
                let decoded = String(textField).removingPercentEncoding ?? ""
                if !decoded.isEmpty { text = String(decoded.prefix(furnitureTextMax)) }
            }
            out.append(FurniturePlacement(uid: out.count, kind: kindId,
                                          x: CGFloat(x), lane: lane, text: text, wallY: wallY))
        }
        return out.isEmpty ? defaultPlacements : out
    }

    /// 서버 전송용 직렬화 — "kind:x:lane[:y[:text]]". 벽 가구는 y 필드(소수 1자리)를 항상
    /// 포함하고, 액자 문구는 그 뒤 percent-encoding (':'/';' 충돌 방지). 바닥은 3필드.
    static func serializePlacements(_ placements: [FurniturePlacement]) -> String {
        placements.map { p in
            var s = String(format: "%d:%.1f:%d", p.kind, p.x, p.lane)
            let isWall = p.lane == wallLane
            if isWall {
                let y = p.wallY ?? wallFurnitureBaselineY
                s += String(format: ":%.1f", y)
            }
            if let text = p.text, !text.isEmpty,
               let enc = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                // 문구는 항상 y 필드 뒤 — 액자는 벽 가구라 y가 이미 붙어 있다.
                s += ":\(enc)"
            }
            return s
        }.joined(separator: ";")
    }

    /// 벽 baseline y 클램프 — 아이템이 벽 밴드(0..wallBottom) 안에 온전히 들어오게.
    /// baseline = 아이템 하단이므로 상단(baseline-h)≥0, 하단(baseline)≤wallBottom.
    static func clampWallY(_ y: CGFloat, for kind: FurnitureKind) -> CGFloat {
        let h = kind.size.height
        return min(max(y, min(h, wallBottom)), wallBottom)
    }

    /// 드롭 시 클램프 — 벽 가구는 벽 밴드(lane 3) 안에서 x·y 자유, 바닥은 가장 가까운 레인 스냅.
    /// dragY = 커서의 논리 y (벽 가구는 아이템 중심이 이를 따르도록 baseline으로 환산).
    static func clampPlacement(kind kindId: Int, x: CGFloat,
                               dragY: CGFloat) -> (x: CGFloat, lane: Int, wallY: CGFloat?) {
        let cx = min(max(x, edgeMargin), sceneSize.width - edgeMargin)
        guard let kind = furnitureKind(id: kindId) else { return (cx, 2, nil) }
        if kind.mount == .wall {
            // 커서 = 아이템 중심 → baseline = 중심 + h/2. 벽 밴드로 클램프.
            return (cx, wallLane, clampWallY(dragY + kind.size.height / 2, for: kind))
        }
        let lane = lanes.enumerated().min { abs($0.element - dragY) < abs($1.element - dragY) }?.offset ?? 2
        return (cx, lane, nil)
    }

    /// 드래그/구매 배치 겹침 검사 — 같은 구역에서 시각 폭이 겹치면 true. 벽 가구는 x·y 둘 다
    /// 겹칠 때만 (자유 배치라 높이가 다르면 나란히 허용). 예외: canStack ↔ isSurface는 겹침 허용.
    static func placementCollides(uid: Int, kind kindId: Int, x: CGFloat, lane: Int,
                                  wallY: CGFloat? = nil,
                                  others: [FurniturePlacement]) -> Bool {
        guard let kind = furnitureKind(id: kindId) else { return false }
        let myY = wallY ?? wallFurnitureBaselineY
        return others.contains { p in
            guard p.uid != uid, p.lane == lane,
                  let other = furnitureKind(id: p.kind) else { return false }
            if (kind.canStack && other.isSurface) || (kind.isSurface && other.canStack) {
                return false
            }
            let xOverlap = abs(x - p.x) < (kind.size.width + other.size.width) / 2
            if lane == wallLane {
                let otherY = p.wallY ?? wallFurnitureBaselineY
                let yOverlap = abs(myY - otherY) < (kind.size.height + other.size.height) / 2
                return xOverlap && yOverlap
            }
            return xOverlap
        }
    }

    /// canStack 가구가 올라앉은 표면 가구 — 같은 레인에서 표면 폭 안에 있으면 마운트.
    static func mountedSurface(of placement: FurniturePlacement,
                               in placements: [FurniturePlacement]) -> FurniturePlacement? {
        guard let kind = furnitureKind(id: placement.kind), kind.canStack,
              placement.lane != wallLane else { return nil }
        return placements
            .filter { p in
                guard p.uid != placement.uid, p.lane == placement.lane,
                      let surface = furnitureKind(id: p.kind), surface.isSurface else { return false }
                return abs(p.x - placement.x) < surface.size.width / 2
            }
            .min { abs($0.x - placement.x) < abs($1.x - placement.x) }
    }

    /// 인스턴스의 렌더 baseline y — 벽 가구는 자유 y(없으면 기본), 마운트된 소품은 상판 위로 올림.
    static func baselineY(for placement: FurniturePlacement,
                          in placements: [FurniturePlacement]) -> CGFloat {
        if placement.lane == wallLane { return placement.wallY ?? wallFurnitureBaselineY }
        var y = lanes[min(max(placement.lane, 0), 2)]
        if let surface = mountedSurface(of: placement, in: placements),
           let surfaceKind = furnitureKind(id: surface.kind) {
            y -= surfaceKind.surfaceInsetY
        }
        return y
    }

    // MARK: - 벽 장식 (붙박이 — 재배치 무관)

    struct WallDecor {
        let imageName: String?
        let drawKind: DrawKind?
        let size: CGSize
        let anchorX: CGFloat
        let baselineY: CGFloat
    }

    /// 붙박이는 창문만 — 시계/화이트보드는 벽 가구 카탈로그로 이동 (구매·자유 배치).
    static let wallDecor: [WallDecor] = [
        WallDecor(imageName: nil, drawKind: .window,
                  size: CGSize(width: 26, height: 20), anchorX: 35, baselineY: 46),
    ]

    /// 데스크 위 PC 배치 — (deskX, 데스크 상판 y). 상판 "모서리 걸침"은 떠 보인다는
    /// 피드백으로 상판 면 안쪽 깊숙이(가시 하단 = 상판 상단 -9px) 내려 앉힘 — 합성 검증.
    /// (PC 아트 하단 투명 9px 포함해 frame bottom = baseline + 1 — 추가 하향 피드백 반영.)
    static let pcSize = CGSize(width: 16, height: 32)
    static func pcBaselineY(deskBaselineY: CGFloat) -> CGFloat { deskBaselineY + 1 }

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

    /// 통행 특성별 충돌 밴드 — baseline 주변 낮은 띠, 펫 "발" 기준 판정 (몸통 겹침 허용).
    /// avoid = 전 구간(피해감), front = 뒤쪽 밴드(앞으로만 지나가게), behind = 앞쪽 밴드
    /// (뒤로만), through/벽/마운트된 소품 = 없음.
    private static func passingBand(passing: PetPassing, x: CGFloat, baselineY: CGFloat,
                                    width: CGFloat) -> CGRect? {
        switch passing {
        case .through: return nil
        case .avoid:  return CGRect(x: x - width / 2, y: baselineY - 10, width: width, height: 14)
        case .front:  return CGRect(x: x - width / 2, y: baselineY - 10, width: width, height: 8)
        case .behind: return CGRect(x: x - width / 2, y: baselineY - 2, width: width, height: 8)
        }
    }

    /// 가구·바닥 데코의 충돌 사각형 목록 — 펫 A* 경로탐색이 우회할 영역.
    static func collisionRects(placements: [FurniturePlacement],
                               decor: [(slotId: Int, kind: String)]) -> [CGRect] {
        var rects: [CGRect] = []
        for p in placements {
            guard p.lane != wallLane, let kind = furnitureKind(id: p.kind),
                  mountedSurface(of: p, in: placements) == nil,
                  let band = passingBand(passing: kind.passing, x: p.x,
                                         baselineY: lanes[min(max(p.lane, 0), 2)],
                                         width: kind.blockingWidth) else { continue }
            rects.append(band)
        }
        for entry in decor {
            guard let slot = decorSlot(id: entry.slotId), slot.category == .floor,
                  let item = decorItem(kind: entry.kind),
                  let band = passingBand(passing: item.passing, x: slot.anchorX,
                                         baselineY: slot.baselineY,
                                         width: item.blockingWidth) else { continue }
            rects.append(band)
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
