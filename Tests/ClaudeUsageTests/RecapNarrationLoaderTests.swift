import XCTest
@testable import ClaudeUsage

@MainActor
final class RecapNarrationLoaderTests: SandboxedTestCase {
    private func facts(pet: PetKind = .bear) -> RecapFacts {
        var game = RecapGameFacts.gather(events: [])
        game.narrator = PetSelection(kind: pet, variant: 0)
        return RecapFacts(usage: .compute(claude: [], codex: [], cursor: [], now: Date()), game: game)
    }
    private func authenticate(_ device: String = "account-one") {
        Settings.shared.rankingDeviceID = device
        XCTAssertTrue(Keychain.saveRankingHmacKey("test-key"))
    }
    private func row(pet: String = "bear", year: Int = 2026) -> RecapNarrationRow {
        .init(year: year, petKind: pet, generatedAt: Date(timeIntervalSince1970: 1794560000),
              persona: "느긋한 곰", lines: Dictionary(uniqueKeysWithValues: RecapNarration.sceneIDs.map { ($0, "우리 이야기를 천천히 돌아보자.") }))
    }

    func testPendingThenReadyIsCachedAcrossLoaderInstances() async {
        authenticate()
        var requests = 0
        let saved = row()
        let loader = RecapNarrationLoader(request: { _, _, _, _, _ in
            requests += 1
            return requests == 1 ? .init(status: .pending, row: nil, retryAfter: 1)
                : .init(status: .ready, row: saved, retryAfter: nil)
        }, sleep: { _ in })
        await loader.load(facts: facts())
        guard case .ready(let first) = loader.state else { return XCTFail("expected ready") }
        XCTAssertEqual(first, saved)
        let second = RecapNarrationLoader(request: { _, _, _, _, _ in
            XCTFail("Cached narration must not call the server")
            throw URLError(.notConnectedToInternet)
        })
        await second.load(facts: facts())
        guard case .ready(let cached) = second.state else { return XCTFail("expected local cache") }
        XCTAssertEqual(cached, saved)
        XCTAssertEqual(requests, 2)
    }

    func testCacheIsSeparatedByAccountAndPet() async {
        authenticate()
        var requested: [String] = []
        let loader = RecapNarrationLoader(request: { device, _, year, pet, _ in
            requested.append("\(device)/\(pet)")
            return .init(status: .ready, row: self.row(pet: pet, year: year), retryAfter: nil)
        })
        await loader.load(facts: facts())
        await loader.load(facts: facts(pet: .fox))
        authenticate("account-two")
        await loader.load(facts: facts())
        XCTAssertEqual(requested, ["account-one/bear", "account-one/fox", "account-two/bear"])
    }

    func testWrongPetOrIncompleteResponseIsNotUsedOrCached() async {
        authenticate()
        let loader = RecapNarrationLoader(request: { _, _, _, _, _ in
            .init(status: .ready, row: self.row(pet: "fox"), retryAfter: nil)
        })
        await loader.load(facts: facts())
        guard case .fallback = loader.state else { return XCTFail("must reject another pet's text") }
        let partial = RecapNarrationRow(year: 2026, petKind: "bear", generatedAt: Date(), persona: "곰", lines: ["boot": "대사"])
        XCTAssertFalse(partial.isValid(year: 2026, petKind: "bear"))
        XCTAssertFalse(row(year: 2027).isValid(year: 2026, petKind: "bear"))
    }

    func testUnregisteredAndServerFailureUseFallback() async {
        let loader = RecapNarrationLoader(request: { _, _, _, _, _ in
            XCTFail("No credentials means no network request")
            throw URLError(.notConnectedToInternet)
        })
        await loader.load(facts: facts())
        guard case .fallback = loader.state else { return XCTFail("expected fallback") }
        authenticate()
        let failed = RecapNarrationLoader(request: { _, _, _, _, _ in .init(status: .failed, row: nil, retryAfter: 900) })
        await failed.load(facts: facts())
        guard case .fallback = failed.state else { return XCTFail("expected fallback") }
    }

    func testSummaryContainsOnlyBoundedStatsAndExplicitNullPartner() throws {
        let summary = try RecapNarrationSummary(facts()).json()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
        XCTAssertTrue(object["partnerKind"] is NSNull)
        XCTAssertNil(object["nickname"])
        XCTAssertNil(object["events"])
        XCTAssertNil(object["daily"])
        XCTAssertEqual(object["goldenHour"] as? Int, -1)
        XCTAssertEqual(Set(RecapNarration.sceneIDs), Set(RecapScenes.all.map(\.id)))
    }
}
