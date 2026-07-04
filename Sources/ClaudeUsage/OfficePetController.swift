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
///   working  — 상위 5명(점수 기여자): 대부분 자리 고정, 낮은 빈도 wander. 데스크 PC ON 연동.
///   sleeping — 월 VP 0: 완전 고정 + 💤. 스침 인사에도 무반응.
///   greeting — 같은 레인에서 두 펫이 교차하는 순간 ~10% 확률로 1.5s 멈춤 + 인사 말풍선.
@MainActor
final class OfficeSimulation: ObservableObject {

    struct PetState: Identifiable {
        enum Mode { case normal, working, sleeping }
        enum Phase {
            case idle(until: TimeInterval)
            case walking(target: CGFloat)
            case greeting(until: TimeInterval)
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
        var facingRight: Bool = true
        var phase: Phase = .idle(until: 0)
        var bubble: String?
        var bubbleUntil: TimeInterval = 0

        var isWalking: Bool {
            if case .walking = phase { return true }
            return false
        }
    }

    @Published private(set) var pets: [PetState] = []

    private var timer: Timer?
    private var wanderRanges: [Int: ClosedRange<CGFloat>] = [:]
    /// 인사 스팸 방지 — pair key("a|b") → 다음 허용 시각.
    private var greetCooldown: [String: TimeInterval] = [:]
    private var configuredKey: String = ""

    /// 이동 속도 (논리 px/s) — WalkingCat 산책 감각에 맞춤.
    private static let walkSpeed: CGFloat = 14
    private static let greetDuration: TimeInterval = 1.5
    private static let greetChance = 0.10
    private static let greetCooldownSec: TimeInterval = 30
    private static let officeQuotes = [
        "빌드 기다리는 중…", "커피 리필 각", "머지 좀 봐주세요", "오늘도 평화로운 prod",
        "회의가 이길까 코딩이 이길까", "on-call 아님 (아마)", "LGTM?", "스탠드업 3분 전",
    ]
    private static let greetLines = ["👋", "커피?", "머지 축하", "오늘도 화이팅"]

    deinit {
        timer?.invalidate()
    }

    /// 멤버 목록 + 가구 배치 → 배치된(officeSlot != nil) 펫 상태 구성. 같은 구성이면
    /// 재구성하지 않아 5분 새로고침마다 펫이 순간이동하는 것을 막는다.
    /// layout이 바뀌면(가구 재배치) 산책 범위가 달라지므로 재구성 대상.
    func configure(members: [RankingAPI.GuildMember], layout: [Int]) {
        let key = members.map {
            "\($0.nickname):\($0.officeSlot ?? -1):\($0.isTopContributor):\($0.monthlyVP > 0)"
        }.sorted().joined(separator: ",")
            + "|layout:" + layout.map(String.init).joined(separator: ",")
        guard key != configuredKey else { return }
        configuredKey = key

        pets = members.compactMap { member in
            guard let spot = OfficeLayout.spot(id: member.officeSlot) else { return nil }
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
                x: spot.anchorX
            )
        }
        wanderRanges = Dictionary(uniqueKeysWithValues:
            pets.map { ($0.spot.id, OfficeLayout.wanderRange(for: $0.spot, layout: layout)) })
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
                        // working은 자리를 덜 비운다.
                        let wanderChance = pet.mode == .working ? 0.25 : 0.65
                        if Double.random(in: 0..<1) < wanderChance,
                           let range = wanderRanges[pet.spot.id] {
                            let target = CGFloat.random(in: range)
                            pet.phase = .walking(target: target)
                            pet.facingRight = target > pet.x
                        } else {
                            pet.phase = .idle(until: now + Double.random(in: 2...8))
                            // idle 시작 시 낮은 확률로 사무실 한마디.
                            if pet.bubble == nil && Double.random(in: 0..<1) < 0.08 {
                                pet.bubble = Self.officeQuotes.randomElement()
                                pet.bubbleUntil = now + 4
                            }
                        }
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
                }
            }
            updated[i] = pet
        }

        // 스침 인사 — 같은 레인, 둘 다 걷는 중, 근접 교차. 펫끼리는 비충돌(통과)이므로
        // 하드 블록 없이 연출만 (기획 §5-2 충돌 모델).
        for i in updated.indices {
            guard updated[i].isWalking, updated[i].mode != .sleeping else { continue }
            for j in updated.indices where j > i {
                guard updated[j].isWalking, updated[j].mode != .sleeping,
                      updated[i].spot.lane == updated[j].spot.lane,
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
}
