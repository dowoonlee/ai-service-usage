import XCTest
import SwiftUI
@testable import ClaudeUsage

/// 프리뷰용 데모 상태.
///
/// 화면 프리뷰는 빈 상태로 찍으면 아무것도 검수할 수 없다 — 도장은 전부 잠겨 있고, 파티는 비어
/// 있고, 도감은 회색이다. 실제 사용자의 중반 진행도를 흉내낸 상태를 샌드박스에 시드해서,
/// "값이 들어찼을 때의 레이아웃"을 본다.
///
/// 여기서 마음껏 상태를 써도 안전한 이유는 `AppEnv`가 XCTest를 샌드박스로 돌리기 때문이다
/// (`SandboxedTestCase` 참조). 예전에는 이런 시드 자체가 실사용 데이터 오염이었다.
@MainActor
enum PreviewDemoState {

    /// 중반 진행도의 트레이너. 프리뷰 스위트는 setUp에서 이걸 호출한다.
    static func seed() {
        let s = Settings.shared
        s.coins = 12_480
        s.coinsTotalEarned = 148_200
        s.gachaTickets = 4
        s.premiumTickets = 1
        s.rp = 320
        s.rpTotalEarned = 1_450
        s.shinyShards = 41
        s.rankingNickname = "데모트레이너"

        seedPets()
        seedBadges()
        seedCollections()
        seedParty()
        seedCosmetics()
    }

    /// 등급별로 고르게 섞은 보유 펫. variant는 0~4를 흩어서 이로치·프레스티지 표시도 함께 본다.
    static func seedPets() {
        let s = Settings.shared
        var owned: [PetKind: PetOwnership] = [:]
        var usage: [PetKind: TimeInterval] = [:]

        for rarity in [Rarity.common, .rare, .epic, .legendary, .mythic] {
            let pool = Gacha.pool[rarity] ?? []
            // 등급마다 앞에서 몇 마리만 — 도감이 "일부는 열리고 일부는 잠긴" 실제 모습이 되게.
            let take = rarity == .common ? 24 : (rarity == .rare ? 12 : 4)
            for (i, kind) in pool.prefix(take).enumerated() {
                var o = PetOwnership.initial()
                o.count = 1 + i * 3
                // 0,1,2,3,4 순환 — 각 variant 뱃지가 한 화면에 다 나오게.
                let top = i % 5
                o.unlockedVariants = Set(0...min(top, 3))
                if top == PetOwnership.prestigeVariant { o.unlockedVariants.insert(PetOwnership.prestigeVariant) }
                owned[kind] = o
                usage[kind] = TimeInterval(3600 * (i + 1))
            }
        }
        s.ownedPets = owned
        s.petUsageSeconds = usage
    }

    /// 지역별로 진행 상태가 다르게 — 완주/진행중/미개봉이 한 화면에 같이 보이도록.
    static func seedBadges() {
        let s = Settings.shared
        var cleared: Set<String> = []
        for (i, category) in BadgeCategory.allCases.enumerated() {
            // 카테고리마다 다른 티어까지 클리어. i%4 == 0이면 아예 미획득.
            let upTo = i % 4
            guard upTo > 0 else { continue }
            for tier in BadgeTier.allCases.prefix(upTo) {
                cleared.insert(BadgeID(category: category, tier: tier).key)
            }
        }
        s.clearedBadges = cleared
        s.creditedBadgeRewards = cleared
        s.discoveredRegions = Set(BadgeRegion.allCases.map(\.rawValue))
        s.masteredRegions = Set(BadgeRegion.allCases.prefix(1).map(\.rawValue))
    }

    static func seedCollections() {
        let s = Settings.shared
        // 절반만 완성 — 도감 하단 업적 그리드에서 컬러/그레이가 함께 보이게.
        let done = PetCollection.allCases.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        s.completedCollections = Set(done.map(\.rawValue))
        s.collectionCompletedAt = Dictionary(uniqueKeysWithValues: done.map {
            ($0.rawValue, Date(timeIntervalSince1970: 1_780_000_000))
        })
    }

    /// 세 차트 파티를 각각 3마리로 채운다. 비어 있으면 파티 탭이 플레이스홀더만 나온다.
    static func seedParty() {
        let s = Settings.shared
        let picks: [PetChartSource: [PetKind]] = [
            .claude: [.fox, .wolf, .bear],
            .cursor: [.slime, .goblin, .bat],
            .codex:  [.warrior, .lancer, .monk],
        ]
        for (source, kinds) in picks {
            let members = kinds.enumerated().map { PetSelection(kind: $0.element, variant: $0.offset % 3) }
            s.setPresetMembers(s.presetID(for: source), members)
        }
        s.petClaudeKind = .fox
        s.petCursorKind = .slime
    }

    static func seedCosmetics() {
        let s = Settings.shared
        s.ownedAccessories = Set(CardAccessory.allCases.map(\.rawValue))
        s.ownedTitles = Set(CardTitle.allCases.map(\.rawValue))
        s.ownedThemes = Set(PetTheme.allCases.map(\.rawValue))
    }

    // MARK: - 파생 값

    static var trainerStats: TrainerStats { TrainerStats.compute(from: Settings.shared) }

    static var badgeRows: [TrainerCardView.BadgeRow] {
        let cleared = Settings.shared.clearedBadges
        return BadgeCategory.allCases.map { category in
            TrainerCardView.BadgeRow(
                category: category,
                cleared: BadgeTier.allCases.contains { cleared.contains(BadgeID(category: category, tier: $0).key) },
                available: true)
        }
    }

    static var collectionRows: [(PetCollection, Bool)] {
        let done = Settings.shared.completedCollections
        return PetCollection.allCases.map { ($0, done.contains($0.rawValue)) }
    }

    /// 길드 사무실 프리뷰용 응답. `GuildOfficeDemo`가 만드는 것과 같은 모양이되,
    /// 창을 띄우지 않고 뷰에 바로 주입할 수 있게 값만 돌려준다.
    static func guildInfo() -> RankingAPI.GuildInfoResponse {
        func member(_ nick: String, kind: PetKind, variant: Int = 0, vp: Int,
                    top: Bool, me: Bool = false, slot: Int? = nil) -> RankingAPI.GuildMember {
            var card = TrainerCard.default
            card.avatar = PetSelection(kind: kind, variant: variant)
            let profile = ProfileState(
                card: card, trainerID: "DEMO", stats: trainerStats,
                clearedBadges: Array(Settings.shared.clearedBadges),
                completedCollections: Array(Settings.shared.completedCollections),
                backup: nil, equippedEffects: [], integrityViolation: false,
                guildName: "데드락클럽")
            return RankingAPI.GuildMember(
                nickname: nick, monthlyVP: vp, isTopContributor: top, officeSlot: slot,
                isLeader: me, isMe: me, joinedAt: Date(timeIntervalSince1970: 1_780_000_000),
                githubLogin: nil, profileJson: profile, deviceId: nil)
        }
        let members = [
            member("dowoon", kind: .fox, variant: 1, vp: 3120, top: true, me: true, slot: 0),
            member("kimcoder", kind: .warrior, vp: 2400, top: true, slot: 1),
            member("vibewolf", kind: .wolf, variant: 4, vp: 1800, top: true, slot: 2),
            member("nightowl", kind: .whale, vp: 700, top: true, slot: 3),
            member("lurker42", kind: .ninjaFrog, vp: 400, top: true),
            member("ghostdev", kind: .slime, vp: 0, top: false),
        ]
        // 가구는 슬롯을 앞에서부터 채운다 — 배치 로직과 빈 슬롯 표시를 함께 보기 위해 일부만.
        let furniture = (0..<6).map {
            RankingAPI.GuildFurnitureItem(slotId: $0, itemKind: String(OfficeLayout.furnitureCatalog[$0 % OfficeLayout.furnitureCatalog.count].id),
                                          donorNickname: members[$0 % members.count].nickname)
        }
        let guild = RankingAPI.GuildInfo(
            id: "demo-guild", name: "데드락클럽", inviteCode: "DEMO12", isLeader: true,
            floorTheme: 1, wallTheme: 2, officeFurniture: nil,
            logo: "sample:3", logoX: nil, logoY: nil,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            score: 8_540, rank: 3, memberCount: members.count)
        return RankingAPI.GuildInfoResponse(guild: guild, members: members, furniture: furniture,
                                            sentInvites: nil, joinRequests: nil)
    }
}
