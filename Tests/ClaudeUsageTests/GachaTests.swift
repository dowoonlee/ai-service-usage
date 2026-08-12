import XCTest
@testable import ClaudeUsage

/// 가챠 — 앱의 1차 재미 루프인데 그동안 테스트가 한 건도 없었다. `Settings.shared`를 직접
/// 차감하는 구조라 실행하면 실제 사용자 코인이 빠져나갔기 때문이다(하네스 도입으로 해소).
///
/// 크게 두 종류를 잠근다.
///   1. **풀 정합성** — 새 펫을 `Gacha.pool`에 넣는 걸 깜빡해도 아무 테스트도 실패하지 않았다.
///      `PetKind.rarityFor()`는 nil을 반환하고 기존 테스트들은 `?? .common`으로 폴백하기 때문에
///      "가챠에서 영영 안 나오는데 Common 스탯으로 배틀에 서는 펫"이 조용히 생긴다.
///   2. **차감/커밋 계약** — roll이 잔액만 깎고 보유는 건드리지 않는다는 분리(부화 애니메이션 중
///      인벤토리가 미리 열리는 버그 방지)는 주석으로만 지켜지고 있었다.
@MainActor
final class GachaTests: SandboxedTestCase {

    // MARK: - 풀 정합성

    // 모든 PetKind가 정확히 한 등급에 속한다. 누락되면 그 펫은 가챠에서 영원히 안 나오고,
    // rarityFor가 nil이 되어 스탯·스킬 계산이 Common으로 조용히 폴백한다.
    func testPoolCoversEveryPetKindExactlyOnce() {
        let pooled = Gacha.pool.values.flatMap { $0 }
        XCTAssertEqual(Set(pooled).count, pooled.count, "같은 펫이 두 등급에 들어있다")

        let missing = Set(PetKind.allCases).subtracting(pooled)
        XCTAssertTrue(missing.isEmpty,
                      "Gacha.pool에 빠진 펫: \(missing.map(\.rawValue).sorted())")
        XCTAssertEqual(pooled.count, PetKind.allCases.count)
    }

    // 위 테스트의 실질적 귀결 — 폴백 없이 등급을 알 수 있어야 한다.
    func testEveryKindHasResolvableRarity() {
        let unresolved = PetKind.allCases.filter { PetKind.rarityFor($0) == nil }
        XCTAssertTrue(unresolved.isEmpty,
                      "rarity 미해결 펫: \(unresolved.map(\.rawValue).sorted())")
    }

    // 모든 등급에 최소 1마리 — 빈 등급이 있으면 drawKind가 `.fox` 폴백으로 새어나간다.
    func testEveryRarityTierIsPopulated() {
        for rarity in Rarity.allCases {
            XCTAssertFalse((Gacha.pool[rarity] ?? []).isEmpty, "\(rarity.rawValue) 풀이 비어있다")
        }
    }

    // MARK: - 추첨 분포

    // Mythic은 weight 0 — 코인 가챠로는 절대 나오지 않아야 한다(RP 프리미엄 전용 풀).
    // 이게 깨지면 프리미엄 티켓의 존재 이유가 사라진다.
    func testMythicNeverDropsFromCoinGacha() {
        var rng = SeededRNG(seed: 20260812)
        for _ in 0..<50_000 {
            let (kind, rarity) = Gacha.drawKind(using: &rng)
            XCTAssertNotEqual(rarity, .mythic)
            XCTAssertNotEqual(PetKind.rarityFor(kind), .mythic)
        }
    }

    // 실측 분포가 선언된 weight와 맞는지. 누적 경계(0.02 → 0.10 → 0.40 → 1.00) 계산이
    // 어긋나면 등급이 통째로 밀린다 — 표본 오차보다 훨씬 큰 차이로 드러난다.
    func testDrawKindDistributionMatchesDeclaredWeights() {
        var rng = SeededRNG(seed: 7)
        let n = 60_000
        var counts: [Rarity: Int] = [:]
        for _ in 0..<n {
            let (_, rarity) = Gacha.drawKind(using: &rng)
            counts[rarity, default: 0] += 1
        }
        for rarity in [Rarity.common, .rare, .epic, .legendary] {
            let observed = Double(counts[rarity] ?? 0) / Double(n)
            let expected = rarity.weight
            XCTAssertEqual(observed, expected, accuracy: expected * 0.15,
                           "\(rarity.rawValue) 실측 \(observed) vs 기대 \(expected)")
        }
    }

    // 프리미엄 풀은 [mythic + legendary]만 — 꽝(common/rare/epic)이 섞이면 안 된다.
    func testEliteDrawOnlyYieldsMythicOrLegendary() {
        var rng = SeededRNG(seed: 99)
        var mythic = 0
        let n = 20_000
        for _ in 0..<n {
            let (_, rarity) = Gacha.drawKindElite(using: &rng)
            XCTAssertTrue(rarity == .mythic || rarity == .legendary, "예상 밖 등급: \(rarity.rawValue)")
            if rarity == .mythic { mythic += 1 }
        }
        XCTAssertEqual(Double(mythic) / Double(n), Gacha.eliteMythicChance,
                       accuracy: Gacha.eliteMythicChance * 0.15)
    }

    // MARK: - 10연차 비용

    // 티켓 우선 소모 → 남은 draw 중 1회 무료 → 나머지만 과금.
    func testMultiPullCostTicketBoundaries() {
        let cost = Gacha.pullCost
        XCTAssertEqual(Gacha.multiPullCost(tickets: 0).ticketsUsed, 0)
        XCTAssertEqual(Gacha.multiPullCost(tickets: 0).coinCost, 9 * cost)
        XCTAssertEqual(Gacha.multiPullCost(tickets: 1).coinCost, 8 * cost)
        XCTAssertEqual(Gacha.multiPullCost(tickets: 9).coinCost, 0)

        // 보유가 10을 넘어도 10장까지만 쓴다 — 초과분이 다음 뽑기용으로 남아야 한다.
        XCTAssertEqual(Gacha.multiPullCost(tickets: 25).ticketsUsed, Gacha.multiPullCount)
        XCTAssertEqual(Gacha.multiPullCost(tickets: 25).coinCost, 0)

        // 음수 티켓(손상된 저장값)이 코인 비용을 부풀리거나 음수로 만들지 않아야 한다.
        XCTAssertEqual(Gacha.multiPullCost(tickets: -5).ticketsUsed, 0)
        XCTAssertEqual(Gacha.multiPullCost(tickets: -5).coinCost, 9 * cost)
    }

    // MARK: - 차감 / 커밋 분리

    func testRollDebitsCoinsOnce() throws {
        let s = Settings.shared
        s.coins = 1000
        _ = try Gacha.roll(useTicket: false)
        XCTAssertEqual(s.coins, 1000 - Gacha.pullCost)
    }

    func testRollWithTicketSpendsTicketNotCoins() throws {
        let s = Settings.shared
        s.coins = 1000
        s.gachaTickets = 2
        _ = try Gacha.roll(useTicket: true)
        XCTAssertEqual(s.gachaTickets, 1)
        XCTAssertEqual(s.coins, 1000, "티켓 뽑기는 코인을 건드리면 안 된다")
    }

    func testRollRejectsInsufficientBalance() {
        let s = Settings.shared
        s.coins = Gacha.pullCost - 1
        XCTAssertThrowsError(try Gacha.roll(useTicket: false)) { error in
            XCTAssertEqual(error as? GachaError, .insufficientCoins)
        }
        XCTAssertEqual(s.coins, Gacha.pullCost - 1, "실패한 뽑기가 잔액을 깎으면 안 된다")
    }

    func testRollWithoutTicketsThrows() {
        Settings.shared.gachaTickets = 0
        XCTAssertThrowsError(try Gacha.roll(useTicket: true)) { error in
            XCTAssertEqual(error as? GachaError, .noTickets)
        }
    }

    func testPremiumRollSpendsPremiumTicketOnly() throws {
        let s = Settings.shared
        s.coins = 1000
        s.premiumTickets = 1
        s.gachaTickets = 3
        let pull = try Gacha.rollPremium()
        XCTAssertEqual(s.premiumTickets, 0)
        XCTAssertEqual(s.gachaTickets, 3)
        XCTAssertEqual(s.coins, 1000)
        XCTAssertTrue(pull.rarity == .mythic || pull.rarity == .legendary)
    }

    // roll은 잔액만 깎고 보유는 손대지 않는다 — 부화 애니메이션(~3.7초) 동안 인벤토리가
    // 미리 열리지 않게 하는 계약. 이 분리가 무너지면 연출 전에 결과가 노출된다.
    func testRollDoesNotMutateOwnership() throws {
        let s = Settings.shared
        s.coins = 1000
        let before = s.ownedPets
        let pull = try Gacha.roll(useTicket: false)
        XCTAssertEqual(s.ownedPets.count, before.count, "roll이 보유 펫을 바꿨다")
        XCTAssertNil(s.ownedPets[pull.kind], "roll 시점에 펫이 해금되면 안 된다")
    }

    func testCommitUnlocksPetAndFlagsHighlight() throws {
        let s = Settings.shared
        s.coins = 1000
        let pull = try Gacha.roll(useTicket: false)
        _ = Gacha.commit(pull)
        XCTAssertNotNil(s.ownedPets[pull.kind])
        XCTAssertEqual(s.ownedPets[pull.kind]?.count, 1)
        XCTAssertTrue(s.pendingHighlights.contains(pull.kind), "신규 펫은 도감 강조 대상")
    }

    // 첫 펫은 양쪽 차트에 자동 배정되지만, 두 번째 뽑기는 사용자의 선택을 덮지 않는다.
    func testFirstCommitSeedsChartsButSecondDoesNot() throws {
        let s = Settings.shared
        s.ownedPets = [:]
        s.coins = 10_000

        let first = try Gacha.roll(useTicket: false)
        _ = Gacha.commit(first)
        XCTAssertEqual(s.petClaudeKind, first.kind)
        XCTAssertEqual(s.petCursorKind, first.kind)

        var second = try Gacha.roll(useTicket: false)
        while second.kind == first.kind { second = try Gacha.roll(useTicket: false) }
        _ = Gacha.commit(second)
        XCTAssertEqual(s.petClaudeKind, first.kind, "두 번째 뽑기가 차트 배정을 덮어썼다")
    }

    // 같은 종이 한 배치에 두 번 나오면 첫 칸만 신규다 — 순차 commit이 보장하는 성질.
    func testMultiPullMarksDuplicatesWithinBatch() {
        let s = Settings.shared
        s.ownedPets = [:]
        let kind = PetKind.allCases[0]
        let pulls = (0..<3).map {
            GachaPull(pulledAt: Date(timeIntervalSince1970: TimeInterval($0)),
                      kind: kind, rarity: PetKind.rarityFor(kind) ?? .common, variantUnlocked: nil)
        }
        let results = Gacha.commitMulti(pulls)
        XCTAssertEqual(results.map(\.isNew), [true, false, false])
        XCTAssertEqual(results.map(\.count), [1, 2, 3])
    }

    func testMultiPullDebitsTicketsThenCoins() throws {
        let s = Settings.shared
        s.coins = 10_000
        s.gachaTickets = 3
        let pulls = try Gacha.rollMulti()
        XCTAssertEqual(pulls.count, Gacha.multiPullCount)
        XCTAssertEqual(s.gachaTickets, 0)
        XCTAssertEqual(s.coins, 10_000 - 6 * Gacha.pullCost)   // 10 - 3티켓 - 1무료 = 6과금
    }

    func testMultiPullRejectsInsufficientBalance() {
        let s = Settings.shared
        s.gachaTickets = 0
        s.coins = 9 * Gacha.pullCost - 1
        XCTAssertThrowsError(try Gacha.rollMulti())
        XCTAssertEqual(s.coins, 9 * Gacha.pullCost - 1)
        XCTAssertEqual(s.gachaTickets, 0, "실패한 10연차가 티켓을 삼키면 안 된다")
    }
}
