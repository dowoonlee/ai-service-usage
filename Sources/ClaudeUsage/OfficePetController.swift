import Foundation
import SwiftUI

/// 길드 사무실 펫 시뮬레이션 — 배치된 멤버 대표 펫들의 행동 상태 기계 (docs/plans/guild.md §5-2).
///
/// `WalkingCat`의 `PetController`는 차트(plotFrame/points)에 강결합이라 재사용하지 않고,
/// 사무실 전용으로 가볍게 다시 만든다. 스프라이트 프레임·이로치 색조·이펙트 렌더는
/// 기존 `PetSprite`/`PetEffectOverlay` 경로를 뷰에서 그대로 쓴다.
///
/// 행동 FSM (모드별):
///   normal   — idle(2~8s) ↔ **바닥 전체에서 랜덤 지점**을 뽑아 A* 최단경로로 이동
///              (상하좌우대각 8방향) + 낮은 확률로 커피머신 방문(동시 1마리 — P2a 고도화)
///   working  — 상위 5명(점수 기여자): 대부분 자리 고정(.scan "작업" 모션), 자리 근처만 wander.
///              데스크 PC ON 연동은 뷰가 처리.
///   sleeping — 월 VP 0: 완전 고정 + 💤. 스침 인사에도 무반응.
///   greeting — 두 펫이 근접 교차하는 순간 ~10% 확률로 1.5s 멈춤 + 인사 말풍선.
///   special  — Mythic 전용: idle 중 낮은 확률로 특수 모션(Attack/Heal 등) + 전용 대사.
///
/// 경로탐색: `OfficeLayout.collisionRects`(통행 특성별 충돌 밴드)를 4px 셀 그리드로 이산화한
/// `OfficePathGrid`에서 A*(8방향, 대각선은 모서리 끼임 방지 조건부)로 최단경로를 뽑고,
/// waypoint를 따라 등속 이동한다. front/behind의 앞뒤 통과 연출은 뷰의 zIndex가 담당.
@MainActor
final class OfficeSimulation: ObservableObject {

    struct PetState: Identifiable {
        enum Mode { case normal, working, sleeping }
        enum Phase {
            case idle(until: TimeInterval)
            /// A* waypoint 경로 추종 — step = 현재 향하는 waypoint 인덱스.
            case walking(path: [CGPoint], step: Int)
            case greeting(until: TimeInterval)
            /// 공용 지점(커피머신) 방문 경로 — returning이면 자기 스팟 복귀 중.
            case visiting(path: [CGPoint], step: Int, returning: Bool)
            /// 커피머신 앞 한 모금 — 멈춰서 ☕.
            case drinking(until: TimeInterval)
            /// Mythic 특수 모션 재생 중.
            case special(until: TimeInterval)
        }

        let id: String                 // nickname (길드 내 유니크)
        let kind: PetKind
        let variant: Int
        let equippedEffects: Set<EffectKind>
        let spot: OfficeLayout.Spot
        /// 산책의 중심점 — 자리 anchor. 2D wander 목표는 이 점 중심 반경에서 뽑는다.
        let home: CGPoint
        let mode: Mode
        let monthlyVP: Int
        let isMe: Bool

        var x: CGFloat
        /// 현재 발(baseline) y — 2D 이동이라 상시 변한다.
        var y: CGFloat
        var facingRight: Bool = true
        var phase: Phase = .idle(until: 0)
        var bubble: String?
        var bubbleUntil: TimeInterval = 0
        /// Mythic 특수 모션 종류 — special phase에서 뷰가 이 액션의 프레임을 재생.
        var specialAction: PetController.Action = .special1

        var isWalking: Bool {
            switch phase {
            case .walking, .visiting: return true
            default: return false
            }
        }

        /// 뷰가 재생할 스프라이트 액션 — phase·mode에서 유도.
        var displayAction: PetController.Action {
            switch phase {
            case .walking, .visiting: return .walk
            case .special: return specialAction
            case .drinking, .greeting: return .sit
            case .idle:
                // working은 자리에서 "작업 중" 모션(.scan) — PC ON과 함께 캐리 중임이 읽히게.
                return mode == .working ? .scan : .sit
            }
        }
    }

    @Published private(set) var pets: [PetState] = []

    private var timer: Timer?
    /// 통행 특성별 충돌 밴드를 이산화한 보행 그리드 — 가구 재배치(layout)마다 재구축.
    private var grid: OfficePathGrid?
    /// 커피머신(가구 세트)이 놓인 포지션 옆의 방문 지점 — 재배치(layout)에 따라 이동한다.
    private var coffeePoint: CGPoint?
    /// 동시 방문 1마리 제한 — 커피머신 앞 정체 방지.
    private var visitingPetID: String?
    /// 인사 스팸 방지 — pair key("a|b") → 다음 허용 시각.
    private var greetCooldown: [String: TimeInterval] = [:]
    private var configuredKey: String = ""

#if DEBUG
    /// 데모 전용 — 확률 이벤트(방문/특수 모션)를 가속해 스크린샷 검증을 가능하게 한다.
    static var debugAccelerate = false
#endif

    /// 이동 속도 (논리 px/s) — WalkingCat 산책 감각에 맞춤. 방문은 약간 빠릿하게.
    private static let walkSpeed: CGFloat = 14
    private static let visitSpeed: CGFloat = 20
    private static let greetDuration: TimeInterval = 1.5
    private static let greetChance = 0.10
    private static let greetCooldownSec: TimeInterval = 30
    private static let drinkDuration: TimeInterval = 3.0
    private static let specialDuration: TimeInterval = 1.6

    // MARK: - 대사 (P2a 확충 — WalkingCat의 Quotes와 별개인 사무실 상황극)

    private static let officeQuotes = [
        "빌드 기다리는 중…", "커피 리필 각", "머지 좀 봐주세요", "오늘도 평화로운 prod",
        "회의가 이길까 코딩이 이길까", "on-call 아님 (아마)", "LGTM?", "스탠드업 3분 전",
        "npm install 하는 중", "PR 리뷰 기다리는 중", "금요일 배포는 용기", "오늘 목표: 커밋 1개",
        "내 컴에서는 됐는데", "회의록은 나중에", "429 났다, 잠깐 쉬자", "커서 깜빡이는 거 구경 중",
    ]
    /// working(상위 5명) 전용 — 캐리 중인 자의 품격.
    private static let workingQuotes = [
        "컴파일 중…", "집중 모드 🔥", "딥 워크 중 — 말 걸지 마세요", "리팩토링이 끝나지 않아",
        "이번 달은 내가 캐리한다", "테스트 다 초록불 보고 잘 거야",
    ]
    private static let drinkQuotes = ["☕", "커피가 코드를 만든다", "한 모금만…"]
    private static let greetLines = ["👋", "커피?", "머지 축하", "오늘도 화이팅"]

    deinit {
        timer?.invalidate()
    }

    /// 멤버 목록 + 자동 배치(assignments: nickname → 포지션 id) + 가구 배치 → 펫 상태 구성.
    /// 같은 구성이면 재구성하지 않아 5분 새로고침마다 펫이 순간이동하는 것을 막는다.
    /// layout이 바뀌면(가구 재배치) 산책 범위·커피머신 위치가 달라지므로 재구성 대상.
    func configure(members: [RankingAPI.GuildMember],
                   assignments: [String: Int],
                   placements: [OfficeLayout.FurniturePlacement],
                   decor: [(slotId: Int, kind: String)] = []) {
        let key = members.map {
            "\($0.nickname):\(assignments[$0.nickname] ?? -1):\($0.isTopContributor):\($0.monthlyVP > 0)"
        }.sorted().joined(separator: ",")
            + "|furniture:" + OfficeLayout.serializePlacements(placements)
            + "|decor:" + decor.map { "\($0.slotId):\($0.kind)" }.sorted().joined(separator: ",")
        guard key != configuredKey else { return }
        configuredKey = key

        pets = members.compactMap { member in
            guard let spot = OfficeLayout.spot(id: assignments[member.nickname]) else { return nil }
            let avatar = member.profileJson?.card.avatar
            let mode: PetState.Mode = member.monthlyVP <= 0 ? .sleeping
                : (member.isTopContributor ? .working : .normal)
            let home = CGPoint(x: spot.anchorX, y: OfficeLayout.lanes[spot.lane])
            return PetState(
                id: member.nickname,
                kind: avatar?.kind ?? .fox,
                variant: avatar?.variant ?? 0,
                equippedEffects: Set((member.profileJson?.equippedEffects ?? [])
                    .compactMap { EffectKind(rawValue: $0) }),
                spot: spot,
                home: home,
                mode: mode,
                monthlyVP: member.monthlyVP,
                isMe: member.isMe,
                x: home.x,
                y: home.y
            )
        }
        // 통행 특성별 충돌 밴드 → A* 보행 그리드 (기획 §2/§5-2).
        grid = OfficePathGrid(
            blockedRects: OfficeLayout.collisionRects(placements: placements, decor: decor))
        // 커피머신 방문 지점 — 커피머신이 놓인 레인 바닥, 기계 오른쪽 옆 (정면을 비워둔다).
        // 책상 위에 올려진 커피머신도 방문 지점은 그 레인의 바닥이다.
        coffeePoint = placements
            .first { OfficeLayout.furnitureKind(id: $0.kind)?.name == "커피머신"
                     && $0.lane != OfficeLayout.wallLane }
            .map { CGPoint(x: min($0.x + 12, OfficeLayout.sceneSize.width - OfficeLayout.edgeMargin),
                           y: OfficeLayout.lanes[min(max($0.lane, 0), 2)]) }
        visitingPetID = nil
        greetCooldown = [:]

        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startTimerIfNeeded() {
        guard timer == nil, !pets.isEmpty else { return }
        // WalkingCat과 동일 — Timer block 안 MainActor.assumeIsolated는 macOS 26에서 SIGSEGV
        // (issue #16 계열). DispatchQueue.main으로 명시적 hop.
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var accel: Bool {
#if DEBUG
        return Self.debugAccelerate
#else
        return false
#endif
    }

    private func tick() {
        guard !pets.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        let dt: CGFloat = 1.0 / 30
        var updated = pets

        for i in updated.indices {
            var pet = updated[i]

            // 말풍선 만료.
            if pet.bubble != nil && now > pet.bubbleUntil { pet.bubble = nil }

            switch pet.mode {
            case .sleeping:
                // 완전 고정 — 주기적 💤 만.
                if pet.bubble == nil && Double.random(in: 0..<1) < 0.002 {
                    pet.bubble = "💤"
                    pet.bubbleUntil = now + 3
                }

            case .working, .normal:
                switch pet.phase {
                case .idle(let until):
                    if now >= until {
                        decideNextAction(&pet, now: now)
                    }
                case .walking(let path, var step):
                    if advance(&pet, along: path, step: &step, speed: Self.walkSpeed, dt: dt) {
                        pet.phase = .idle(until: now + Double.random(in: 2...8))
                    } else {
                        pet.phase = .walking(path: path, step: step)
                    }
                case .greeting(let until):
                    if now >= until {
                        pet.phase = .idle(until: now + Double.random(in: 1...4))
                    }
                case .visiting(let path, var step, let returning):
                    if advance(&pet, along: path, step: &step, speed: Self.visitSpeed, dt: dt) {
                        if returning {
                            pet.phase = .idle(until: now + Double.random(in: 2...8))
                            if visitingPetID == pet.id { visitingPetID = nil }
                        } else {
                            pet.phase = .drinking(until: now + Self.drinkDuration)
                            pet.bubble = Self.drinkQuotes.randomElement()
                            pet.bubbleUntil = now + Self.drinkDuration
                        }
                    } else {
                        pet.phase = .visiting(path: path, step: step, returning: returning)
                    }
                case .drinking(let until):
                    if now >= until {
                        let back = grid?.path(from: CGPoint(x: pet.x, y: pet.y), to: pet.home)
                            ?? [pet.home]
                        pet.phase = .visiting(path: back, step: 0, returning: true)
                        pet.facingRight = pet.home.x > pet.x
                    }
                case .special(let until):
                    if now >= until {
                        pet.phase = .idle(until: now + Double.random(in: 2...8))
                    }
                }
            }
            updated[i] = pet
        }

        // 스침 인사 — 둘 다 산책(walking) 중 근접 교차 (2D 거리 기준).
        // 펫끼리는 비충돌(통과)이므로 하드 블록 없이 연출만 (기획 §5-2 충돌 모델).
        for i in updated.indices {
            guard case .walking = updated[i].phase, updated[i].mode != .sleeping else { continue }
            for j in updated.indices where j > i {
                guard case .walking = updated[j].phase, updated[j].mode != .sleeping,
                      hypot(updated[i].x - updated[j].x, updated[i].y - updated[j].y) < 7 else { continue }
                let pairKey = [updated[i].id, updated[j].id].sorted().joined(separator: "|")
                if let until = greetCooldown[pairKey], now < until { continue }
                greetCooldown[pairKey] = now + Self.greetCooldownSec
                guard Double.random(in: 0..<1) < Self.greetChance else { continue }
                let line = Self.greetLines.randomElement() ?? "👋"
                for k in [i, j] {
                    updated[k].phase = .greeting(until: now + Self.greetDuration)
                    updated[k].bubble = line
                    updated[k].bubbleUntil = now + Self.greetDuration + 0.5
                }
                // 서로 마주보게.
                updated[i].facingRight = updated[j].x > updated[i].x
                updated[j].facingRight = updated[i].x > updated[j].x
            }
        }

        pets = updated
    }

    /// idle 만료 시 다음 행동 결정 — 모드별 성향 (P2a 고도화의 중심 분기).
    private func decideNextAction(_ pet: inout PetState, now: TimeInterval) {
        // Mythic 특수 모션 — idle 사이 낮은 확률, 전용 대사 동반 (WalkingCat의 special 연출 미러).
        if let spec = Mythic.spec(for: pet.kind), !spec.specials.isEmpty,
           Double.random(in: 0..<1) < (accel ? 0.6 : 0.06) {
            let action = spec.specials.keys.randomElement() ?? .special1
            pet.specialAction = action
            pet.phase = .special(until: now + Self.specialDuration)
            if let quote = spec.moveQuotes[action]?.randomElement() {
                pet.bubble = quote
                pet.bubbleUntil = now + Self.specialDuration + 1
            }
            return
        }

        // 커피머신 방문 — normal 위주, 동시 1마리. working은 자리를 오래 못 비우니 드물게.
        let visitChance = accel ? 0.9 : (pet.mode == .working ? 0.03 : 0.10)
        if let coffee = coffeePoint, visitingPetID == nil,
           // 커피머신 옆이 자기 자리인 펫은 방문이 무의미.
           hypot(pet.home.x - coffee.x, pet.home.y - coffee.y) > 20,
           Double.random(in: 0..<1) < visitChance,
           let path = grid?.path(from: CGPoint(x: pet.x, y: pet.y), to: coffee) {
            visitingPetID = pet.id
            pet.phase = .visiting(path: path, step: 0, returning: false)
            pet.facingRight = coffee.x > pet.x
            return
        }

        // 산책 vs 제자리 — working은 자리 지킴 성향 + 자리 근처만, normal은 바닥 전체 랜덤.
        let wanderChance = pet.mode == .working ? 0.25 : 0.6
        if Double.random(in: 0..<1) < wanderChance,
           let target = wanderTarget(for: pet),
           let path = grid?.path(from: CGPoint(x: pet.x, y: pet.y), to: target) {
            pet.phase = .walking(path: path, step: 0)
            pet.facingRight = target.x > pet.x
        } else {
            pet.phase = .idle(until: now + Double.random(in: 2...8))
            // idle 시작 시 낮은 확률로 상황극 한마디 — working은 전용 대사 위주로 섞는다.
            if pet.bubble == nil && Double.random(in: 0..<1) < 0.08 {
                let pool = pet.mode == .working
                    ? (Bool.random() ? Self.workingQuotes : Self.officeQuotes)
                    : Self.officeQuotes
                pet.bubble = pool.randomElement()
                pet.bubbleUntil = now + 4
            }
        }
    }

    /// 산책 목표 — "현재 위치에서 랜덤한 다른 위치" (사용자 요청). normal은 바닥 전체의
    /// 자유 셀에서 균등 추첨(현재 위치 근처는 제외해 제자리걸음 방지), working은 자리 근처만.
    private func wanderTarget(for pet: PetState) -> CGPoint? {
        guard let grid else { return nil }
        let current = CGPoint(x: pet.x, y: pet.y)
        if pet.mode == .working {
            return grid.randomFreePoint(near: pet.home, radius: 22, awayFrom: current, minDist: 6)
        }
        return grid.randomFreePoint(awayFrom: current, minDist: 20)
    }

    /// waypoint 경로 추종 — 현재 waypoint에 닿으면 다음으로. 반환 true = 경로 끝 도착.
    private func advance(_ pet: inout PetState, along path: [CGPoint], step: inout Int,
                         speed: CGFloat, dt: CGFloat) -> Bool {
        guard step < path.count else { return true }
        let target = path[step]
        let dx = target.x - pet.x
        let dy = target.y - pet.y
        let dist = hypot(dx, dy)
        if dist < 0.9 {
            step += 1
            return step >= path.count
        }
        let move = min(speed * dt, dist)
        pet.x += dx / dist * move
        pet.y += dy / dist * move
        if abs(dx) > 0.5 { pet.facingRight = dx > 0 }
        return false
    }
}

// MARK: - 보행 그리드 + A* (petWalkArea 4px 셀 이산화)

/// 가구 충돌 밴드를 피해 다니는 최단경로 탐색. 셀 수 ~66×18 = 1,200이라 배열 스캔
/// A*로 충분하다 (호출 빈도도 펫당 산책 결정 시 1회).
struct OfficePathGrid {
    static let cellSize: CGFloat = 4
    let cols: Int
    let rows: Int
    private let origin: CGPoint
    private var blockedCells: [Bool]
    private var freeCellIndices: [Int] = []

    init(blockedRects: [CGRect]) {
        let area = OfficeLayout.petWalkArea
        origin = CGPoint(x: area.minX, y: area.minY)
        cols = max(1, Int(area.width / Self.cellSize))
        rows = max(1, Int(area.height / Self.cellSize))
        blockedCells = Array(repeating: false, count: cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let p = center(c, r)
                // 살짝 팽창(-1 inset) — 셀 경계에 걸친 밴드도 막아 스침 침범 방지.
                if blockedRects.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) {
                    blockedCells[r * cols + c] = true
                }
            }
        }
        freeCellIndices = blockedCells.indices.filter { !blockedCells[$0] }
    }

    func center(_ c: Int, _ r: Int) -> CGPoint {
        CGPoint(x: origin.x + (CGFloat(c) + 0.5) * Self.cellSize,
                y: origin.y + (CGFloat(r) + 0.5) * Self.cellSize)
    }

    private func cell(of p: CGPoint) -> (c: Int, r: Int) {
        (min(max(Int((p.x - origin.x) / Self.cellSize), 0), cols - 1),
         min(max(Int((p.y - origin.y) / Self.cellSize), 0), rows - 1))
    }

    private func isFree(_ c: Int, _ r: Int) -> Bool {
        c >= 0 && r >= 0 && c < cols && r < rows && !blockedCells[r * cols + c]
    }

    /// 막힌 지점 보정 — 주변 링을 넓혀가며 가장 가까운 자유 셀 (가구 위에 낀 시작점 탈출).
    private func nearestFree(to p: CGPoint) -> (c: Int, r: Int)? {
        let (c0, r0) = cell(of: p)
        if isFree(c0, r0) { return (c0, r0) }
        for radius in 1...8 {
            var best: (c: Int, r: Int, d: CGFloat)?
            for dr in -radius...radius {
                for dc in -radius...radius where abs(dr) == radius || abs(dc) == radius {
                    let c = c0 + dc, r = r0 + dr
                    guard isFree(c, r) else { continue }
                    let q = center(c, r)
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if best == nil || d < best!.d { best = (c, r, d) }
                }
            }
            if let best { return (best.c, best.r) }
        }
        return nil
    }

    /// 자유 셀 랜덤 추첨 — near/radius로 반경 제한, awayFrom/minDist로 제자리 재추첨 방지.
    func randomFreePoint(near: CGPoint? = nil, radius: CGFloat = .infinity,
                         awayFrom: CGPoint? = nil, minDist: CGFloat = 0) -> CGPoint? {
        guard !freeCellIndices.isEmpty else { return nil }
        for _ in 0..<16 {
            guard let idx = freeCellIndices.randomElement() else { break }
            let p = center(idx % cols, idx / cols)
            if let near, hypot(p.x - near.x, p.y - near.y) > radius { continue }
            if let awayFrom, hypot(p.x - awayFrom.x, p.y - awayFrom.y) < minDist { continue }
            return p
        }
        return nil
    }

    /// A* 최단경로 — 8방향, 대각선은 양쪽 직교 셀이 모두 자유일 때만(모서리 끼임 방지).
    /// 반환 waypoint는 방향이 꺾이는 지점만 남긴 셀 중심 목록 (+ 마지막에 목표점).
    /// 시작·목표가 막혀 있으면 가장 가까운 자유 셀로 보정, 도달 불가면 nil.
    func path(from: CGPoint, to: CGPoint) -> [CGPoint]? {
        guard let s = nearestFree(to: from), let g = nearestFree(to: to) else { return nil }
        let start = s.r * cols + s.c
        let goal = g.r * cols + g.c
        if start == goal { return [center(g.c, g.r)] }

        var gScore = Array(repeating: CGFloat.infinity, count: cols * rows)
        var cameFrom = Array(repeating: -1, count: cols * rows)
        var closed = Array(repeating: false, count: cols * rows)
        var open: [(idx: Int, f: CGFloat)] = []
        func heuristic(_ idx: Int) -> CGFloat {
            let dc = abs(idx % cols - goal % cols), dr = abs(idx / cols - goal / cols)
            // octile 거리 — 대각 이동 비용 √2 반영.
            return CGFloat(max(dc, dr)) + 0.41421 * CGFloat(min(dc, dr))
        }
        gScore[start] = 0
        open.append((start, heuristic(start)))

        while !open.isEmpty {
            // 소규모 그리드 — min 스캔으로 충분 (힙 불필요).
            let minAt = open.indices.min { open[$0].f < open[$1].f }!
            let (current, _) = open.remove(at: minAt)
            if current == goal { break }
            if closed[current] { continue }
            closed[current] = true
            let c = current % cols, r = current / cols
            for dr in -1...1 {
                for dc in -1...1 where dr != 0 || dc != 0 {
                    let nc = c + dc, nr = r + dr
                    guard isFree(nc, nr) else { continue }
                    // 대각선 모서리 끼임 방지 — 양쪽 직교가 뚫려 있어야 통과.
                    if dr != 0 && dc != 0 && (!isFree(c + dc, r) || !isFree(c, r + dr)) { continue }
                    let next = nr * cols + nc
                    guard !closed[next] else { continue }
                    let cost: CGFloat = (dr != 0 && dc != 0) ? 1.41421 : 1
                    let tentative = gScore[current] + cost
                    if tentative < gScore[next] {
                        gScore[next] = tentative
                        cameFrom[next] = current
                        open.append((next, tentative + heuristic(next)))
                    }
                }
            }
        }
        guard cameFrom[goal] >= 0 || goal == start else { return nil }

        // 경로 복원 + 방향 전환점만 waypoint로 (collinear 병합).
        var cells: [Int] = [goal]
        var cursor = goal
        while cursor != start {
            cursor = cameFrom[cursor]
            guard cursor >= 0 else { return nil }
            cells.append(cursor)
        }
        cells.reverse()
        var waypoints: [CGPoint] = []
        for (i, idx) in cells.enumerated() {
            guard i > 0 else { continue }
            let prev = cells[i - 1]
            let dir = (idx % cols - prev % cols, idx / cols - prev / cols)
            if i + 1 < cells.count {
                let next = cells[i + 1]
                let nextDir = (next % cols - idx % cols, next / cols - idx / cols)
                if dir == nextDir { continue }   // 같은 방향 — 중간점 생략
            }
            waypoints.append(center(idx % cols, idx / cols))
        }
        if waypoints.isEmpty { waypoints = [center(g.c, g.r)] }
        return waypoints
    }
}
