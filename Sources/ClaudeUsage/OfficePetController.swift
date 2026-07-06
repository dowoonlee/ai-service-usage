import Foundation
import SwiftUI

/// 길드 사무실 펫 시뮬레이션 — 배치된 멤버 대표 펫들의 행동 상태 기계 (docs/plans/guild.md §5-2).
///
/// `WalkingCat`의 `PetController`는 차트(plotFrame/points)에 강결합이라 재사용하지 않고,
/// 사무실 전용으로 가볍게 다시 만든다. 스프라이트 프레임·이로치 색조·이펙트 렌더는
/// 기존 `PetSprite`/`PetEffectOverlay` 경로를 뷰에서 그대로 쓴다.
///
/// 행동 FSM (모드별):
///   normal   — idleAtSpot(2~8s) ↔ wanderNearSpot(스팟 ±40, walkable 클램프)
///              + 낮은 확률로 **커피머신 방문**(레인 간 2D 이동, 동시 1마리 — P2a 고도화)
///   working  — 상위 5명(점수 기여자): 대부분 자리 고정(.scan "작업" 모션), 낮은 빈도 wander.
///              데스크 PC ON 연동은 뷰가 처리.
///   sleeping — 월 VP 0: 완전 고정 + 💤. 스침 인사에도 무반응.
///   greeting — 같은 바닥선에서 두 펫이 교차하는 순간 ~10% 확률로 1.5s 멈춤 + 인사 말풍선.
///   special  — Mythic 전용: idle 중 낮은 확률로 특수 모션(Attack/Heal 등) + 전용 대사.
///
/// 레인 간 이동 중에는 가구 blocking을 적용하지 않는다 — 바닥은 자유 통행이고, 목적지가
/// 항상 가구 옆의 열린 지점이라 경로 검증 없이도 시각적으로 자연스럽다 (기획 §5-2).
@MainActor
final class OfficeSimulation: ObservableObject {

    struct PetState: Identifiable {
        enum Mode { case normal, working, sleeping }
        enum Phase {
            case idle(until: TimeInterval)
            case walking(target: CGFloat)
            case greeting(until: TimeInterval)
            /// 공용 지점(커피머신) 방문 — 2D 목표 지점으로 이동. returning이면 자기 스팟 복귀 중.
            case visiting(target: CGPoint, returning: Bool)
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
        let mode: Mode
        let monthlyVP: Int
        let isMe: Bool

        var x: CGFloat
        /// 현재 바닥선 y — 방문(레인 간 이동) 중에만 자기 레인에서 벗어난다.
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
    private var wanderRanges: [Int: ClosedRange<CGFloat>] = [:]
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
            return PetState(
                id: member.nickname,
                kind: avatar?.kind ?? .fox,
                variant: avatar?.variant ?? 0,
                equippedEffects: Set((member.profileJson?.equippedEffects ?? [])
                    .compactMap { EffectKind(rawValue: $0) }),
                spot: spot,
                mode: mode,
                monthlyVP: member.monthlyVP,
                isMe: member.isMe,
                x: spot.anchorX,
                y: OfficeLayout.lanes[spot.lane]
            )
        }
        // 바닥 데코도 blocking에 합류 (기획 §2 — 바닥 데코는 가구 충돌 모델을 따름).
        let decorBlocked = OfficeLayout.decorBlockedIntervals(placed: decor)
        wanderRanges = Dictionary(uniqueKeysWithValues:
            pets.map { ($0.spot.id,
                        OfficeLayout.wanderRange(for: $0.spot, placements: placements,
                                                 extraBlocked: decorBlocked)) })
        // 커피머신 방문 지점 — 커피머신 세트가 놓인 좌표 오른쪽 옆 (기계 정면을 비워둔다).
        coffeePoint = placements
            .first { OfficeLayout.furnitureSet(id: $0.setId)?.name == "커피머신" }
            .map { CGPoint(x: min($0.x + 12, OfficeLayout.sceneSize.width - OfficeLayout.edgeMargin),
                           y: OfficeLayout.lanes[$0.lane]) }
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
                case .walking(let target):
                    let dir: CGFloat = target > pet.x ? 1 : -1
                    pet.x += dir * Self.walkSpeed * dt
                    pet.facingRight = dir > 0
                    if abs(pet.x - target) < 1.5 {
                        pet.x = target
                        pet.phase = .idle(until: now + Double.random(in: 2...8))
                    }
                case .greeting(let until):
                    if now >= until {
                        pet.phase = .idle(until: now + Double.random(in: 1...4))
                    }
                case .visiting(let target, let returning):
                    moveToward(&pet, target: target, dt: dt)
                    if hypot(pet.x - target.x, pet.y - target.y) < 1.5 {
                        pet.x = target.x
                        pet.y = target.y
                        if returning {
                            pet.phase = .idle(until: now + Double.random(in: 2...8))
                            if visitingPetID == pet.id { visitingPetID = nil }
                        } else {
                            pet.phase = .drinking(until: now + Self.drinkDuration)
                            pet.bubble = Self.drinkQuotes.randomElement()
                            pet.bubbleUntil = now + Self.drinkDuration
                        }
                    }
                case .drinking(let until):
                    if now >= until {
                        pet.phase = .visiting(
                            target: CGPoint(x: pet.spot.anchorX, y: OfficeLayout.lanes[pet.spot.lane]),
                            returning: true)
                        pet.facingRight = pet.spot.anchorX > pet.x
                    }
                case .special(let until):
                    if now >= until {
                        pet.phase = .idle(until: now + Double.random(in: 2...8))
                    }
                }
            }
            updated[i] = pet
        }

        // 스침 인사 — 같은 바닥선, 둘 다 자기 레인 산책(walking) 중, 근접 교차.
        // 펫끼리는 비충돌(통과)이므로 하드 블록 없이 연출만 (기획 §5-2 충돌 모델).
        for i in updated.indices {
            guard case .walking = updated[i].phase, updated[i].mode != .sleeping else { continue }
            for j in updated.indices where j > i {
                guard case .walking = updated[j].phase, updated[j].mode != .sleeping,
                      abs(updated[i].y - updated[j].y) < 1,
                      abs(updated[i].x - updated[j].x) < 6 else { continue }
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
           hypot(pet.spot.anchorX - coffee.x, OfficeLayout.lanes[pet.spot.lane] - coffee.y) > 20,
           Double.random(in: 0..<1) < visitChance {
            visitingPetID = pet.id
            pet.phase = .visiting(target: coffee, returning: false)
            pet.facingRight = coffee.x > pet.x
            return
        }

        // 산책 vs 제자리 — working은 자리 지킴 성향.
        let wanderChance = pet.mode == .working ? 0.25 : 0.6
        if Double.random(in: 0..<1) < wanderChance, let range = wanderRanges[pet.spot.id] {
            let target = CGFloat.random(in: range)
            pet.phase = .walking(target: target)
            pet.facingRight = target > pet.x
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

    /// 2D 등속 이동 — 레인 간 이동은 바닥이 자유 통행이라 경로 검증 없이 직선.
    private func moveToward(_ pet: inout PetState, target: CGPoint, dt: CGFloat) {
        let dx = target.x - pet.x
        let dy = target.y - pet.y
        let dist = hypot(dx, dy)
        guard dist > 0.01 else { return }
        let step = min(Self.visitSpeed * dt, dist)
        pet.x += dx / dist * step
        pet.y += dy / dist * step
        if abs(dx) > 0.5 { pet.facingRight = dx > 0 }
    }
}
