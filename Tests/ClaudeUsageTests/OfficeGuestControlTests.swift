import XCTest
@testable import ClaudeUsage

/// 놀러가기(방문객) 펫의 WASD 조작 — 입장 연출 중(씬 왼쪽 밖) 키를 누른 경우의 계약.
@MainActor
final class OfficeGuestControlTests: SandboxedTestCase {
    private var fakeNow: TimeInterval = 1_000

    private func step(_ sim: OfficeSimulation, _ ticks: Int = 1) {
        for _ in 0..<ticks { fakeNow += 1.0 / 30; sim.tick() }
    }

    private func makeVisitSim() -> (OfficeSimulation, Int) {
        let info = PreviewDemoState.guildInfo()
        let others = info.members.filter { !$0.isMe }
        let sim = OfficeSimulation()
        sim.clock = { [unowned self] in self.fakeNow }
        sim.configure(members: others,
            assignments: OfficeLayout.autoAssignments(memberIds: others.map(\.nickname), seed: info.guild.id),
            placements: OfficeLayout.defaultPlacements,
            guest: .init(name: "visitor", kind: .fox, variant: 0, effects: []))
        sim.stop()
        return (sim, sim.pets.firstIndex { $0.isGuest }!)
    }

    func testGuestPressingKeyDuringEntranceStillMoves() {
        let (sim, g) = makeVisitSim()
        XCTAssertTrue(sim.hasControllablePet)
        XCTAssertLessThan(sim.pets[g].x, OfficeLayout.petWalkArea.minX, "입장 전엔 씬 왼쪽 밖")
        let startX = sim.pets[g].x
        sim.setControlKey(.right, pressed: true)
        step(sim, 60)   // 2초
        let pet = sim.pets[g]
        XCTAssertTrue(pet.isControlled)
        XCTAssertGreaterThan(pet.x - startX, 20, "입장 중 키를 눌러도 → 로 실제로 이동해야 한다 (방향만 바뀌면 안 됨)")
        XCTAssertTrue(OfficeLayout.petWalkArea.contains(CGPoint(x: pet.x, y: pet.y)), "2초면 바닥 영역에 들어와 있어야 한다")
    }

    func testGuestAfterArrivalMovesLikeMember() {
        let (sim, g) = makeVisitSim()
        step(sim, 30 * 8)   // 입장 완료까지 충분히
        let p0 = CGPoint(x: sim.pets[g].x, y: sim.pets[g].y)
        XCTAssertTrue(OfficeLayout.petWalkArea.contains(p0))
        sim.setControlKey(.up, pressed: true)
        step(sim, 30)
        XCTAssertLessThan(sim.pets[g].y, p0.y - 10, "도착 후 ↑ 는 위로 이동")
    }
}

/// `OfficeKeyCapture.CaptureView` — SwiftUI의 자동 포커스(창 재오픈·unhide·시트 열림 때 첫 TextField를
/// first responder로 만드는 동작)를 대신 받으려면 first responder 후보여야 하고, 가구 드래그·펫 탭을
/// 가리지 않으려면 히트테스트에서는 빠져 있어야 한다. 둘 중 하나가 깨지면 WASD가 초대/방명록
/// 입력란으로 타이핑되거나 씬 조작이 막힌다.
@MainActor
final class OfficeKeyCaptureTests: XCTestCase {
    func testCaptureViewAcceptsFirstResponderButIsTransparentToClicks() {
        let view = OfficeKeyCapture.CaptureView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertTrue(view.acceptsFirstResponder, "첫 key view가 되어 TextField 자동 포커스를 가로채야 한다")
        XCTAssertEqual(view.focusRingType, .none, "투명 뷰에 포커스 링이 그려지면 안 된다")
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)), "클릭은 통과 — 가구 드래그·펫 탭 유지")
    }
}
