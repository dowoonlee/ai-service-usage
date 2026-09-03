import XCTest
@testable import ClaudeUsage

/// 창 가시성/활성 판정. 깃발 이펙트(`PetEffectOverlay.flag`)는 `windowIsActive`로 프레임 루프를
/// 멈추므로, "언제 활성인가"가 곧 그 연출이 CPU를 쓰는 조건이다.
@MainActor
final class WindowActivityTests: XCTestCase {

    /// 포커스가 없으면 활성이 아니다 — 보이기만 하는 뒤쪽 창에서 비싼 연출이 돌면 안 된다.
    func testVisibleButNotKeyIsNotActive() {
        let s = WindowVisibilityMonitor.state(isVisible: true, isMiniaturized: false,
                                              occluded: false, isKey: false)
        XCTAssertTrue(s.visible)
        XCTAssertFalse(s.active)
    }

    /// 보이고 + 키면 활성.
    func testVisibleAndKeyIsActive() {
        let s = WindowVisibilityMonitor.state(isVisible: true, isMiniaturized: false,
                                              occluded: false, isKey: true)
        XCTAssertTrue(s.visible)
        XCTAssertTrue(s.active)
    }

    /// 안 보이면 key 플래그가 남아 있어도 활성이 아니다 (닫히는 중/최소화/완전 가림).
    func testHiddenIsNeverActive() {
        for (visible, mini, occluded) in [(false, false, false), (true, true, false), (true, false, true)] {
            let s = WindowVisibilityMonitor.state(isVisible: visible, isMiniaturized: mini,
                                                  occluded: occluded, isKey: true)
            XCTAssertFalse(s.visible, "visible=\(visible) mini=\(mini) occluded=\(occluded)")
            XCTAssertFalse(s.active, "visible=\(visible) mini=\(mini) occluded=\(occluded)")
        }
    }
}

/// 깃발에 걸 길드 로고 판정. `GuildLogo.image`는 값이 없으면 id 해시로 샘플을 지어내는데,
/// 깃발에서 그러면 **내 길드기 자리에 남의 로고**가 걸린다 (v0.17.33 실제 증상).
@MainActor
final class GuildFlagLogoTests: SandboxedTestCase {

    /// 로고 캐시가 비었으면 nil — 지어낸 샘플이 아니라 기본 깃발로 폴백해야 한다.
    func testEmptyLogoGivesNoFlagImage() {
        XCTAssertNil(GuildLogo.flagImage(for: "", guildID: "some-guild-id"))
        XCTAssertNil(GuildLogo.flagImage(for: nil, guildID: "some-guild-id"))
    }

    /// 무소속(길드 id 없음)도 nil.
    func testNoGuildGivesNoFlagImage() {
        XCTAssertNil(GuildLogo.flagImage(for: "s:3", guildID: ""))
    }

    /// 값이 있으면 그 로고를 그대로 준다 — 샘플·커스텀 모두.
    func testExplicitLogoResolves() {
        XCTAssertNotNil(GuildLogo.flagImage(for: "s:3", guildID: "some-guild-id"))
    }

    /// `myFlagImage`는 캐시(`Settings.guildLogo`)만 본다 — 캐시가 비면 깃발도 무지.
    func testMyFlagImageFollowsCache() {
        let s = Settings.shared
        s.guildID = "b34b2241-75f8-4903-8648-623c63658b78"
        s.guildLogo = ""
        XCTAssertNil(GuildLogo.myFlagImage, "캐시가 비었는데 로고를 지어내면 남의 길드기가 걸린다")
        s.guildLogo = GuildLogo.encode(sample: 3)
        XCTAssertNotNil(GuildLogo.myFlagImage)
    }
}
