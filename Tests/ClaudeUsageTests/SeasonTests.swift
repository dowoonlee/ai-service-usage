import XCTest
@testable import ClaudeUsage

/// 시즌 레지스트리 — 날짜 창·강제·스위치 합성. 소비자는 날짜를 안 보므로 여기가 유일한 날짜 테스트다.
/// 오피스 창밖 눈 — 위치가 시각의 순수 함수라 숫자로 고정할 수 있다. "잘 안 보인다"는 피드백으로
/// 7개 → 46개로 늘렸으니, 다시 줄어들면 여기서 걸린다.
final class WindowSnowTests: XCTestCase {
    func testSnowIsDenseAndStaysInsideTheWindowHorizontally() {
        XCTAssertGreaterThanOrEqual(WindowSnow.flakeCount, 40)
        for t in stride(from: 0.0, through: 30.0, by: 0.37) {
            let flakes = WindowSnow.flakes(at: t)
            XCTAssertEqual(flakes.count, WindowSnow.flakeCount)
            for f in flakes {
                XCTAssertTrue((0..<1).contains(f.x), "x=\(f.x) at t=\(t)")
                XCTAssertTrue((-0.1...1.1).contains(f.y), "y=\(f.y) at t=\(t)")
            }
            // 어느 순간에도 창 안(0...1)에 절반 넘게 보여야 "펑펑"이다.
            XCTAssertGreaterThan(flakes.filter { (0...1).contains($0.y) }.count, WindowSnow.flakeCount / 2)
        }
    }

    func testSnowFallsDownwardAndIsDeterministic() {
        XCTAssertEqual(WindowSnow.flakes(at: 12.5), WindowSnow.flakes(at: 12.5))
        let a = WindowSnow.flakes(at: 100.0), b = WindowSnow.flakes(at: 100.05)
        // 0.05초 뒤 대부분은 더 아래에 있다(위로 되감긴 것은 바닥을 지난 소수뿐).
        let movedDown = zip(a, b).filter { $1.y > $0.y }.count
        XCTAssertGreaterThan(movedDown, WindowSnow.flakeCount * 8 / 10)
        // 가장 빠른 겹도 2초 안팎 — 예전(10초 넘게 걸리던 점 7개)처럼 느려지면 실패.
        XCTAssertLessThanOrEqual(WindowSnow.layers.map(\.fallSeconds).min() ?? 99, 2.0)
    }
}

final class SeasonWindowTests: XCTestCase {
    private func kst(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        Calendar.kst.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testXmasWindowBoundaries() {
        let w = SeasonRegistry.season(.xmas)!.window
        // 겨울 시즌은 11/16에 켠다(2026-11-16 릴리스와 함께).
        XCTAssertFalse(w.contains(kst(2026, 11, 15, 23, 59)))
        XCTAssertTrue(w.contains(kst(2026, 11, 16, 0, 0)))
        XCTAssertTrue(w.contains(kst(2026, 12, 1, 0, 0)))
        XCTAssertTrue(w.contains(kst(2026, 12, 25, 23, 59)))
        XCTAssertFalse(w.contains(kst(2026, 12, 26, 0, 0)))   // end는 배타
    }

    func testNewYearWindowWrapsYear() {
        let w = SeasonRegistry.season(.newYear)!.window
        XCTAssertTrue(w.contains(kst(2026, 12, 26, 0, 0)))
        XCTAssertTrue(w.contains(kst(2026, 12, 31)))
        XCTAssertTrue(w.contains(kst(2027, 1, 3, 23, 59)))
        XCTAssertFalse(w.contains(kst(2027, 1, 4, 0, 0)))
        XCTAssertFalse(w.contains(kst(2027, 7, 1)))
    }

    func testInstanceYearGroupsWrappedWindowByStartYear() {
        let ny = SeasonRegistry.season(.newYear)!
        XCTAssertEqual(ny.instanceID(now: kst(2026, 12, 28)), "newYear-2026")
        XCTAssertEqual(ny.instanceID(now: kst(2027, 1, 2)), "newYear-2026")
        let xmas = SeasonRegistry.season(.xmas)!
        XCTAssertEqual(xmas.instanceID(now: kst(2026, 12, 10)), "xmas-2026")
    }

    func testSeasonsNeverOverlap() {
        // 1년 전부 — 하루에 활성 시즌이 둘이면 `active()`가 먼저 선언된 쪽을 임의로 고른다.
        var d = kst(2026, 1, 1, 0, 0)
        let end = kst(2027, 1, 1, 0, 0)
        while d < end {
            let hits = SeasonRegistry.all.filter { $0.window.contains(d) }
            XCTAssertLessThanOrEqual(hits.count, 1, "\(d): \(hits.map(\.kind))")
            d = Calendar.kst.date(byAdding: .day, value: 1, to: d)!
        }
    }

    func testNextBoundary() {
        XCTAssertEqual(SeasonRegistry.nextBoundary(after: kst(2026, 11, 15)), kst(2026, 11, 16, 0, 0))
        XCTAssertEqual(SeasonRegistry.nextBoundary(after: kst(2026, 12, 10)), kst(2026, 12, 26, 0, 0))
        XCTAssertEqual(SeasonRegistry.nextBoundary(after: kst(2026, 12, 30)), kst(2027, 1, 4, 0, 0))
    }

    func testFixedWindow() {
        let iv = DateInterval(start: kst(2027, 2, 6, 0, 0), end: kst(2027, 2, 10, 0, 0))
        let w = SeasonWindow(rule: .fixed([iv]))
        XCTAssertTrue(w.contains(kst(2027, 2, 7)))
        XCTAssertFalse(w.contains(kst(2027, 2, 10, 0, 0)))
        XCTAssertFalse(w.contains(kst(2028, 2, 7)))   // 테이블에 없는 연도는 비활성
        XCTAssertEqual(w.nextBoundary(after: kst(2027, 2, 7)), kst(2027, 2, 10, 0, 0))
    }

    func testEnvironmentOverrideParsing() {
        XCTAssertEqual(SeasonRegistry.environmentOverride(["AIUSAGE_SEASON": "xmas"]), .season(.xmas))
        XCTAssertEqual(SeasonRegistry.environmentOverride(["AIUSAGE_SEASON": "none"]), Override.none)
        XCTAssertNil(SeasonRegistry.environmentOverride(["AIUSAGE_SEASON": "bogus"]))
        XCTAssertNil(SeasonRegistry.environmentOverride([:]))
    }

    func testParticleStyleMapping() {
        XCTAssertNil(ParticleStyle.weather(.clear, intensity: 1))
        XCTAssertEqual(ParticleStyle.weather(.thunder, intensity: 0.5)?.thunder, true)
        XCTAssertEqual(ParticleStyle.weather(.snow, intensity: 0.5)?.intensity, 0.5)
        XCTAssertEqual(ParticleStyle.seasonSnow.intensity, 0.35)
        XCTAssertEqual(ParticleStyle.seasonSnow.quoteCondition, .snow)
    }

    @MainActor
    func testSeasonDataSanity() {
        for s in SeasonRegistry.all {
            XCTAssertFalse(s.quotes.isEmpty, "\(s.kind)")
            for q in s.quotes { XCTAssertLessThanOrEqual(q.count, 35, "\(s.kind): \(q)") }
            if let hw = s.headwear { XCTAssertNotNil(PetSprite.image(named: hw), "\(s.kind) headwear \(hw)") }
        }
    }
}

@MainActor
final class SeasonRegistryActiveTests: SandboxedTestCase {
    private func kst(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.kst.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    func testScheduledByDateWhenNoOverride() {
        SeasonRegistry.override = nil
        XCTAssertEqual(SeasonRegistry.active(now: kst(2026, 12, 10))?.kind, .xmas)
        XCTAssertEqual(SeasonRegistry.active(now: kst(2026, 12, 30))?.kind, .newYear)
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 7, 1)))
    }

    func testOverrideWinsOverDate() {
        SeasonRegistry.override = .season(.xmas)
        XCTAssertEqual(SeasonRegistry.active(now: kst(2026, 7, 1))?.kind, .xmas)
        SeasonRegistry.override = Override.none
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 12, 10)))
    }

    func testUserToggleAndKillSwitch() {
        SeasonRegistry.override = nil
        Settings.shared.seasonalEffectsEnabled = false
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 12, 10)))
        Settings.shared.seasonalEffectsEnabled = true
        Settings.shared.disabledSeasons = ["xmas"]
        XCTAssertNil(SeasonRegistry.active(now: kst(2026, 12, 10)))
        XCTAssertEqual(SeasonRegistry.active(now: kst(2026, 12, 30))?.kind, .newYear)
    }

    func testViewModelAmbientPrefersRealPrecipitation() {
        let vm = ViewModel()
        SeasonRegistry.override = .season(.xmas)
        vm.refreshSeason()
        XCTAssertEqual(vm.activeSeason?.kind, .xmas)
        vm.weather = .clear
        XCTAssertEqual(vm.ambientStyle, .seasonSnow)
        XCTAssertEqual(vm.effectiveWeather, .snow)
        vm.weather = .rain; vm.weatherIntensity = 0.7
        XCTAssertEqual(vm.ambientStyle?.sprite, "raindrop")
        XCTAssertEqual(vm.effectiveWeather, .rain)
        Settings.shared.weatherEffectEnabled = false
        vm.weather = .clear
        XCTAssertNil(vm.ambientStyle)
        XCTAssertEqual(vm.effectiveWeather, .clear)
    }
}

@MainActor
final class HeadAnchorTests: XCTestCase {
    func testScanFindsTopmostOpaqueBand() {
        // 4×4, (x=2, y=1 from top)만 불투명. lockFocus는 디스플레이 배율을 타므로 CGImage를 직접 만든다.
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 2, y: 2, width: 1, height: 1))   // y-up: 위에서 1행 = y 2
        let img = NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: 4, height: 4))
        let a = PetSprite.scanHeadAnchor(img)
        XCTAssertEqual(a?.x ?? -1, 0.625, accuracy: 0.001)
        XCTAssertEqual(a?.top ?? -1, 0.25, accuracy: 0.001)
    }

    func testEveryPetHasAnAnchorInsideTheCell() {
        for kind in PetKind.allCases {
            guard let a = PetSprite.headAnchor(for: kind, action: .walk, frameIndex: 0) else {
                XCTFail("\(kind): anchor nil"); continue
            }
            XCTAssert((0...1).contains(a.x), "\(kind) x=\(a.x)")
            XCTAssert((0..<0.9).contains(a.top), "\(kind) top=\(a.top)")
        }
    }
}

final class HeadwearLayoutTests: XCTestCase {
    func testLayoutMovesForwardAndSitsOnHead() {
        let anchor = PetSprite.HeadAnchor(x: 0.5, top: 0.25)
        let hat = CGSize(width: 16, height: 16)
        let right = PetSprite.headwearLayout(cellWidth: 100, cellHeight: 100, anchor: anchor, hatSize: hat, facesLeft: false)
        let left = PetSprite.headwearLayout(cellWidth: 100, cellHeight: 100, anchor: anchor, hatSize: hat, facesLeft: true)
        XCTAssertEqual(right.height, 42)
        XCTAssertEqual(right.centerX, 60)                 // 중심 50 + 앞(오른쪽) 10%
        XCTAssertEqual(left.centerX, 40)                  // 왼쪽을 보면 왼쪽으로
        // 모자 바닥 = 머리 꼭대기(25) + 42×0.35
        XCTAssertEqual(right.top + right.height, 25 + 42 * 0.35, accuracy: 0.001)
    }
}
