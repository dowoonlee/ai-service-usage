import SwiftUI

/// 펫 75종을 의미 단위로 묶는 컬렉션 (도감의 "셋 보너스" 단위).
///
/// 한 컬렉션의 모든 base 펫(variant 0)을 보유하면 "컴플리트" — 1회성 코인 보너스 + 도감
/// 업적 섹션에 영구 등재. 기존 rarity 섹션 레이아웃은 그대로 두고, 도감 하단에 별도
/// 업적 섹션으로만 노출 (기존 동선 보존).
///
/// 각 컬렉션의 정체성은 dev 컬쳐 밈 — `displayName`이 코드네임, `subtitle`이 한 줄 농담.
/// 톤은 기존 `BadgeRegistry`의 region/category(Coffee/Vibe/Cron/Repo, Standup/Heartbeat 등)와
/// 일관: 영어 짧은 단어, DevOps·LLM 메타포, 자조 섞인 농담.
///
/// 멤버 매핑(`PetKind → PetCollection`)은 `PetTraits.swift`의 extension에. 미래에 다른
/// trait(예: element/archetype)을 추가할 때 기존 매핑 라인을 건드리지 않도록 trait별로
/// extension 분리.
enum PetCollection: String, CaseIterable, Codable {
    case mainframe          // "Works on My Machine"  — 야생 포유류
    case dns                // "It's Always DNS"       — 하늘 친구
    case npmInstall         // "npm install"           — 땅 위 작은 친구
    case nodeModules        // "node_modules"          — 돼지족
    case todoSince2019      // "TODO Since 2019"       — 자연물·정령
    case wontfix            // "WONTFIX"               — 언데드
    case fridayDeploy       // "Friday Deploy"         — 악마·괴물
    case vibeCoders         // "Vibe Coders"           — 모험가·전사
    case tokenBurners       // "Token Burners"         — 마법·신성·왕족
    case rustEvangelists    // "Rust Evangelists"      — 이종족 전사
    case noVerify           // "--no-verify"           — 해적단
    case happyPath          // "Happy Path"            — 밝고 귀여운 마스코트 (메이플풍)
    case onCall             // "On-Call"               — Tiny Swords 엘리트 기사단 (Mythic/Legendary)
    case ciRunners          // "CI Runners"            — 0x72 로봇 (자동화 봇)
    case helloWorld         // "Hello World"           — GrafxKid 레트로 플랫포머 마스코트

    var displayName: String {
        switch self {
        case .mainframe:        return "Works on My Machine"
        case .dns:              return "It's Always DNS"
        case .npmInstall:       return "npm install"
        case .nodeModules:      return "node_modules"
        case .todoSince2019:    return "TODO Since 2019"
        case .wontfix:          return "WONTFIX"
        case .fridayDeploy:     return "Friday Deploy"
        case .vibeCoders:       return "Vibe Coders"
        case .tokenBurners:     return "Token Burners"
        case .rustEvangelists:  return "Rust Evangelists"
        case .noVerify:         return "--no-verify"
        case .happyPath:        return "Happy Path"
        case .onCall:           return "On-Call"
        case .ciRunners:        return "CI Runners"
        case .helloWorld:       return "Hello World"
        }
    }

    /// 도감 카드용 한 줄 농담. 각 컬렉션의 정체성을 굳히는 카피.
    var subtitle: String {
        switch self {
        case .mainframe:        return "어제까지 잘 돌아갔다는 그 환경"
        case .dns:              return "장애 원인의 99%, 그 수상한 새들"
        case .npmInstall:       return "영원히 끝나지 않는 의존성 지옥"
        case .nodeModules:      return "우주에서 가장 무거운 폴더"
        case .todoSince2019:    return "5년째 박혀있는 주석들의 무덤"
        case .wontfix:          return "닫혀도 닫혀도 살아 돌아오는 issue"
        case .fridayDeploy:     return "금요일 오후 5시에 풀린 그것들"
        case .vibeCoders:       return "그냥 vibe로 짜는 사람들"
        case .tokenBurners:     return "context window를 통째로 태우는 마법사들"
        case .rustEvangelists:  return "Have you tried rewriting it in Rust?"
        case .noVerify:         return "hook? 그게 뭔데"
        case .happyPath:        return "엣지 케이스 없는, 그 평화로운 실행 경로"
        case .onCall:           return "삐삐가 울릴 때마다 출동하는 정예들"
        case .ciRunners:        return "새벽 3시에도 묵묵히 빌드 돌리는 무쇠팔들"
        case .helloWorld:       return "누구나 처음 찍어보는, 그 한 줄의 마스코트들"
        }
    }

    /// 컬렉션 액센트 컬러. 11개 모두 충분한 색상 거리(hue 30°+ 간격) — 인접 그룹이
    /// 시각적으로 구분되도록 의도적으로 분산. 미완성 그룹은 회색으로 처리(`GachaView`)하므로
    /// 이 색은 완성 그룹 표시 + 완성 배너에서만 노출.
    var accentColor: Color {
        switch self {
        case .mainframe:        return Color(red: 0.65, green: 0.50, blue: 0.35)  // sandy brown
        case .dns:              return Color(red: 0.40, green: 0.65, blue: 0.85)  // sky blue
        case .npmInstall:       return Color(red: 0.90, green: 0.65, blue: 0.20)  // amber
        case .nodeModules:      return Color(red: 0.25, green: 0.30, blue: 0.55)  // navy
        case .todoSince2019:    return Color(red: 0.55, green: 0.55, blue: 0.30)  // olive
        case .wontfix:          return Color(red: 0.55, green: 0.30, blue: 0.65)  // purple
        case .fridayDeploy:     return Color(red: 0.85, green: 0.25, blue: 0.25)  // red
        case .vibeCoders:       return Color(red: 0.30, green: 0.55, blue: 0.35)  // forest green
        case .tokenBurners:     return Color(red: 0.85, green: 0.30, blue: 0.65)  // magenta
        case .rustEvangelists:  return Color(red: 0.80, green: 0.35, blue: 0.15)  // rust
        case .noVerify:         return Color(red: 0.20, green: 0.55, blue: 0.55)  // teal
        case .happyPath:        return Color(red: 0.55, green: 0.80, blue: 0.40)  // lime
        case .onCall:           return Color(red: 0.42, green: 0.50, blue: 0.62)  // steel blue-gray
        case .ciRunners:        return Color(red: 0.25, green: 0.72, blue: 0.82)  // electric cyan
        case .helloWorld:       return Color(red: 0.96, green: 0.58, blue: 0.42)  // warm coral
        }
    }

    /// 뱃지 가운데에 들어가는 SF Symbol — 코드네임의 dev 농담을 시각화.
    /// 가능한 한 의미적 매핑 (예: tokenBurners → flame, noVerify → bolt.slash).
    var iconSystemImage: String {
        switch self {
        case .mainframe:        return "server.rack"                        // 빈티지 대형 시스템
        case .dns:              return "network"                            // 네트워크/DNS
        case .npmInstall:       return "hourglass"                          // 영원한 기다림
        case .nodeModules:      return "shippingbox.fill"                   // 무거운 박스
        case .todoSince2019:    return "note.text"                          // 박힌 메모
        case .wontfix:          return "exclamationmark.bubble.fill"        // 닫혀도 살아 돌아옴
        case .fridayDeploy:     return "calendar.badge.exclamationmark"     // 금요일 + 위험
        case .vibeCoders:       return "music.note"                         // 그냥 vibe로
        case .tokenBurners:     return "flame.fill"                         // 토큰 태우기
        case .rustEvangelists:  return "wrench.and.screwdriver.fill"        // systems programming
        case .noVerify:         return "bolt.slash.fill"                    // hook 무시
        case .happyPath:        return "sun.max.fill"                       // 엣지 케이스 없는 평화
        case .onCall:           return "shield.lefthalf.filled"             // 프로덕션 수호 기사단
        case .ciRunners:        return "gearshape.2.fill"                   // 자동화 러너/봇
        case .helloWorld:       return "hand.wave.fill"                     // 첫 인사, 입문 마스코트
        }
    }

    /// 도감 정렬 순서로 멤버 펫 반환 — 컬렉션 카드의 멤버 미리보기 그리드 순서와 일치.
    /// 각 멤버의 rarity는 `Gacha.pool` 역인덱스로 계산하므로 여기서는 순수 멤버십만 정의.
    var members: [PetKind] {
        switch self {
        case .mainframe:
            return [.fox, .wolf, .bear, .boar, .deer, .rabbit, .bunny, .rino, .grizzly]
        case .dns:
            return [.bat, .bee, .blueBird, .chicken, .duck, .fatBird, .chiChiBird, .orchidOwl, .penguin]
        case .npmInstall:
            return [.chameleon, .turtle, .snail, .slug, .tinySlug, .snipCrab,
                    .hermie, .roach, .squirmyWormy, .moeScotty]
        case .nodeModules:
            return [.angryPig, .kingPig, .pig, .pigBoxer, .pigBomber]
        case .todoSince2019:
            return [.mushroom, .slime, .plant, .radish, .trunk, .rock1, .rock2, .rock3,
                    .bushly, .gloppySlime, .wispyFire, .fairy, .angie]
        case .wontfix:
            return [.ghost, .skull, .necromancer, .skelet, .tinyZombie, .iceZombie, .zombie, .bigZombie,
                    .blankey, .skeletonG]
        case .fridayDeploy:
            return [.chort, .pumpkinDude, .imp, .muddy, .swampy, .bigDemon, .ogre, .wogol, .devoDevil,
                    .martianRed, .bigRed, .mrChomps]
        case .vibeCoders:
            return [.maskDude, .ninjaFrog, .dwarfF, .dwarfM, .elfF, .elfM, .knightF, .knightM, .geralt,
                    .diego, .holly, .gordon, .toggle, .tracy, .armand]
        case .tokenBurners:
            return [.wizardF, .wizardM, .doc, .angel, .kingHuman, .lilWiz]
        case .rustEvangelists:
            return [.maskedOrc, .orcShaman, .orcWarrior, .lizardF, .lizardM, .goblin, .orc]
        case .noVerify:
            return [.bombGuy, .baldPirate, .cucumber, .bigGuy, .pirateCaptain, .whale, .clownCaptain, .fierceTooth]
        case .happyPath:
            return [.jellySlime, .sunFrog, .oposum, .sunFox]
        case .onCall:
            return [.warrior, .lancer, .monk, .archer, .pawn]
        case .ciRunners:
            return [.scrapBot, .antennaBot, .pixelBot, .spiderBot, .sentryBot,
                    .miniBot, .visorBot, .batBot, .beaconBot,
                    .roboPumpkin, .roboTotem, .gumBot, .robotJ5,
                    .robotWalky, .mrCircuit, .roboRetro]
        case .helloWorld:
            return [.mrMan, .bumpyBot, .princessSera, .rollingNero, .diverFish,
                    .bub, .spikeyBub, .pokeyBub, .blockyBub,
                    .onionLad, .mrMochi, .octi, .daikon, .rocketCherry, .cheesePuff,
                    .twiggy, .tommy,
                    .agentMike, .ballooney, .jumpyLumpy, .orangeFruit, .percy, .vessa, .barryCherry]
        }
    }
}

extension PetCollection {
    /// base 펫(variant 0) 모두 보유 = 컴플리트. variant 풀세트는 별도 보너스로 분리 가능.
    @MainActor
    func isComplete(_ s: Settings) -> Bool {
        members.allSatisfy { (s.ownedPets[$0]?.count ?? 0) > 0 }
    }

    /// (collected, total) — 도감 카드의 진행도 표시(예: "5/8") 용.
    @MainActor
    func progress(_ s: Settings) -> (collected: Int, total: Int) {
        let collected = members.reduce(0) { $0 + ((s.ownedPets[$1]?.count ?? 0) > 0 ? 1 : 0) }
        return (collected, members.count)
    }

    /// 셋 보너스 곱셈 — 단일 멤버 가치 합 대비 1.5배 추가. "왜 1.5?" — 멤버 하나하나 가챠로
    /// 뽑을 때 받는 코인보다 셋 완성에 의미 있는 보너스가 붙어야 컬렉션 동기 유발이 됨.
    /// 너무 크면 가챠 밸런스가 망가지고, 1.0(추가 없음)이면 셋 완성 의미가 약함. 1.5는 절충.
    static let setBonusMultiplier: Double = 1.5

    /// `Σ(member rarity coinValue) × setBonusMultiplier`. rarity 분포가 자동 반영되므로
    /// Common-heavy 그룹과 Legendary-mix 그룹의 보상이 자연스럽게 차등.
    var bonusCoins: Int {
        let sum = members.reduce(0) { $0 + (PetKind.rarityFor($1)?.coinValue ?? Rarity.common.coinValue) }
        return Int(Double(sum) * Self.setBonusMultiplier)
    }
}

/// 컬렉션 컴플리트 평가 + 보상 + 이펙트 트리거. `Gacha.commit(_:)` 직후 호출.
/// dedup은 `Settings.completedCollections`(rawValue Set) — `BadgeRegistry`의 `clearedBadges`
/// 와 동일 패턴. 한 번 컴플리트된 컬렉션은 ownedPets가 어떤 이유로 비워져도 재지급 안 됨.
@MainActor
enum PetCollectionRegistry {
    /// - Parameter silent: 단발성 컴플리트 배너(`pendingCollectionCelebration`)는 set 안 함.
    ///   기본 `false`(가챠 commit 경로) — 한 번에 하나의 컬렉션만 컴플리트되므로 배너 1개로 충분.
    ///   `true`(마이그레이션 경로) — 다중 컴플리트가 동시 발생할 수 있는데 단일 String? 배너로는
    ///   마지막 1개만 노출되는 한계가 있으니 강조 표시(`pendingCollectionHighlights`)에 인지를 위임.
    static func evaluate(silent: Bool = false) {
        let s = Settings.shared
        for c in PetCollection.allCases where !s.completedCollections.contains(c.rawValue) {
            guard c.isComplete(s) else { continue }
            s.completedCollections.insert(c.rawValue)
            s.collectionCompletedAt[c.rawValue] = Date()
            s.pendingCollectionHighlights.insert(c.rawValue)
            if !silent {
                s.pendingCollectionCelebration = c.rawValue
            }
            CoinLedger.shared.creditCollectionBonus(c)
        }
    }
}
