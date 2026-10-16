import XCTest
@testable import ClaudeUsage

/// 길드 사무실 WASD 조작 — `OfficeSimulation.setControlKey` → `tick()` 경로의 계약.
/// 타이머 없이 `tick()`을 직접 돌려 결정적으로 검사한다 (1 tick = 1/30s). 시계도 가짜로 바꿔
/// 틱마다 1/30초씩 민다 — 액션 길이·복귀 타이머가 벽시계가 아니라 틱 수로 결정되게.
@MainActor
final class OfficeControlTests: SandboxedTestCase {
    private var fakeNow: TimeInterval = 1_000

    /// 1틱 = 1/30초 — 시계를 먼저 밀고 틱.
    private func step(_ sim: OfficeSimulation, _ ticks: Int = 1, each: (() -> Void)? = nil) {
        for _ in 0..<ticks {
            fakeNow += 1.0 / 30
            sim.tick()
            each?()
        }
    }

    private func makeSim(placements: [OfficeLayout.FurniturePlacement]) -> (OfficeSimulation, Int) {
        let info = PreviewDemoState.guildInfo()
        let sim = OfficeSimulation()
        sim.clock = { [unowned self] in self.fakeNow }
        sim.configure(members: info.members,
            assignments: OfficeLayout.autoAssignments(memberIds: info.members.map(\.nickname), seed: info.guild.id),
            placements: placements)
        sim.stop()   // 타이머는 끈다 — 테스트가 tick을 직접 민다.
        let me = sim.pets.firstIndex(where: \.isMe)!
        return (sim, me)
    }

    func testHeldKeyMovesOnlyMyPetAndReleasingStopsIt() {
        let (sim, me) = makeSim(placements: [])
        XCTAssertTrue(sim.hasControllablePet)
        let startX = sim.pets[me].x
        let startY = sim.pets[me].y

        sim.setControlKey(.right, pressed: true)
        step(sim, 30)   // 1초
        let pet = sim.pets[me]
        XCTAssertTrue(pet.isControlled)
        XCTAssertTrue(pet.isWalking, "키가 눌린 동안은 걷기 프레임")
        XCTAssertTrue(pet.facingRight)
        XCTAssertEqual(pet.y, startY, accuracy: 0.001, "→ 만 눌렀으면 y는 그대로")
        XCTAssertGreaterThan(pet.x - startX, 20, "28px/s 속도로 1초면 ~28px")

        sim.setControlKey(.right, pressed: false)
        step(sim)
        let released = sim.pets[me]
        XCTAssertTrue(released.isControlled, "손을 떼도 복귀 타이머 동안은 조작 상태 유지")
        XCTAssertFalse(released.isWalking, "멈추면 앉기 프레임")
        let xAfterRelease = released.x
        step(sim, 30)
        XCTAssertEqual(sim.pets[me].x, xAfterRelease, accuracy: 0.001, "키 없이는 움직이지 않는다")
    }

    func testControlledPetStaysInsideWalkAreaAndOffFurniture() {
        // 기본 가구 배치 — 충돌 밴드가 있는 실제 조건에서 한 걸음씩 전부 자유 셀이어야 한다.
        let placements = OfficeLayout.defaultPlacements
        let (sim, me) = makeSim(placements: placements)
        let grid = OfficePathGrid(blockedRects: OfficeLayout.collisionRects(placements: placements, decor: []))
        let area = OfficeLayout.petWalkArea

        // 네 방향 각각 20초씩 밀어붙여 가장자리·가구에 부딪히게 한다.
        for key in [OfficeSimulation.ControlKey.right, .down, .left, .up] {
            sim.setControlKey(key, pressed: true)
            step(sim, 600) {
                let p = CGPoint(x: sim.pets[me].x, y: sim.pets[me].y)
                XCTAssertTrue(area.contains(p), "\(key): \(p) 는 보행 영역 밖")
                XCTAssertTrue(grid.isWalkable(p), "\(key): \(p) 는 가구 충돌 밴드 위")
            }
            sim.setControlKey(key, pressed: false)
        }
        // 20초간 → 로 밀었으면 오른쪽 끝 근처까지 갔어야 한다 (가구를 돌아서라도).
        sim.setControlKey(.right, pressed: true)
        step(sim, 600)
        XCTAssertGreaterThan(sim.pets[me].x, area.midX)
    }

    func testDiagonalInputNormalisesSpeed() {
        let (sim, me) = makeSim(placements: [])
        let start = CGPoint(x: sim.pets[me].x, y: sim.pets[me].y)
        sim.setControlKey(.right, pressed: true)
        sim.setControlKey(.down, pressed: true)
        step(sim, 15)   // 0.5초 — 아래 경계(146)까지 여유 있는 범위
        let end = CGPoint(x: sim.pets[me].x, y: sim.pets[me].y)
        let dist = hypot(end.x - start.x, end.y - start.y)
        XCTAssertEqual(dist, 14, accuracy: 2, "대각선도 28px/s — 축별 합산으로 √2배 빨라지면 안 된다")
    }

    func testEmoteKeyPlaysQuoteAndHopThenSettlesIntoControlledIdle() {
        let (sim, me) = makeSim(placements: [])
        let start = CGPoint(x: sim.pets[me].x, y: sim.pets[me].y)
        sim.triggerEmote()
        let pet = sim.pets[me]
        XCTAssertTrue(pet.isEmoting)
        XCTAssertNotNil(pet.bubble, "F = 대사 한마디")
        XCTAssertFalse(Mythic.isMythic(pet.kind), "데모의 내 펫은 일반 종 — 점프 경로를 검사한다")

        var maxHop: CGFloat = 0
        step(sim, 24) {   // 0.8초 — 첫 점프 봉우리를 지난다
            maxHop = max(maxHop, sim.pets[me].hopOffset)
            XCTAssertEqual(sim.pets[me].x, start.x, accuracy: 0.001, "액션 중엔 제자리")
            XCTAssertEqual(sim.pets[me].y, start.y, accuracy: 0.001)
        }
        XCTAssertGreaterThan(maxHop, 3, "일반 펫은 제자리 점프가 보여야 한다")

        step(sim, 40)   // 누적 2.1초 > 1.6초 액션 길이
        let done = sim.pets[me]
        XCTAssertFalse(done.isEmoting)
        XCTAssertTrue(done.isControlled, "액션이 끝나면 WASD와 같은 조작 여운으로")
        XCTAssertEqual(done.hopOffset, 0)
        XCTAssertNotNil(done.bubble, "대사는 액션보다 조금 더 남는다")

        step(sim, 30 * 7)   // 조작 여운 6초 경과
        XCTAssertFalse(sim.pets[me].isControlled, "손을 뗀 지 6초가 지나면 자율 행동으로 복귀")
    }

    func testEmoteIgnoresRepeatWhilePlayingAndIsInterruptedByMovement() {
        let (sim, me) = makeSim(placements: [])
        sim.triggerEmote()
        let firstUntil = sim.pets[me].bubbleUntil
        step(sim)
        sim.triggerEmote()
        XCTAssertEqual(sim.pets[me].bubbleUntil, firstUntil, "재생 중 연타는 무시")

        sim.setControlKey(.right, pressed: true)
        step(sim)
        XCTAssertTrue(sim.pets[me].isControlled, "이동 입력이 액션을 끊는다")
        XCTAssertEqual(sim.pets[me].hopOffset, 0)
        sim.setControlKey(.right, pressed: false)
    }

    func testNoControllablePetWhenNobodyIsMe() {
        let info = PreviewDemoState.guildInfo()
        let others = info.members.filter { !$0.isMe }
        let sim = OfficeSimulation()
        sim.configure(members: others,
            assignments: OfficeLayout.autoAssignments(memberIds: others.map(\.nickname), seed: info.guild.id),
            placements: [])
        sim.stop()
        sim.clock = { [unowned self] in self.fakeNow }
        XCTAssertFalse(sim.hasControllablePet)
        let before = sim.pets.map(\.phase.isControlledPhase)
        sim.setControlKey(.right, pressed: true)
        step(sim, 30)
        XCTAssertEqual(sim.pets.map(\.phase.isControlledPhase), before, "내 펫이 없으면 WASD는 아무도 움직이지 않는다")
        XCTAssertFalse(sim.pets.contains { $0.isControlled })
        sim.triggerEmote()
        XCTAssertFalse(sim.pets.contains { $0.isEmoting }, "F도 마찬가지")
    }
}

private extension OfficeSimulation.PetState.Phase {
    var isControlledPhase: Bool {
        if case .controlled = self { return true }
        return false
    }
}
