import Foundation
import SwiftUI

/// 트레이너 카드 customization 상태. Report 탭의 메인 데이터 모델.
///
/// 4 레이어로 구성:
///   1. **Avatar** — 보유 펫 + variant
///   2. **Background** — PetTheme 또는 컴플리트한 컬렉션 색
///   3. **Frame** — 외곽 장식 (도장 진척 자동 unlock)
///   4. **Title** — 칭호 (코인/도장/컬렉션 자동 + 일부 코인 구매)
/// + **Accessory** — 펫 sprite 위 layer (가챠/구매 인벤토리)
/// + **Layout** — 정렬 옵션 (avatar 위치, 표시 토글)
struct TrainerCard: Codable, Hashable {
    var avatar: PetSelection
    var background: TrainerBackground
    var frame: CardFrame
    var title: CardTitle
    /// nil이면 액세서리 미착용.
    var accessory: CardAccessory?
    /// 액세서리 위치·크기 transform. drag/slider로 사용자가 직접 조정. nil이면 `.default`.
    /// Codable 호환성을 위해 Optional — 기존(v0.7.0/v0.7.1) 영속화 카드에 이 필드가
    /// 없어도 누락(nil)로 decode 가능. 호출 측은 `?? .default`로 fallback.
    var accessoryTransform: AccessoryTransform?
    var layout: CardLayout

    /// 사용자 의도에 따른 effective transform — nil이면 default.
    var effectiveAccessoryTransform: AccessoryTransform {
        accessoryTransform ?? .default
    }

    static let `default` = TrainerCard(
        avatar: PetSelection(kind: .fox, variant: 0),
        background: .theme(.grassland),
        frame: .none,
        title: .newcomer,
        accessory: nil,
        accessoryTransform: nil,
        layout: CardLayout()
    )
}

/// 액세서리 transform — 펫 sprite 기준 상대 offset + scale.
/// 기본값(0, -32, 1.0)은 펫 머리 위 중앙 + 50px 사이즈에 해당 (이전 hardcoded와 동일).
/// `Codable` decoding 시 누락 필드는 default로 fallback (Swift 기본 동작 X — 모든 필드
/// 명시적 default value로 처리).
struct AccessoryTransform: Codable, Hashable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = -32
    var scale: CGFloat = 1.0

    static let `default` = AccessoryTransform()

    /// drag/scale 한계 — 펫(110px) 영역을 너무 벗어나지 않도록 clamp용.
    static let offsetLimit: CGFloat = 80
    static let scaleRange: ClosedRange<CGFloat> = 0.4...2.5
}

/// 카드 배경 — PetTheme 4개 + 컴플리트한 컬렉션 11색까지 unlock 가능.
enum TrainerBackground: Codable, Hashable {
    case theme(PetTheme)
    case collection(String)  // PetCollection.rawValue

    /// 자동 unlock — 컴플리트한 컬렉션의 색은 즉시 사용 가능.
    /// PetTheme 4개는 기본 unlock, collection 색은 컬렉션 컴플리트로 unlock.
    @MainActor
    static func unlocked(in s: Settings) -> [TrainerBackground] {
        var out: [TrainerBackground] = PetTheme.allCases.map { .theme($0) }
        for c in PetCollection.allCases where s.completedCollections.contains(c.rawValue) {
            out.append(.collection(c.rawValue))
        }
        return out
    }

    var displayName: String {
        switch self {
        case .theme(let t):       return t.displayName
        case .collection(let r):  return PetCollection(rawValue: r)?.displayName ?? r
        }
    }

    @MainActor
    var fillTopColor: Color {
        switch self {
        case .theme(let t):       return t.topColor
        case .collection(let r):  return PetCollection(rawValue: r)?.accentColor ?? .gray
        }
    }

    @MainActor
    var fillBottomColor: Color {
        switch self {
        case .theme(let t):       return t.bottomColor
        case .collection(let r):  return (PetCollection(rawValue: r)?.accentColor ?? .gray).opacity(0.6)
        }
    }
}

/// 카드 외곽 프레임 — 4단계 자동 unlock. 도장·컬렉션 진척에 비례.
enum CardFrame: String, CaseIterable, Codable, Hashable {
    case none
    case bronze     // 도장 4뱃지
    case silver     // 도장 8뱃지
    case gold       // 챔피언 뱃지
    case sparkle    // 모든 컬렉션 컴플리트

    var displayName: String {
        switch self {
        case .none:     return "기본"
        case .bronze:   return "Bronze"
        case .silver:   return "Silver"
        case .gold:     return "Gold"
        case .sparkle:  return "Sparkle"
        }
    }

    var color: Color {
        switch self {
        case .none:     return .secondary.opacity(0.5)
        case .bronze:   return Color(red: 0.72, green: 0.45, blue: 0.20)
        case .silver:   return Color(red: 0.75, green: 0.75, blue: 0.78)
        case .gold:     return Color(red: 1.00, green: 0.78, blue: 0.00)
        case .sparkle:  return Color(red: 0.85, green: 0.30, blue: 0.85)
        }
    }

    /// 외곽선 두께. tier 올라갈수록 두꺼움.
    var lineWidth: CGFloat {
        switch self {
        case .none: return 1
        case .bronze: return 2
        case .silver: return 2.5
        case .gold: return 3
        case .sparkle: return 3.5
        }
    }

    /// 호버 popover에 노출할 unlock 조건.
    var unlockDescription: String {
        switch self {
        case .none:    return "기본 프레임 — 별도 조건 없음"
        case .bronze:  return "도장 4뱃지 클리어 시 unlock"
        case .silver:  return "도장 8뱃지 클리어 시 unlock"
        case .gold:    return "도장 챔피언 뱃지 획득 시 unlock"
        case .sparkle: return "11 컬렉션 셋 전부 컴플리트 시 unlock"
        }
    }

    @MainActor
    static func unlocked(in s: Settings) -> Set<CardFrame> {
        var set: Set<CardFrame> = [.none]
        let cleared = s.clearedBadges.count
        if cleared >= 4  { set.insert(.bronze) }
        if cleared >= 8  { set.insert(.silver) }
        if s.championBadgeEarnedAt != nil { set.insert(.gold) }
        if s.completedCollections.count >= PetCollection.allCases.count {
            set.insert(.sparkle)
        }
        return set
    }
}

/// 칭호 — 텍스트만. 진행도 자동 unlock 25개 + 코인 구매 13개 = 총 38개.
/// dev 자조 밈 + 게임 진행도 호칭이 섞인 톤. 사용자가 카드에 자랑하고 싶은 정체성 표현.
enum CardTitle: String, CaseIterable, Codable, Hashable {
    // ── 자동 unlock — 시작/기본 ──
    case newcomer                  // 시작 칭호 (항상 unlock)

    // ── 자동 unlock — 가챠 진행 ──
    case firstPull                 // 가챠 1회
    case pullAddict                // 가챠 100회
    case pullMaster                // 가챠 500회

    // ── 자동 unlock — 코인 누적 ──
    case coiner100                 // 누적 100
    case coiner1k                  // 누적 1,000
    case coiner10k                 // 누적 10,000
    case coiner100k                // 누적 100,000

    // ── 자동 unlock — 펫 도감 ──
    case petFriend15               // 15종 보유
    case petCollector40            // 40종 보유
    case petDexMaster              // 75종 보유
    case variantHunter             // 이로치 1+ 보유한 종 1개 이상
    case variantMaster             // 이로치 모두(3종) 보유한 종 1개 이상

    // ── 자동 unlock — 컬렉션 셋 ──
    case collector1                // 셋 1개
    case collector5                // 셋 5개
    case collectorAll              // 11 셋 전부

    // ── 자동 unlock — 도장 ──
    case fourBadges                // 도장 4뱃지
    case eightBadges               // 도장 8뱃지
    case champion                  // 챔피언 뱃지
    case stagingLead               // production tier 4개 클리어
    case prodOwner                 // 모든(가능한) production tier 클리어

    // ── 자동 unlock — Wellness ──
    case wellnessGuru              // 응답 50
    case wellnessLegend            // 응답 200

    // ── 자동 unlock — 사용 기간 ──
    case dayOneBeliever            // 첫 적립 7일+
    case veteran                   // 30일+
    case longHauler                // 90일+

    // ── 자동 unlock — 아레나 ──
    // 기획의 "10연승" 칭호는 레이팅·랭킹 칭호로 대체 확정(#166) — 연승 트래킹은 서버 pvp_matches
    // 히스토리 계산이 필요해 저우선 명명 정리 범위를 넘고, 아래 3개가 실력 지표를 이미 커버한다.
    case arenaRookie               // 아레나 첫 승리
    case arenaChallenger           // 레이팅 1200 도달
    case arenaChampion             // 아레나 랭킹 1위 도달

    // ── 자동 unlock — Vibe / OSS ──
    case vibeCoder                 // Claude+Cursor 5,000
    case vibeMaster                // Claude+Cursor 25,000
    case openSourceContributor     // PR 1+
    case openSourceVeteran         // PR 5+

    // ── 코인 구매 (dev 자조 밈) ──
    case worksOnMyMachine          // 1,000
    case fourOhFour                // 800
    case caffeineAddict            // 1,500
    case midnightHacker            // 1,500
    case rubberDuck                // 1,500
    case forcePusher               // 2,000
    case tabsNotSpaces             // 800
    case spacesNotTabs             // 800
    case vimConvert                // 1,000
    case stackOverflowHero         // 1,500
    case shippedItToProd           // 2,500
    case tenXEngineer              // 5,000
    case ceoOfVibes                // 10,000

    var displayName: String {
        switch self {
        // 자동 unlock
        case .newcomer:              return "신입 트레이너"
        case .firstPull:             return "첫 뽑기"
        case .pullAddict:            return "가챠 중독자"
        case .pullMaster:            return "가챠 마스터"
        case .coiner100:             return "동전 수집가"
        case .coiner1k:              return "코인 마스터"
        case .coiner10k:             return "코인 갑부"
        case .coiner100k:            return "코인 재벌"
        case .petFriend15:           return "펫 친구"
        case .petCollector40:        return "펫 수집가"
        case .petDexMaster:          return "펫 도감 마스터"
        case .variantHunter:         return "이로치 헌터"
        case .variantMaster:         return "이로치 마스터"
        case .collector1:            return "셋 헌터"
        case .collector5:            return "수집가"
        case .collectorAll:          return "도감 마스터"
        case .fourBadges:            return "4뱃지 도전자"
        case .eightBadges:           return "8뱃지 트레이너"
        case .champion:              return "도장 챔피언"
        case .stagingLead:           return "Staging Lead"
        case .prodOwner:             return "Prod Owner"
        case .wellnessGuru:          return "Wellness Guru"
        case .wellnessLegend:        return "Wellness Legend"
        case .dayOneBeliever:        return "Day One"
        case .veteran:               return "Veteran"
        case .longHauler:            return "Long Hauler"
        case .arenaRookie:           return "아레나 루키"
        case .arenaChallenger:       return "아레나 도전자"
        case .arenaChampion:         return "아레나 챔피언"
        case .vibeCoder:             return "Vibe Coder"
        case .vibeMaster:            return "Vibe Master"
        case .openSourceContributor: return "Open Source"
        case .openSourceVeteran:     return "OSS Veteran"
        // 구매 (dev 자조 밈)
        case .worksOnMyMachine:      return "Works On My Machine"
        case .fourOhFour:            return "404 Not Found"
        case .caffeineAddict:        return "Caffeine Addict"
        case .midnightHacker:        return "Midnight Hacker"
        case .rubberDuck:            return "Rubber Duck Whisperer"
        case .forcePusher:           return "Force Pusher"
        case .tabsNotSpaces:         return "Tabs Not Spaces"
        case .spacesNotTabs:         return "Spaces Not Tabs"
        case .vimConvert:            return "Vim Convert"
        case .stackOverflowHero:     return "Stack Overflow Hero"
        case .shippedItToProd:       return "Shipped It To Prod"
        case .tenXEngineer:          return "10x Engineer"
        case .ceoOfVibes:            return "CEO of Vibes"
        }
    }

    /// 호버 popover에 노출할 unlock 조건 문구.
    var unlockDescription: String {
        switch self {
        case .newcomer:              return "기본 칭호"
        case .firstPull:             return "가챠 1회 성공"
        case .pullAddict:            return "가챠 100회"
        case .pullMaster:            return "가챠 500회"
        case .coiner100:             return "누적 적립 100 coin"
        case .coiner1k:              return "누적 적립 1,000 coin"
        case .coiner10k:             return "누적 적립 10,000 coin"
        case .coiner100k:            return "누적 적립 100,000 coin"
        case .petFriend15:           return "펫 15종 보유"
        case .petCollector40:        return "펫 40종 보유"
        case .petDexMaster:          return "펫 75종 모두 보유"
        case .variantHunter:         return "이로치 1마리 이상 unlock"
        case .variantMaster:         return "한 종의 이로치 풀세트 (variant 0/1/2/3)"
        case .collector1:            return "컬렉션 셋 1개 컴플리트"
        case .collector5:            return "컬렉션 셋 5개 컴플리트"
        case .collectorAll:          return "11 컬렉션 셋 전부 컴플리트"
        case .fourBadges:            return "도장 4뱃지 클리어"
        case .eightBadges:           return "도장 8뱃지 클리어"
        case .champion:              return "도장 챔피언 뱃지 획득"
        case .stagingLead:           return "production tier 도장 4개 클리어"
        case .prodOwner:             return "가능한 모든 production tier 도장 클리어"
        case .wellnessGuru:          return "Wellness 응답 50회"
        case .wellnessLegend:        return "Wellness 응답 200회"
        case .dayOneBeliever:        return "첫 적립 후 7일 경과"
        case .veteran:               return "첫 적립 후 30일 경과"
        case .longHauler:            return "첫 적립 후 90일 경과"
        case .arenaRookie:           return "아레나 첫 승리"
        case .arenaChallenger:       return "아레나 레이팅 1200 도달"
        case .arenaChampion:         return "아레나 랭킹 1위 도달"
        case .vibeCoder:             return "Claude+Cursor 누적 코인 5,000"
        case .vibeMaster:            return "Claude+Cursor 누적 코인 25,000"
        case .openSourceContributor: return "GitHub 머지 PR 1개 이상"
        case .openSourceVeteran:     return "GitHub 머지 PR 5개 이상"
        // 구매 칭호
        case .worksOnMyMachine:      return "1,000 coin · \"내 컴퓨터선 됐어요\""
        case .fourOhFour:            return "800 coin · 칭호를 찾을 수 없습니다"
        case .caffeineAddict:        return "1,500 coin · 카페인이 곧 코드"
        case .midnightHacker:        return "1,500 coin · 새벽 3시의 영감"
        case .rubberDuck:            return "1,500 coin · 러버덕에게 설명하면 풀림"
        case .forcePusher:           return "2,000 coin · git push -f origin main"
        case .tabsNotSpaces:         return "800 coin · 탭이 정의이며 진리"
        case .spacesNotTabs:         return "800 coin · 스페이스가 옳다"
        case .vimConvert:            return "1,000 coin · :wq로 살아나가는 법"
        case .stackOverflowHero:     return "1,500 coin · 답변 reputation 10k+"
        case .shippedItToProd:       return "2,500 coin · 금요일 오후 5시"
        case .tenXEngineer:          return "5,000 coin · 모두가 부르는 그 사람"
        case .ceoOfVibes:            return "10,000 coin · 회사를 차렸다"
        }
    }

    /// 코인 구매 가격. nil이면 자동 unlock 전용.
    var purchasePrice: Int? {
        switch self {
        case .fourOhFour, .tabsNotSpaces, .spacesNotTabs:                  return 800
        case .worksOnMyMachine, .vimConvert:                               return 1000
        case .caffeineAddict, .midnightHacker, .rubberDuck,
             .stackOverflowHero:                                           return 1500
        case .forcePusher:                                                 return 2000
        case .shippedItToProd:                                             return 2500
        case .tenXEngineer:                                                return 5000
        case .ceoOfVibes:                                                  return 10000
        default: return nil
        }
    }

    @MainActor
    static func unlocked(in s: Settings) -> Set<CardTitle> {
        var set: Set<CardTitle> = [.newcomer]

        // ── 가챠 진행 ──
        let pulls = s.ownedPets.values.reduce(0) { $0 + $1.count }
        if pulls >= 1   { set.insert(.firstPull) }
        if pulls >= 100 { set.insert(.pullAddict) }
        if pulls >= 500 { set.insert(.pullMaster) }

        // ── 코인 누적 ──
        if s.coinsTotalEarned >= 100     { set.insert(.coiner100) }
        if s.coinsTotalEarned >= 1000    { set.insert(.coiner1k) }
        if s.coinsTotalEarned >= 10000   { set.insert(.coiner10k) }
        if s.coinsTotalEarned >= 100000  { set.insert(.coiner100k) }

        // ── 펫 도감 ──
        let petKindsOwned = s.ownedPets.count
        if petKindsOwned >= 15 { set.insert(.petFriend15) }
        if petKindsOwned >= 40 { set.insert(.petCollector40) }
        if petKindsOwned >= PetKind.allCases.count { set.insert(.petDexMaster) }
        let hasAnyVariant = s.ownedPets.values.contains { !$0.unlockedVariants.intersection([1, 2, 3]).isEmpty }
        if hasAnyVariant { set.insert(.variantHunter) }
        let hasAllVariants = s.ownedPets.values.contains { $0.unlockedVariants.isSuperset(of: [0, 1, 2, 3]) }
        if hasAllVariants { set.insert(.variantMaster) }

        // ── 컬렉션 셋 ──
        if s.completedCollections.count >= 1 { set.insert(.collector1) }
        if s.completedCollections.count >= 5 { set.insert(.collector5) }
        if s.completedCollections.count >= PetCollection.allCases.count {
            set.insert(.collectorAll)
        }

        // ── 도장 ──
        let cleared = s.clearedBadges.count
        if cleared >= 4 { set.insert(.fourBadges) }
        if cleared >= 8 { set.insert(.eightBadges) }
        if s.championBadgeEarnedAt != nil { set.insert(.champion) }
        // production tier 단계 칭호.
        let prodCleared = s.clearedBadges.filter { $0.hasSuffix(".production") }.count
        if prodCleared >= 4 { set.insert(.stagingLead) }
        if BadgeCategory.allCases.filter({ $0.isAvailable(s) })
            .allSatisfy({ s.clearedBadges.contains("\($0.rawValue).production") }) {
            set.insert(.prodOwner)
        }

        // ── Wellness ──
        if s.wellnessRespondedCount >= 50  { set.insert(.wellnessGuru) }
        if s.wellnessRespondedCount >= 200 { set.insert(.wellnessLegend) }

        // ── 사용 기간 (firstCreditedAt 기준) ──
        if let first = s.firstCreditedAt {
            let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
            if days >= 7  { set.insert(.dayOneBeliever) }
            if days >= 30 { set.insert(.veteran) }
            if days >= 90 { set.insert(.longHauler) }
        }

        // ── 아레나 ──
        if s.pvpWinsCache >= 1     { set.insert(.arenaRookie) }
        if s.pvpBestRating >= 1200 { set.insert(.arenaChallenger) }
        if s.pvpBestRank == 1      { set.insert(.arenaChampion) }

        // ── Vibe / OSS ──
        let vibe = s.claudeCoinsEarned + s.cursorCoinsEarned
        if vibe >= 5000  { set.insert(.vibeCoder) }
        if vibe >= 25000 { set.insert(.vibeMaster) }
        if !s.creditedPRNumbers.isEmpty { set.insert(.openSourceContributor) }
        if s.creditedPRNumbers.count >= 5 { set.insert(.openSourceVeteran) }

        // ── 코인 구매 칭호 (인벤토리에서 합산) ──
        for raw in s.ownedTitles {
            if let t = CardTitle(rawValue: raw) { set.insert(t) }
        }
        return set
    }
}

/// 액세서리 — 트레이너 카드의 펫 sprite 위 layer로 합성. 가챠/구매로 인벤토리에 추가.
///
/// `resourceName`이 가리키는 PNG가 `Resources/trainer-accessories/`에 있으면 그 sprite 사용,
/// 없으면 SF Symbol fallback (`fallbackSymbol`)으로 즉시 가시화. 추후 픽셀 sprite 자원이
/// 추가되면 자동 swap — 시스템 자체는 자원 유무와 무관하게 동작.
/// case 이름은 displayName/fallback symbol과 일관되도록 변경(`tshirt`, `gift`)했지만
/// rawValue는 v0.7.0/v0.7.1 사용자의 `ownedAccessories` 영속 데이터 호환을 위해 옛값
/// (`"scarf"`, `"ribbon"`) 그대로 유지. 결과: 코드 가독성 + 인벤토리 보존 둘 다 만족.
enum CardAccessory: String, CaseIterable, Codable, Hashable {
    case strawHat
    case glasses
    case crown
    case tshirt = "scarf"      // rawValue는 v0.7.0 호환
    case halo
    case mask
    case gift = "ribbon"        // rawValue는 v0.7.0 호환
    case headphones

    var displayName: String {
        switch self {
        case .strawHat:   return "밀짚 모자"
        case .glasses:    return "안경"
        case .crown:      return "왕관"
        case .tshirt:     return "티셔츠"
        case .halo:       return "후광"
        case .mask:       return "마스크"
        case .gift:       return "선물"
        case .headphones: return "헤드폰"
        }
    }

    /// PNG 파일명(확장자 제외). `Resources/trainer-accessories/<name>.png`.
    var resourceName: String { "accessory_\(rawValue)" }

    /// PNG 자원이 없을 때 fallback으로 표시할 SF Symbol.
    /// 시스템이 자원 유무와 무관하게 즉시 동작하도록 함 — 자원 추가는 incremental.
    var fallbackSymbol: String {
        switch self {
        case .strawHat:   return "graduationcap.fill"
        case .glasses:    return "eyeglasses"
        case .crown:      return "crown.fill"
        case .tshirt:     return "tshirt.fill"
        case .halo:       return "circle.dashed"
        case .mask:       return "theatermasks.fill"
        case .gift:       return "gift.fill"
        case .headphones: return "headphones"
        }
    }

    /// 코인 직접 구매 가격. 가챠 풀과 별도 — 사용자가 원하는 것만 살 수 있게.
    var price: Int {
        switch self {
        case .strawHat, .glasses, .tshirt: return 800
        case .gift, .mask, .headphones:    return 1500
        case .crown, .halo:                return 3000
        }
    }
}

/// 카드 정렬 옵션 — 사용자가 자유롭게 조정.
struct CardLayout: Codable, Hashable {
    var avatarPosition: AvatarPosition = .left
    var showBadges: Bool = true
    var showCollections: Bool = true
    var showStats: Bool = true

    enum AvatarPosition: String, Codable, CaseIterable, Hashable {
        case left, center, right

        var displayName: String {
            switch self {
            case .left:   return "왼쪽"
            case .center: return "가운데"
            case .right:  return "오른쪽"
            }
        }
    }
}

extension TrainerCard {
    /// 첫 launch 시 5자리 랜덤 ID 생성. `00000` ~ `99999` 균등.
    static func generateTrainerID() -> String {
        String(format: "%05d", Int.random(in: 0...99999))
    }
}
