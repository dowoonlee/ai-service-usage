import XCTest
@testable import ClaudeUsage

/// 메뉴바 렌더러의 이로치 tint 캐시 계약.
///
/// `render`의 `frameIdx`는 tick마다 단조 증가하는 누적 카운터고, sprite 조회는 프레임 수로
/// 나머지 연산을 해 같은 그림을 돌려준다. 캐시 키가 이 정규화를 따라가지 않으면 "같은 그림,
/// 매번 다른 키"가 되어 캐시가 100% 미스하고 CI 렌더 결과가 무한히 쌓인다 — 실측으로
/// 5시간 만에 CoreImage 6.2GB / 리전 8만 개까지 갔다. 여기가 그 계약을 고정하는 자리다.
@MainActor
final class MenuBarRendererCacheTests: XCTestCase {
    // 캐시 키용 인덱스가 sprite 조회와 정확히 같은 프레임을 가리켜야 한다.
    // 둘이 어긋나면 캐시는 조용히 무의미해진다 (동작은 멀쩡해 보이고 메모리만 샌다).
    func testCacheFrameIndexMatchesSpriteLookup() {
        let kind = PetKind.fox
        let action = PetController.Action.walk
        let frames = PetSprite.frames(for: kind, action: action)
        XCTAssertFalse(frames.isEmpty, "테스트 전제: fox walk strip이 로드돼야 한다")

        for raw in [0, 1, 7, 100, 12_345, 1_000_000] {
            let idx = MenuBarRenderer.cacheFrameIndex(raw, kind: kind, action: action)
            XCTAssertTrue(idx >= 0 && idx < frames.count, "정규화 결과가 프레임 범위 밖: \(idx)")
            XCTAssertTrue(PetSprite.image(for: kind, action: action, frameIndex: raw) === frames[idx],
                          "frameIdx=\(raw)에서 캐시 키가 조회된 sprite와 다른 프레임을 가리킨다")
        }
    }

    // 오래 돌려도 캐시는 (액션당) 프레임 수를 넘지 않는다.
    // 누적 카운터가 키로 새면 이 값이 tick 수만큼 자란다.
    func testTintCacheStaysBoundedOverLongRun() {
        let kind = PetKind.fox
        let renderer = MenuBarRenderer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // pct = 0 → fps 6, action은 .walk 고정. 0.2초 tick이면 매번 frameIdx가 증가한다.
        let feed = MenuBarRenderer.Feed(
            pct: 0,
            history: (0..<12).map { (start.addingTimeInterval(Double($0) * 60), Double($0 % 5) * 10) },
            kind: kind,
            variant: 1,                       // variant 0은 tint 자체를 건너뛰므로 누수 경로가 아니다
            theme: PetTheme.defaultFor(kind)
        )
        renderer.reset(now: start)

        let ticks = 300
        for i in 1...ticks {
            _ = renderer.render(feed: feed, now: start.addingTimeInterval(Double(i) * 0.2))
        }

        let walkFrames = PetSprite.frames(for: kind, action: .walk).count
        XCTAssertLessThanOrEqual(renderer.tintedSpriteCacheCountForTesting, walkFrames,
                                 "\(ticks) tick 후 tint 캐시가 walk 프레임 수(\(walkFrames))를 넘었다 — 캐시 키에 누적 frameIdx가 샌다")
    }
}
