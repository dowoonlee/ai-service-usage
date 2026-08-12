import XCTest
@testable import ClaudeUsage

final class JSONLStoreTests: XCTestCase {
    private var tempDir: URL!

    struct Item: Codable, Equatable { let id: Int; let name: String }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeStore(filename: String = "test.jsonl") -> JSONLStore<Item> {
        JSONLStore<Item>(filename: filename, label: "test", directory: tempDir)
    }

    // 파일 없으면 빈 배열.
    func testLoadRecentEmptyFile() {
        let store = makeStore()
        XCTAssertEqual(store.loadRecent(limit: 10), [])
    }

    // append 후 같은 순서로 loadRecent.
    func testAppendAndLoad() {
        let store = makeStore()
        let items = (1...5).map { Item(id: $0, name: "item\($0)") }
        items.forEach { store.append($0) }
        XCTAssertEqual(store.loadRecent(limit: 10), items)
    }

    // 라인 수가 limit보다 적으면 전부 반환.
    func testLoadRecentSmallerThanLimit() {
        let store = makeStore()
        let items = (1...3).map { Item(id: $0, name: "x") }
        items.forEach { store.append($0) }
        XCTAssertEqual(store.loadRecent(limit: 100), items)
    }

    // 라인 수가 limit보다 많으면 마지막 limit개만.
    func testLoadRecentLargerThanLimit() {
        let store = makeStore()
        let items = (1...50).map { Item(id: $0, name: "x") }
        items.forEach { store.append($0) }
        let recent = store.loadRecent(limit: 10)
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?.id, 41)
        XCTAssertEqual(recent.last?.id, 50)
    }

    // 파일이 청크 크기(64KB)를 넘어 여러 청크 거꾸로 읽어야 하는 시나리오.
    // 큰 payload로 100KB+ 강제, 마지막 N개가 정확히 복원되는지.
    func testTailSeekAcrossChunks() {
        let store = makeStore()
        let bigPayload = String(repeating: "x", count: 1500)   // 라인당 ~1.5KB → 100라인 = 150KB
        let items = (1...100).map { Item(id: $0, name: bigPayload) }
        items.forEach { store.append($0) }

        let recent = store.loadRecent(limit: 5)
        XCTAssertEqual(recent.count, 5)
        XCTAssertEqual(recent.map(\.id), [96, 97, 98, 99, 100])
    }

    // 비어있지 않은 마지막 라인이 정상적으로 디코딩되는지(\n 종결자가 끝에 있어야 함).
    func testLastLineNotTruncated() {
        let store = makeStore()
        store.append(Item(id: 1, name: "one"))
        store.append(Item(id: 2, name: "two"))
        let recent = store.loadRecent(limit: 1)
        XCTAssertEqual(recent, [Item(id: 2, name: "two")])
    }

    // 파일이 임계를 넘으면 뒤쪽만 남기고 잘라낸다 — 최신 라인은 보존, 오래된 것부터 폐기.
    // (스냅샷·cursor 이벤트 파일이 상한 없이 자라던 것을 막는 compaction.)
    func testCompactionTrimsOldestLines() {
        let store = JSONLStore<Item>(filename: "compact.jsonl", label: "test", directory: tempDir,
                                     compactThresholdBytes: 20_000, compactKeepBytes: 8_000)
        let payload = String(repeating: "y", count: 200)   // 라인당 ~230B
        (1...400).forEach { store.append(Item(id: $0, name: payload)) }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: store.storageURL.path)[.size] as? NSNumber)??.intValue ?? 0
        XCTAssertLessThanOrEqual(size, 20_000, "임계 이하로 줄어야 함")

        let recent = store.loadRecent(limit: 1000)
        XCTAssertFalse(recent.isEmpty)
        XCTAssertEqual(recent.last?.id, 400, "최신 라인은 보존")
        XCTAssertLessThan(recent.count, 400, "오래된 라인은 폐기")
        // 바이트로 자른 첫 라인이 남아 있으면 디코딩이 깨지거나 id가 튄다 — 연속성으로 검증.
        let ids = recent.map(\.id)
        XCTAssertEqual(ids, Array(ids[0]...400), "남은 구간의 id가 연속")
    }

    // 임계 미만이면 아무것도 자르지 않는다(정상 사용자의 통상 경로).
    func testNoCompactionBelowThreshold() {
        let store = JSONLStore<Item>(filename: "small.jsonl", label: "test", directory: tempDir,
                                     compactThresholdBytes: 10 * 1024 * 1024, compactKeepBytes: 1024)
        let items = (1...300).map { Item(id: $0, name: "x") }
        items.forEach { store.append($0) }
        XCTAssertEqual(store.loadRecent(limit: 1000), items)
    }

    // UTF-8 다바이트 문자(한글)가 청크 경계에 걸쳐도 정상 복원.
    func testUTF8AcrossChunkBoundary() {
        let store = makeStore()
        let korean = String(repeating: "한글테스트", count: 700)   // 라인당 ~10KB+ UTF-8
        let items = (1...20).map { Item(id: $0, name: korean) }
        items.forEach { store.append($0) }

        let recent = store.loadRecent(limit: 3)
        XCTAssertEqual(recent.map(\.id), [18, 19, 20])
        XCTAssertEqual(recent.last?.name, korean)
    }
}
