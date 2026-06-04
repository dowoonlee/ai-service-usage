import Foundation

/// 가챠 엔진. 등급 분배 + 가중 랜덤 + 보유 상태 반영.
///
/// 분배 정책: 현실 동물 = Common, 의인화/판타지 = 상위 등급.
/// 79종 풀에서 등급별 4/10/24/41 분배 → 종당 확률 0.5/0.8/1.25/1.46%.
/// 대형 사이즈/보스급 → Legendary, 헤드라이너/전사 → Epic, 등.
@MainActor
enum Gacha {
    /// 풀은 read-only static 데이터 — actor 격리 불필요. nonisolated로 두면 비-MainActor
    /// 컨텍스트(`PetCollection.bonusCoins` 같은 nonisolated computed)에서도 직접 읽을 수 있음.
    nonisolated static let pool: [Rarity: [PetKind]] = [
        .legendary: [.ninjaFrog, .knightM, .pirateCaptain, .whale],
        .epic:      [.maskDude, .ghost, .plant, .skull,
                     .ogre, .bigDemon, .kingHuman, .clownCaptain, .wizardM, .knightF],
        .rare:      [.mushroom, .slime, .trunk, .radish, .rock1, .rock2, .rock3, .chameleon, .rino,
                     .bigZombie, .necromancer, .fierceTooth, .kingPig, .baldPirate, .bigGuy,
                     .dwarfM, .elfM, .lizardM, .wizardF, .doc, .orcShaman, .orcWarrior,
                     .maskedOrc, .sunFox],
        .common:    [.fox, .wolf, .bear, .boar, .deer, .rabbit,
                     .angryPig, .bunny, .chicken, .duck, .blueBird, .fatBird,
                     .bat, .bee, .snail, .turtle,
                     .dwarfF, .elfF, .lizardF,
                     .chort, .pumpkinDude, .wogol,
                     .slug, .angel, .goblin, .imp, .skelet, .tinyZombie,
                     .iceZombie, .muddy, .swampy, .tinySlug, .zombie,
                     .pig, .pigBoxer, .pigBomber,
                     .bombGuy, .cucumber,
                     .jellySlime, .sunFrog, .oposum],
    ]

    /// 마이그레이션 시 legacy default petKind를 ownedPets로 옮길 때 등급 화이트리스트.
    /// Legendary/Epic은 마이그레이션으로 무료 지급되면 안 된다 — 사용자가 가챠로 뽑아야 함.
    /// (CLAUDE.md "Migration safety" 항목 참고)
    static func isLegendaryOrEpic(_ kind: PetKind) -> Bool {
        (pool[.legendary] ?? []).contains(kind) || (pool[.epic] ?? []).contains(kind)
    }

    /// 환율 캘리브레이션 그레이스 기간 (이 기간 내엔 시드값 사용).
    static let calibrationGracePeriod: TimeInterval = 7 * 86400
    /// 첫 7일 동안 사용하는 시드 비용.
    static let seedPullCost: Int = 300
    /// 캘리브레이션 후 비용 안전 범위.
    static let pullCostBounds: ClosedRange<Int> = 50...2000
    /// 평균 일일 적립의 몇 배를 1뽑기 비용으로 할지. 일주일에 2번 ≈ 3.5일치.
    static let pullCostDayMultiplier: Double = 3.5

    /// 1뽑기 비용. `seedPullCost` 고정 — 자동 보정은 "벌수록 비싸지는" 체감(#11/#12)으로 비활성화.
    /// `calibrationGracePeriod`/`pullCostBounds`/`pullCostDayMultiplier`는 향후 재도입 여지로 남김.
    static var pullCost: Int { seedPullCost }

    /// 한 번에 진행하는 연차 뽑기 수.
    static let multiPullCount: Int = 10
    /// 10연차 보너스: coin 지불 draw 중 이만큼은 무료(할인). "1회 무료" = 9배 가격.
    static let multiPullBonusFreeDraws: Int = 1

    /// 보유 티켓 수 기준 10연차 비용 분해.
    /// 정책: 티켓 우선 `min(보유, 10)`장 소모 → 남은 draw 중 보너스만큼 무료 → 나머지 × `pullCost`.
    /// 예) 티켓 0 → 9×300=2700 / 티켓 1 → 8×300=2400 / 티켓 9+ → 0.
    static func multiPullCost(tickets: Int) -> (ticketsUsed: Int, coinCost: Int) {
        let ticketsUsed = min(max(0, tickets), multiPullCount)
        let paidDraws = multiPullCount - ticketsUsed
        let chargedDraws = max(0, paidDraws - multiPullBonusFreeDraws)
        return (ticketsUsed, chargedDraws * pullCost)
    }

    /// Rarity 가중 랜덤 → 등급 내 균등 랜덤. (kind, rarity) 결정만.
    static func drawKind<RNG: RandomNumberGenerator>(using rng: inout RNG) -> (PetKind, Rarity) {
        let r = Double.random(in: 0..<1, using: &rng)
        var cumulative: Double = 0
        // 작은 등급(legendary) 먼저: cumulative 0.02 → 0.10 → 0.40 → 1.00
        let order: [Rarity] = [.legendary, .epic, .rare, .common]
        var rarity: Rarity = .common
        for tier in order {
            cumulative += tier.weight
            if r < cumulative { rarity = tier; break }
        }
        let kinds = pool[rarity] ?? []
        let kind = kinds.randomElement(using: &rng) ?? .fox
        return (kind, rarity)
    }

    static func drawKind() -> (PetKind, Rarity) {
        var rng = SystemRandomNumberGenerator()
        return drawKind(using: &rng)
    }

    /// 잔액만 차감하고 결과(kind, rarity)를 결정한다.
    /// **보유 상태(`ownedPets`)는 변경하지 않음** — `commit(_:)`을 부화 애니메이션
    /// 완료 시점에 호출해서 반영해야 한다 (인벤토리 미리 해금되는 버그 방지).
    /// 반환되는 GachaPull의 `variantUnlocked`는 nil; commit 후의 결과로 채워진다.
    @discardableResult
    static func roll(useTicket: Bool) throws -> GachaPull {
        let s = Settings.shared
        if useTicket {
            guard s.gachaTickets > 0 else { throw GachaError.noTickets }
            s.gachaTickets -= 1
        } else {
            guard s.coins >= pullCost else { throw GachaError.insufficientCoins }
            s.coins -= pullCost
        }
        let (kind, rarity) = drawKind()
        return GachaPull(pulledAt: Date(), kind: kind, rarity: rarity, variantUnlocked: nil)
    }

    /// 10연차 roll — 티켓/코인 선차감 후 10개의 (kind, rarity)만 결정한다.
    /// 단일 `roll`과 동일하게 **보유 상태는 변경하지 않음** — `commitMulti(_:)`를 애니메이션
    /// 완료 시점에 호출해 반영한다. 차감은 `multiPullCost(tickets:)` 정책을 따른다.
    @discardableResult
    static func rollMulti() throws -> [GachaPull] {
        let s = Settings.shared
        let (ticketsUsed, coinCost) = multiPullCost(tickets: s.gachaTickets)
        guard s.coins >= coinCost else { throw GachaError.insufficientCoins }
        // 결정 전에 선차감 (단일 roll과 동일 패턴 — 더블클릭 이중 차감은 호출측 가드가 막음).
        s.gachaTickets -= ticketsUsed
        s.coins -= coinCost
        var pulls: [GachaPull] = []
        pulls.reserveCapacity(multiPullCount)
        for _ in 0..<multiPullCount {
            let (kind, rarity) = drawKind()
            pulls.append(GachaPull(pulledAt: Date(), kind: kind, rarity: rarity, variantUnlocked: nil))
        }
        return pulls
    }

    /// `rollMulti()` 결과 10개를 순차 commit. 순차 처리라 같은 종이 배치 안에서 두 번 나오면
    /// 첫 칸은 신규(`isNew=true`), 둘째 칸은 중복으로 정확히 갈린다.
    /// 컬렉션 평가/하이라이트/첫 펫 자동 할당은 기존 `commit(_:)`을 그대로 재사용한다
    /// (여러 컬렉션이 한 배치에서 완성되면 `pendingCollectionCelebration`은 마지막 것만 남는다 —
    /// 단일 슬롯 한계, 결과 배너는 1건만 노출).
    @discardableResult
    static func commitMulti(_ pulls: [GachaPull]) -> [MultiPullResult] {
        let s = Settings.shared
        var out: [MultiPullResult] = []
        out.reserveCapacity(pulls.count)
        for pull in pulls {
            let wasOwned = s.ownedPets[pull.kind] != nil
            let resolved = commit(pull)
            let count = s.ownedPets[pull.kind]?.count ?? 1
            out.append(MultiPullResult(pull: resolved, isNew: !wasOwned, count: count))
        }
        return out
    }

    /// `roll(useTicket:)` 결과를 보유 상태에 반영. 부화 애니메이션의 hatched 진입 시점에 호출.
    /// - Returns: `variantUnlocked`가 채워진 새 `GachaPull` (UI 표시용).
    @discardableResult
    static func commit(_ pull: GachaPull) -> GachaPull {
        let s = Settings.shared
        let wasEmpty = s.ownedPets.isEmpty
        var owned = s.ownedPets
        var newVariant: Int? = nil
        var triggerHighlight = false
        if owned[pull.kind] == nil {
            owned[pull.kind] = .initial()
            triggerHighlight = true   // 신규 펫
        } else {
            var existing = owned[pull.kind]!
            let usageSec = s.petUsageSeconds[pull.kind] ?? 0
            newVariant = existing.registerPull(usageSeconds: usageSec)
            owned[pull.kind] = existing
            if newVariant != nil { triggerHighlight = true }   // 합산 진행도 임계 도달로 variant 해금
        }
        s.ownedPets = owned
        // 도감에서 직접 클릭해 확인하기 전까지 노란 강조 표시 유지.
        if triggerHighlight { s.pendingHighlights.insert(pull.kind) }
        // 첫 가챠 결과를 양쪽 차트의 활성 펫으로 자동 할당.
        // (의도된 동작) 두 번째 뽑기로 다른 펫을 얻어도 자동 갱신은 안 됨 — 사용자가
        // 명시적으로 SettingsView picker에서 변경해야 한다. 첫 뽑기 직후 두 차트가 같은
        // 펫인 게 살짝 어색할 수 있으나, 다른 종 보유 후 사용자가 의도해 골라야 분리.
        if wasEmpty {
            s.petClaudeKind = pull.kind
            s.petCursorKind = pull.kind
            s.petClaudeVariant = 0
            s.petCursorVariant = 0
        }
        DebugLog.log("Gacha commit: \(pull.kind.rawValue) [\(pull.rarity.rawValue)] count=\(owned[pull.kind]!.count)" +
                     (newVariant != nil ? " newVariant=\(newVariant!)" : ""))
        // 새 펫 보유 → 펫 컬렉션 컴플리트 평가. dedup은 Registry 내부.
        PetCollectionRegistry.evaluate()
        return GachaPull(pulledAt: pull.pulledAt, kind: pull.kind, rarity: pull.rarity,
                         variantUnlocked: newVariant)
    }
}

enum GachaError: Error, LocalizedError {
    case noTickets
    case insufficientCoins

    var errorDescription: String? {
        switch self {
        case .noTickets:         return "가챠권이 없습니다"
        case .insufficientCoins: return "코인이 부족합니다"
        }
    }
}
