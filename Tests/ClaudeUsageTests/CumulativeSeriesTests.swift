import XCTest
@testable import ClaudeUsage

final class CumulativeSeriesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ offset: TimeInterval, cents: Double) -> CursorEvent {
        CursorEvent(timestamp: t0.addingTimeInterval(offset), model: nil, chargedCents: cents)
    }

    // 누적합이 달러 단위로 순서대로 쌓인다. 입력이 역순이어도 정렬 후 계산.
    func testCumulativeSumInDollars() {
        let events = [event(120, cents: 50), event(0, cents: 100), event(60, cents: 25)]
        let series = ViewModel.cumulativeSeries(events: events)
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].1, 1.00, accuracy: 0.0001)   // 100¢
        XCTAssertEqual(series[1].1, 1.25, accuracy: 0.0001)   // +25¢
        XCTAssertEqual(series[2].1, 1.75, accuracy: 0.0001)   // +50¢
        XCTAssertEqual(series[0].0, t0)
        XCTAssertEqual(series[2].0, t0.addingTimeInterval(120))
    }

    // 동일 timestamp는 1ms씩 밀려 strict ascending 보장 (0-width segment 방지).
    func testDuplicateTimestampsNudgedStrictlyAscending() {
        let events = [event(0, cents: 10), event(0, cents: 10), event(0, cents: 10)]
        let series = ViewModel.cumulativeSeries(events: events)
        XCTAssertEqual(series.count, 3)
        for i in 1..<series.count {
            XCTAssertGreaterThan(series[i].0, series[i - 1].0)
        }
    }

    func testEmptyEvents() {
        XCTAssertTrue(ViewModel.cumulativeSeries(events: []).isEmpty)
    }

    // maxPoints 이하 입력은 다운샘플 없이 그대로.
    func testDownsamplePassthroughWhenSmall() {
        let points = (0..<10).map { (t0.addingTimeInterval(Double($0)), Double($0)) }
        let out = ViewModel.downsampleKeepingLast(points, maxPoints: 240)
        XCTAssertEqual(out.count, 10)
    }

    // 초과 입력은 maxPoints(+1) 이내로 줄고, 마지막 점(최종 총액)은 정확히 보존.
    func testDownsampleCapsCountAndKeepsFinalPoint() {
        let n = 20000
        let points = (0..<n).map { (t0.addingTimeInterval(Double($0)), Double($0 + 1)) }
        let out = ViewModel.downsampleKeepingLast(points, maxPoints: ViewModel.cursorChartMaxPoints)
        XCTAssertLessThanOrEqual(out.count, ViewModel.cursorChartMaxPoints + 1)
        XCTAssertGreaterThan(out.count, 0)
        XCTAssertEqual(out.last!.0, points.last!.0)
        XCTAssertEqual(out.last!.1, points.last!.1)
        // 단조증가 유지 + timestamp strict ascending 유지.
        for i in 1..<out.count {
            XCTAssertGreaterThan(out[i].0, out[i - 1].0)
            XCTAssertGreaterThanOrEqual(out[i].1, out[i - 1].1)
        }
    }

    // 그룹 크기가 정확히 나누어떨어지는 경계에서도 마지막 점이 중복 추가되지 않는다.
    func testDownsampleNoDuplicateFinalPointOnExactBoundary() {
        // n=480, maxPoints=240 → group=2, 마지막 그룹 종점 = index 479 = 마지막 점.
        let points = (0..<480).map { (t0.addingTimeInterval(Double($0)), Double($0)) }
        let out = ViewModel.downsampleKeepingLast(points, maxPoints: 240)
        XCTAssertEqual(out.count, 240)
        XCTAssertEqual(out.last!.0, points.last!.0)
    }

    // cumulativeSeries가 대량 이벤트에서 다운샘플까지 통합 수행하는지.
    func testCumulativeSeriesDownsamplesLargeInput() {
        let events = (0..<5000).map { event(Double($0), cents: 1) }
        let series = ViewModel.cumulativeSeries(events: events)
        XCTAssertLessThanOrEqual(series.count, ViewModel.cursorChartMaxPoints + 1)
        // 최종 총액 = 5000¢ = $50 보존.
        XCTAssertEqual(series.last!.1, 50.0, accuracy: 0.0001)
    }
}
