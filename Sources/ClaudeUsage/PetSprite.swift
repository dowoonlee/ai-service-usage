import AppKit
import SwiftUI

// 두 개의 sprite 출처를 함께 쓴다:
//   - Animated Wild Animals (CC0, ScratchIO): 동물 6종, sprite는 모두 좌향
//   - Pixel Adventure 1 (CC0, Pixel Frog):    캐릭터 4종, sprite는 모두 우향
// 둘 다 동작별 strip PNG (frame i → x: i*cellW, y: 0). PetController가
// (action, frameIndex)를 들고 있고, 여기서 잘린 프레임을 캐시.

/// 한 펫 종(kind)의 모든 메타데이터를 한 자리에 모은 레코드.
/// PetKind 케이스를 추가할 때 `displayName/cellSize/defaultFacingLeft/resourceName`
/// switch를 따로 늘릴 필요 없이 `PetKind.def` 한 곳만 수정하면 된다.
struct PetDefinition {
    /// 파일 prefix (예: "Fox", "MaskDude"). action별 suffix를 붙여 PNG basename을 구성.
    let prefix: String
    /// UI에 표시할 한국어 이름.
    let displayName: String
    /// 단일 frame 셀 크기. 같은 animation strip은 cellW × frameCount × cellH.
    let cellSize: (w: Int, h: Int)
    /// sprite 원본 그림이 좌측을 향하는지. 진행 방향과 다르면 가로 반전.
    /// 팩 단위가 아니라 스프라이트마다 개별로 다르니 새 종 추가 시 실제 그림을 보고 지정할 것.
    let defaultFacingLeft: Bool
    /// 동작별 PNG suffix. 종에 따라 alias가 다르다:
    ///   - Rabbit walk = "Hop", Wolf idle = "Howl"
    ///   - Pixel Adventure (Mask Dude/Ninja Frog/Mushroom): walk strip이 없어 "Run"으로 통합
    ///   - Slime: 모든 action이 한 "IdleRun" strip 공유
    let walkSuffix: String
    let runSuffix: String
    let idleSuffix: String
    /// 펫이 기본 사용할 테마 (사용자가 override 안 했을 때).
    let defaultTheme: PetTheme

    /// (action) → 해당 strip PNG의 basename.
    func resourceName(for action: PetController.Action) -> String {
        let suffix: String
        switch action {
        case .walk:                  suffix = walkSuffix
        case .run:                   suffix = runSuffix
        case .sit, .scan, .quote,
             .special1, .special2:   suffix = idleSuffix   // special은 PetKind에서 Mythic 조회로 가로챔
        }
        return "\(prefix)_\(suffix)"
    }
}

enum PetKind: String, CaseIterable, Identifiable, Codable {
    // wild-animals
    case fox
    case wolf
    case bear
    case boar
    case deer
    case rabbit
    // pixel-adventure
    case maskDude
    case ninjaFrog
    case mushroom
    case slime
    // pixel-adventure-2 (PA2 enemies)
    case angryPig
    case bat
    case bee
    case blueBird
    case bunny
    case chameleon
    case chicken
    case duck
    case fatBird
    case ghost
    case plant
    case radish
    case rino
    case rock1
    case rock2
    case rock3
    case skull
    case snail
    case trunk
    case turtle
    // 0x72 DungeonTileset II — heroes (16x28)
    case dwarfF, dwarfM
    case elfF, elfM
    case knightF, knightM
    case lizardF, lizardM
    case wizardF, wizardM
    // 0x72 — tall enemies (16x23) idle+run
    case chort, doc, maskedOrc, orcShaman, orcWarrior, pumpkinDude, wogol
    // 0x72 — tall single-anim (16x23)
    case necromancer, slug
    // 0x72 — small enemies (16x16) idle+run
    case angel, goblin, imp, skelet, tinyZombie
    // 0x72 — small single-anim (16x16)
    case iceZombie, muddy, swampy, tinySlug, zombie
    // 0x72 — big (32x36)
    case bigDemon, bigZombie, ogre
    // Kings and Pigs
    case kingHuman, kingPig, pig, pigBoxer, pigBomber
    // Pirate Bomb
    case bombGuy, baldPirate, cucumber, bigGuy, pirateCaptain, whale
    // Treasure Hunters (free demo)
    case clownCaptain, fierceTooth
    // Calciumtrice Animated Slime (CC-BY 3.0)
    case jellySlime
    // Ansimuz Sunny Land (CC0)
    case sunFox, sunFrog, oposum
    // Tiny Swords (Pixel Frog, CC0) — Mythic/Legendary 신규
    case warrior, lancer, monk, archer, pawn
    // 0x72 16x16+ Robot Tileset (CC0) — "CI Runners" 컬렉션. 전부 우향, Idle 4f / Run 8f.
    case scrapBot, antennaBot, pixelBot, spiderBot, sentryBot, miniBot, visorBot, batBot, beaconBot
    // GrafxKid Sprite Pack 1 (CC0) — 레트로 플랫포머 마스코트. 전부 우향, 16x16(세라만 16x32).
    case mrMan, bumpyBot, princessSera, bushly, devoDevil, rollingNero, gloppySlime
    case chiChiBird, diverFish, bub, spikeyBub, pokeyBub, blockyBub
    // GrafxKid Sprite Pack 2 (CC0) — 음식·사물 마스코트. 전부 우향, 셀 크기 다양.
    case onionLad, mrMochi, octi, roboPumpkin, daikon, roboTotem, rocketCherry, cheesePuff, snipCrab
    // GrafxKid Sprite Pack 3 (CC0) — 로봇·모험가. 전부 우향, 32x32.
    case gumBot, twiggy, robotJ5, tommy, geralt
    // GrafxKid Sprite Pack 4 (CC0)
    case agentMike, martianRed, hermie, ballooney, robotWalky, jumpyLumpy, orchidOwl, roach, mrCircuit, blankey
    // GrafxKid Sprite Pack 5 (CC0)
    case roboRetro, lilWiz, bigRed, squirmyWormy, moeScotty, mrChomps, grizzly, orc, wispyFire
    // GrafxKid Sprite Pack 6 (CC0)
    case penguin, fairy, skeletonG, orangeFruit
    // GrafxKid Sprite Pack 7 (CC0)
    case diego, holly, gordon
    // GrafxKid Sprite Pack 8 (CC0)
    case toggle, tracy, armand, percy, vessa, angie, barryCherry
    // LuizMelo Monsters Creatures Fantasy (CC0) — 다크판타지 몬스터 (150px 캔버스 bbox 트림)
    case flyingEye, goblinBrute, myconid, skeletonLord
    // Superpowers prehistoric-platformer (CC0, pixel-boy) — 공룡. 좌향, 멀티애니 그리드 트림.
    case dinoBat, dinoDragon, dinoBug, dinoLizard, miniRex, dinoPlant, pterodactyl, dinoTurtle, tRex
    // Superpowers prehistoric characters (CC0) — 원시부족. 우향, 그리드 트림.
    case caverman, caveGirl, caveGirl1, dragonMan, lionWarrior, littleCaveBoy
    // LuizMelo 히어로/몬스터/반려동물 (CC0) — 우향, 정사각 프레임 bbox 트림
    case heroKnight, huntress, evilWizard, medievalKing, martialHero, fantasyWarrior, fireWorm
    case vampireBat, mimic, giantRat, kingSlime
    case cat1, cat2, cat3, cat4, cat5, cat6
    case akita, goldenRetriever, greatDane, saintBernard, schnauzer, husky

    var id: String { rawValue }

    var def: PetDefinition {
        switch self {
        case .fox:
            return PetDefinition(prefix: "Fox", displayName: "여우",
                                 cellSize: (64, 36), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .wolf:
            return PetDefinition(prefix: "Wolf", displayName: "늑대",
                                 cellSize: (64, 40), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Howl",
                                 defaultTheme: .wilderness)
        case .bear:
            return PetDefinition(prefix: "Bear", displayName: "곰",
                                 cellSize: (64, 33), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .boar:
            return PetDefinition(prefix: "Boar", displayName: "멧돼지",
                                 cellSize: (64, 40), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .deer:
            return PetDefinition(prefix: "Deer", displayName: "사슴",
                                 cellSize: (72, 52), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .rabbit:
            return PetDefinition(prefix: "Rabbit", displayName: "토끼",
                                 cellSize: (32, 26), defaultFacingLeft: true,
                                 walkSuffix: "Hop", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .maskDude:
            return PetDefinition(prefix: "MaskDude", displayName: "마스크 영웅",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .ninjaFrog:
            return PetDefinition(prefix: "NinjaFrog", displayName: "닌자 개구리",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .mushroom:
            return PetDefinition(prefix: "Mushroom", displayName: "버섯",
                                 cellSize: (32, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .slime:
            return PetDefinition(prefix: "Slime", displayName: "슬라임",
                                 cellSize: (44, 30), defaultFacingLeft: true,
                                 walkSuffix: "IdleRun", runSuffix: "IdleRun", idleSuffix: "IdleRun",
                                 defaultTheme: .wilderness)
        case .angryPig:
            return PetDefinition(prefix: "AngryPig", displayName: "성난 돼지",
                                 cellSize: (36, 30), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .bat:
            return PetDefinition(prefix: "Bat", displayName: "박쥐",
                                 cellSize: (46, 30), defaultFacingLeft: true,
                                 walkSuffix: "Flying", runSuffix: "Flying", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .bee:
            return PetDefinition(prefix: "Bee", displayName: "벌",
                                 cellSize: (36, 34), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .blueBird:
            return PetDefinition(prefix: "BlueBird", displayName: "파랑새",
                                 cellSize: (32, 32), defaultFacingLeft: true,
                                 walkSuffix: "Flying", runSuffix: "Flying", idleSuffix: "Flying",
                                 defaultTheme: .grassland)
        case .bunny:
            return PetDefinition(prefix: "Bunny", displayName: "버니",
                                 cellSize: (34, 44), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .chameleon:
            return PetDefinition(prefix: "Chameleon", displayName: "카멜레온",
                                 cellSize: (84, 38), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .chicken:
            return PetDefinition(prefix: "Chicken", displayName: "닭",
                                 cellSize: (32, 34), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .duck:
            return PetDefinition(prefix: "Duck", displayName: "오리",
                                 cellSize: (36, 36), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .fatBird:
            return PetDefinition(prefix: "FatBird", displayName: "뚱뚱한 새",
                                 cellSize: (40, 48), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .ghost:
            return PetDefinition(prefix: "Ghost", displayName: "유령",
                                 cellSize: (44, 30), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .plant:
            return PetDefinition(prefix: "Plant", displayName: "식인 식물",
                                 cellSize: (44, 42), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .radish:
            return PetDefinition(prefix: "Radish", displayName: "무",
                                 cellSize: (30, 38), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .rino:
            return PetDefinition(prefix: "Rino", displayName: "코뿔소",
                                 cellSize: (52, 34), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .rock1:
            // Rock1~3 동일 아트.
            return PetDefinition(prefix: "Rock1", displayName: "큰 돌",
                                 cellSize: (38, 34), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .rock2:
            return PetDefinition(prefix: "Rock2", displayName: "돌",
                                 cellSize: (32, 28), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .rock3:
            return PetDefinition(prefix: "Rock3", displayName: "작은 돌",
                                 cellSize: (22, 18), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .skull:
            return PetDefinition(prefix: "Skull", displayName: "해골",
                                 cellSize: (52, 54), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .snail:
            return PetDefinition(prefix: "Snail", displayName: "달팽이",
                                 cellSize: (38, 24), defaultFacingLeft: true,
                                 walkSuffix: "Walk", runSuffix: "Walk", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .trunk:
            return PetDefinition(prefix: "Trunk", displayName: "통나무",
                                 cellSize: (64, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .turtle:
            return PetDefinition(prefix: "Turtle", displayName: "거북",
                                 cellSize: (44, 26), defaultFacingLeft: true,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        // ─── 0x72 DungeonTileset II ────────────────────────────────────────
        // 모든 sprite는 우향 (defaultFacingLeft: false). idle/run 4프레임 strip.
        // 4종은 idle/run 분리, 7종은 단일 anim cycle (Idle.png == Run.png 동일 strip).
        case .dwarfF:
            return PetDefinition(prefix: "DwarfF", displayName: "여전사 드워프",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .dwarfM:
            return PetDefinition(prefix: "DwarfM", displayName: "드워프 전사",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .elfF:
            return PetDefinition(prefix: "ElfF", displayName: "여엘프 궁수",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .elfM:
            return PetDefinition(prefix: "ElfM", displayName: "엘프 궁수",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .knightF:
            return PetDefinition(prefix: "KnightF", displayName: "여기사",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .knightM:
            return PetDefinition(prefix: "KnightM", displayName: "기사",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .lizardF:
            return PetDefinition(prefix: "LizardF", displayName: "여도마뱀 인간",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .lizardM:
            return PetDefinition(prefix: "LizardM", displayName: "도마뱀 인간",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .wizardF:
            return PetDefinition(prefix: "WizardF", displayName: "여마법사",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .wizardM:
            return PetDefinition(prefix: "WizardM", displayName: "마법사",
                                 cellSize: (16, 28), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        case .chort:
            return PetDefinition(prefix: "Chort", displayName: "도깨비",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .doc:
            return PetDefinition(prefix: "Doc", displayName: "의사",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .maskedOrc:
            return PetDefinition(prefix: "MaskedOrc", displayName: "가면 오크",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .orcShaman:
            return PetDefinition(prefix: "OrcShaman", displayName: "오크 주술사",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .orcWarrior:
            return PetDefinition(prefix: "OrcWarrior", displayName: "오크 전사",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .pumpkinDude:
            return PetDefinition(prefix: "PumpkinDude", displayName: "호박 인간",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .wogol:
            return PetDefinition(prefix: "Wogol", displayName: "워골",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // 단일 anim — Idle/Run 모두 같은 strip을 본다.
        case .necromancer:
            return PetDefinition(prefix: "Necromancer", displayName: "강령술사",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .slug:
            return PetDefinition(prefix: "Slug", displayName: "민달팽이",
                                 cellSize: (16, 23), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        case .angel:
            return PetDefinition(prefix: "Angel", displayName: "천사",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .goblin:
            return PetDefinition(prefix: "Goblin", displayName: "고블린",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .imp:
            return PetDefinition(prefix: "Imp", displayName: "임프",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .skelet:
            return PetDefinition(prefix: "Skelet", displayName: "스켈레톤",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .tinyZombie:
            return PetDefinition(prefix: "TinyZombie", displayName: "꼬마 좀비",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        case .iceZombie:
            return PetDefinition(prefix: "IceZombie", displayName: "얼음 좀비",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .muddy:
            return PetDefinition(prefix: "Muddy", displayName: "진흙 괴물",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .swampy:
            return PetDefinition(prefix: "Swampy", displayName: "늪지 괴물",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .tinySlug:
            return PetDefinition(prefix: "TinySlug", displayName: "꼬마 민달팽이",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .zombie:
            return PetDefinition(prefix: "Zombie", displayName: "좀비",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Idle", runSuffix: "Idle", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        case .bigDemon:
            return PetDefinition(prefix: "BigDemon", displayName: "큰 악마",
                                 cellSize: (32, 36), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .bigZombie:
            return PetDefinition(prefix: "BigZombie", displayName: "큰 좀비",
                                 cellSize: (32, 36), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .ogre:
            return PetDefinition(prefix: "Ogre", displayName: "오우거",
                                 cellSize: (32, 36), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // ─── Pixel Frog: Kings and Pigs ────────────────────────────────────
        case .kingHuman:
            return PetDefinition(prefix: "KingHuman", displayName: "인간 왕",
                                 cellSize: (78, 58), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .kingPig:
            return PetDefinition(prefix: "KingPig", displayName: "돼지 왕",
                                 cellSize: (38, 28), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pig:
            return PetDefinition(prefix: "Pig", displayName: "병정 돼지",
                                 cellSize: (34, 28), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pigBoxer:
            return PetDefinition(prefix: "PigBoxer", displayName: "상자 돼지",
                                 cellSize: (26, 30), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pigBomber:
            return PetDefinition(prefix: "PigBomber", displayName: "폭탄 돼지",
                                 cellSize: (26, 26), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)

        // ─── Pixel Frog: Pirate Bomb ───────────────────────────────────────
        case .bombGuy:
            return PetDefinition(prefix: "BombGuy", displayName: "폭탄 소년",
                                 cellSize: (58, 58), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .baldPirate:
            return PetDefinition(prefix: "BaldPirate", displayName: "대머리 해적",
                                 cellSize: (63, 67), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .cucumber:
            return PetDefinition(prefix: "Cucumber", displayName: "오이 해적",
                                 cellSize: (64, 68), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .bigGuy:
            return PetDefinition(prefix: "BigGuy", displayName: "거구 해적",
                                 cellSize: (77, 74), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .pirateCaptain:
            return PetDefinition(prefix: "PirateCaptain", displayName: "해적 선장",
                                 cellSize: (80, 72), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .whale:
            // Whale 스프라이트만 같은 Pirate Bomb 팩에서 유일하게 왼쪽을 향함
            // (주둥이가 왼쪽). 나머지 팩 캐릭터는 오른쪽 향함.
            return PetDefinition(prefix: "Whale", displayName: "고래 해적",
                                 cellSize: (68, 46), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        // ─── Pixel Frog: Treasure Hunters (free demo) ─────────────────────
        case .clownCaptain:
            return PetDefinition(prefix: "ClownCaptain", displayName: "광대코 선장",
                                 cellSize: (64, 40), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .fierceTooth:
            return PetDefinition(prefix: "FierceTooth", displayName: "사나운 이빨",
                                 cellSize: (34, 30), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // ─── Calciumtrice: Animated Slime (CC-BY 3.0) ─────────────────────
        // 32x32 멀티애님 grid에서 idle(row0)+walk(row2) 행만 잘라 가로 strip으로.
        // 5색 시트 중 blue 1색만 사용 — 변형(이로치)은 기존 hueRotation 방식.
        case .jellySlime:
            return PetDefinition(prefix: "Jelly", displayName: "젤리",
                                 cellSize: (32, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        // ─── Ansimuz: Sunny Land (CC0) ────────────────────────────────────
        // Oposum은 walk 한 줄뿐이라 모든 action이 같은 strip을 공유.
        case .sunFox:
            return PetDefinition(prefix: "SunFox", displayName: "모험가 여우",
                                 cellSize: (33, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .sunFrog:
            return PetDefinition(prefix: "SunFrog", displayName: "통통 개구리",
                                 cellSize: (35, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .oposum:
            return PetDefinition(prefix: "Oposum", displayName: "주머니쥐",
                                 cellSize: (36, 28), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Run",
                                 defaultTheme: .field)
        // Tiny Swords (Pixel Frog) — Idle/Run strip만, walk는 Run으로 alias (Pixel Adventure와 동일).
        // 원본은 192/320 큰 캔버스(공격 이펙트용 여백 多)라 import 시 캐릭터 bbox 합집합으로 트림했고,
        // cellSize는 그 실측값(예: 전사 97×95). Idle/Run은 같은 bbox로 잘라 cellSize가 일치한다.
        case .warrior:
            return PetDefinition(prefix: "Warrior", displayName: "전사",
                                 cellSize: (93, 93), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .lancer:
            return PetDefinition(prefix: "Lancer", displayName: "창기병",
                                 cellSize: (74, 75), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .storm)
        case .monk:
            return PetDefinition(prefix: "Monk", displayName: "수도사",
                                 cellSize: (83, 71), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .archer:
            // mythic 승격 — 특수 모션(Archer_Shoot) 포함 재트림. cellH=90 (idle 발 기준).
            return PetDefinition(prefix: "Archer", displayName: "궁수",
                                 cellSize: (74, 90), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pawn:
            // mythic 승격 — 특수 모션(Pawn_Hammer/Pickaxe) 포함 재트림(투구 기준). cellH=69.
            return PetDefinition(prefix: "Pawn", displayName: "일꾼",
                                 cellSize: (66, 69), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        // ─── 0x72 16x16+ Robot Tileset (CC0) — "CI Runners" ───────────────
        // 단일 512×512 시트에서 IDLE(4f)/WALK(8f)를 종별 strip으로 추출(scripts/import-robot-tileset.py).
        // 전부 우향(defaultFacingLeft: false). walk는 Run으로 alias. cellSize는 추출 실측값.
        case .scrapBot:
            return PetDefinition(prefix: "ScrapBot", displayName: "고철 로봇",
                                 cellSize: (14, 26), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .antennaBot:
            return PetDefinition(prefix: "AntennaBot", displayName: "안테나 로봇",
                                 cellSize: (16, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .pixelBot:
            return PetDefinition(prefix: "PixelBot", displayName: "픽셀 로봇",
                                 cellSize: (14, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .spiderBot:
            return PetDefinition(prefix: "SpiderBot", displayName: "거미 로봇",
                                 cellSize: (16, 26), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .sentryBot:
            return PetDefinition(prefix: "SentryBot", displayName: "감시 로봇",
                                 cellSize: (15, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .miniBot:
            return PetDefinition(prefix: "MiniBot", displayName: "꼬마 로봇",
                                 cellSize: (14, 18), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .visorBot:
            return PetDefinition(prefix: "VisorBot", displayName: "바이저 로봇",
                                 cellSize: (14, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .batBot:
            return PetDefinition(prefix: "BatBot", displayName: "박쥐 로봇",
                                 cellSize: (13, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .beaconBot:
            return PetDefinition(prefix: "BeaconBot", displayName: "신호등 로봇",
                                 cellSize: (14, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)

        // ─── GrafxKid Sprite Pack 1 (CC0) — 레트로 플랫포머 마스코트 ───────
        // 캐릭터별 개별 strip(셀 크기 파일명 명시). 정지/이동 애니메이션이 없는 종은
        // Standing/Swimming/Rolling/Flapping을 idle/run으로 alias(scripts/import-grafxkid.py).
        case .mrMan:
            return PetDefinition(prefix: "MrMan", displayName: "픽셀 히어로",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .bumpyBot:
            return PetDefinition(prefix: "BumpyBot", displayName: "범피",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .princessSera:
            return PetDefinition(prefix: "PrincessSera", displayName: "세라 공주",
                                 cellSize: (16, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sakura)
        case .bushly:
            return PetDefinition(prefix: "Bushly", displayName: "부시 정령",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .devoDevil:
            return PetDefinition(prefix: "DevoDevil", displayName: "데보 악마",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .rollingNero:
            return PetDefinition(prefix: "RollingNero", displayName: "롤링 네로",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .gloppySlime:
            return PetDefinition(prefix: "GloppySlime", displayName: "글로피 슬라임",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .chiChiBird:
            // grafxkid-1 팩 대부분은 정면이지만 이 스프라이트만 왼쪽을 본다(부리 기준).
            return PetDefinition(prefix: "ChiChiBird", displayName: "치치 새",
                                 cellSize: (16, 16), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .diverFish:
            return PetDefinition(prefix: "DiverFish", displayName: "물고기 다이버",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sea)
        case .bub:
            return PetDefinition(prefix: "Bub", displayName: "버브",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .spikeyBub:
            return PetDefinition(prefix: "SpikeyBub", displayName: "가시 버브",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pokeyBub:
            return PetDefinition(prefix: "PokeyBub", displayName: "뾰족 버브",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .blockyBub:
            return PetDefinition(prefix: "BlockyBub", displayName: "블록 버브",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)

        // ─── GrafxKid Sprite Pack 2 (CC0) — 음식·사물 마스코트 ─────────────
        case .onionLad:
            return PetDefinition(prefix: "OnionLad", displayName: "양파 소년",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .mrMochi:
            return PetDefinition(prefix: "MrMochi", displayName: "모찌 씨",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sakura)
        case .octi:
            return PetDefinition(prefix: "Octi", displayName: "옥티",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sea)
        case .roboPumpkin:
            return PetDefinition(prefix: "RoboPumpkin", displayName: "호박 로봇",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .daikon:
            return PetDefinition(prefix: "Daikon", displayName: "다이콘 무",
                                 cellSize: (16, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .roboTotem:
            return PetDefinition(prefix: "RoboTotem", displayName: "토템 로봇",
                                 cellSize: (16, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .rocketCherry:
            return PetDefinition(prefix: "RocketCherry", displayName: "로켓 체리",
                                 cellSize: (16, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cheesePuff:
            return PetDefinition(prefix: "CheesePuff", displayName: "치즈볼 동무",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .snipCrab:
            return PetDefinition(prefix: "SnipCrab", displayName: "집게 게",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sea)

        // ─── GrafxKid Sprite Pack 3 (CC0) — 로봇·모험가 (32x32) ────────────
        case .gumBot:
            return PetDefinition(prefix: "GumBot", displayName: "껌 로봇",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .twiggy:
            return PetDefinition(prefix: "Twiggy", displayName: "트위기",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .robotJ5:
            return PetDefinition(prefix: "RobotJ5", displayName: "J5 로봇",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .tommy:
            return PetDefinition(prefix: "Tommy", displayName: "토미",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .geralt:
            return PetDefinition(prefix: "Geralt", displayName: "게롤트",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // ─── GrafxKid Sprite Pack 4~8 (CC0) — 마스코트·몬스터·모험가·기사 ───
        case .agentMike:
            return PetDefinition(prefix: "AgentMike", displayName: "요원 마이크",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .martianRed:
            return PetDefinition(prefix: "MartianRed", displayName: "붉은 화성인",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .hermie:
            return PetDefinition(prefix: "Hermie", displayName: "소라게 허미",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sea)
        case .ballooney:
            return PetDefinition(prefix: "Ballooney", displayName: "벌루니",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .robotWalky:
            return PetDefinition(prefix: "RobotWalky", displayName: "워키 로봇",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .jumpyLumpy:
            return PetDefinition(prefix: "JumpyLumpy", displayName: "점피 럼피",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .orchidOwl:
            return PetDefinition(prefix: "OrchidOwl", displayName: "난초 올빼미",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .roach:
            return PetDefinition(prefix: "Roach", displayName: "바퀴 로치",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .mrCircuit:
            return PetDefinition(prefix: "MrCircuit", displayName: "서킷 씨",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .blankey:
            return PetDefinition(prefix: "Blankey", displayName: "담요 유령",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .roboRetro:
            return PetDefinition(prefix: "RoboRetro", displayName: "레트로 로봇",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .space)
        case .lilWiz:
            return PetDefinition(prefix: "LilWiz", displayName: "꼬마 마법사",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .bigRed:
            return PetDefinition(prefix: "BigRed", displayName: "빅 레드",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .squirmyWormy:
            return PetDefinition(prefix: "SquirmyWormy", displayName: "꿈틀 지렁이",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .moeScotty:
            return PetDefinition(prefix: "MoeScotty", displayName: "모 스코티",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .mrChomps:
            return PetDefinition(prefix: "MrChomps", displayName: "촘프 씨",
                                 cellSize: (32, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .toxic)
        case .grizzly:
            return PetDefinition(prefix: "Grizzly", displayName: "그리즐리 곰",
                                 cellSize: (48, 32), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .snowMountain)
        case .orc:
            return PetDefinition(prefix: "Orc", displayName: "덩치 오크",
                                 cellSize: (64, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .wispyFire:
            return PetDefinition(prefix: "WispyFire", displayName: "도깨비불",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .penguin:
            return PetDefinition(prefix: "Penguin", displayName: "펭귄",
                                 cellSize: (16, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .snowMountain)
        case .fairy:
            return PetDefinition(prefix: "Fairy", displayName: "요정",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .skeletonG:
            return PetDefinition(prefix: "Skeleton", displayName: "해골 병사",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .orangeFruit:
            return PetDefinition(prefix: "Orange", displayName: "오렌지",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .diego:
            return PetDefinition(prefix: "Diego", displayName: "디에고",
                                 cellSize: (32, 48), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .holly:
            return PetDefinition(prefix: "Holly", displayName: "홀리",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .gordon:
            return PetDefinition(prefix: "Gordon", displayName: "고든",
                                 cellSize: (48, 48), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .toggle:
            return PetDefinition(prefix: "Toggle", displayName: "토글",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .tracy:
            return PetDefinition(prefix: "Tracy", displayName: "트레이시",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .armand:
            return PetDefinition(prefix: "Armand", displayName: "아르망",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .percy:
            return PetDefinition(prefix: "Percy", displayName: "퍼시",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .vessa:
            return PetDefinition(prefix: "Vessa", displayName: "베사",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sakura)
        case .angie:
            return PetDefinition(prefix: "Angie", displayName: "앤지",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .barryCherry:
            return PetDefinition(prefix: "BarryCherry", displayName: "배리 체리",
                                 cellSize: (32, 32), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)

        // ─── LuizMelo Monsters Creatures Fantasy (CC0) — 다크판타지 몬스터 ──
        case .flyingEye:
            return PetDefinition(prefix: "FlyingEye", displayName: "비행 눈알",
                                 cellSize: (42, 33), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .goblinBrute:
            return PetDefinition(prefix: "GoblinBrute", displayName: "고블린 전사",
                                 cellSize: (38, 38), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .myconid:
            return PetDefinition(prefix: "Myconid", displayName: "버섯 마수",
                                 cellSize: (26, 39), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .toxic)
        case .skeletonLord:
            return PetDefinition(prefix: "SkeletonLord", displayName: "해골 기사",
                                 cellSize: (45, 51), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // ─── Superpowers 공룡 (CC0) — 좌향. 셀 크기는 그리드 트림 실측값 ─────
        case .dinoBat:
            return PetDefinition(prefix: "DinoBat", displayName: "선사 익수룡",
                                 cellSize: (51, 54), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .dinoDragon:
            return PetDefinition(prefix: "DinoDragon", displayName: "새끼 드래곤",
                                 cellSize: (98, 65), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .dinoBug:
            // pterodactyl과 같은 예외 — 팩 다수와 달리 오른쪽을 본다(머리·더듬이 기준).
            return PetDefinition(prefix: "DinoBug", displayName: "고대 곤충",
                                 cellSize: (78, 69), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .dinoLizard:
            // dinoBug/pterodactyl과 같은 예외 — 이 팩에서 오른쪽을 본다(주둥이 기준).
            return PetDefinition(prefix: "DinoLizard", displayName: "고대 도마뱀",
                                 cellSize: (105, 45), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .desert)
        case .miniRex:
            // 같은 팩 tRex와 달리 오른쪽을 본다(머리 기준).
            return PetDefinition(prefix: "MiniRex", displayName: "아기 렉스",
                                 cellSize: (80, 52), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .dinoPlant:
            // 벌어진 입이 오른쪽 — 이 팩의 우향 예외.
            return PetDefinition(prefix: "DinoPlant", displayName: "식충 식물룡",
                                 cellSize: (135, 82), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .toxic)
        case .pterodactyl:
            // superpowers-dino 팩 대부분은 왼쪽을 보지만 이 스프라이트만 오른쪽(부리 기준).
            return PetDefinition(prefix: "Pterodactyl", displayName: "프테라노돈",
                                 cellSize: (126, 113), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .dinoTurtle:
            return PetDefinition(prefix: "DinoTurtle", displayName: "고대 거북",
                                 cellSize: (60, 34), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .sea)
        case .tRex:
            return PetDefinition(prefix: "TRex", displayName: "티라노사우루스",
                                 cellSize: (117, 76), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)

        // ─── Superpowers 원시부족 캐릭터 (CC0) — 우향 ─────────────────────
        case .caverman:
            return PetDefinition(prefix: "Caveman", displayName: "원시인",
                                 cellSize: (57, 60), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .caveGirl:
            return PetDefinition(prefix: "CaveGirl", displayName: "부족 채집가",
                                 cellSize: (66, 64), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .caveGirl1:
            return PetDefinition(prefix: "CaveGirl1", displayName: "부족 소녀",
                                 cellSize: (59, 64), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .dragonMan:
            return PetDefinition(prefix: "DragonMan", displayName: "드래곤맨",
                                 cellSize: (58, 67), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .lionWarrior:
            return PetDefinition(prefix: "LionWarrior", displayName: "사자 전사",
                                 cellSize: (64, 64), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .desert)
        case .littleCaveBoy:
            return PetDefinition(prefix: "LittleCaveBoy", displayName: "꼬마 원시인",
                                 cellSize: (69, 52), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)

        // ─── LuizMelo 히어로/몬스터/반려동물 (CC0) — 우향 ─────────────────
        case .heroKnight:
            return PetDefinition(prefix: "HeroKnight", displayName: "영웅 기사",
                                 cellSize: (50, 56), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .huntress:
            return PetDefinition(prefix: "Huntress", displayName: "여전사 사냥꾼",
                                 cellSize: (50, 42), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .evilWizard:
            return PetDefinition(prefix: "EvilWizard", displayName: "흑마법사",
                                 cellSize: (76, 104), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .aurora)
        case .medievalKing:
            return PetDefinition(prefix: "MedievalKing", displayName: "중세 왕",
                                 cellSize: (74, 82), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .martialHero:
            return PetDefinition(prefix: "MartialHero", displayName: "무술 영웅",
                                 cellSize: (46, 52), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .fantasyWarrior:
            return PetDefinition(prefix: "FantasyWarrior", displayName: "판타지 전사",
                                 cellSize: (58, 45), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .fireWorm:
            return PetDefinition(prefix: "FireWorm", displayName: "화염 벌레",
                                 cellSize: (52, 45), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .volcano)
        case .vampireBat:
            return PetDefinition(prefix: "VampireBat", displayName: "흡혈 박쥐",
                                 cellSize: (67, 55), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .mimic:
            return PetDefinition(prefix: "Mimic", displayName: "미믹",
                                 cellSize: (47, 34), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .giantRat:
            // luizmelo-mcf2 팩에서 유일하게 왼쪽을 본다(코 왼쪽, 꼬리 오른쪽).
            return PetDefinition(prefix: "GiantRat", displayName: "거대 쥐",
                                 cellSize: (59, 20), defaultFacingLeft: true,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .wilderness)
        case .kingSlime:
            return PetDefinition(prefix: "KingSlime", displayName: "킹 슬라임",
                                 cellSize: (46, 20), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .toxic)
        // luizmelo-pets 팩은 고양이·개 12종 전부 오른쪽을 본다.
        case .cat1:
            return PetDefinition(prefix: "Cat1", displayName: "나비",
                                 cellSize: (30, 15), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cat2:
            return PetDefinition(prefix: "Cat2", displayName: "까망",
                                 cellSize: (30, 15), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cat3:
            return PetDefinition(prefix: "Cat3", displayName: "모모",
                                 cellSize: (30, 14), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cat4:
            return PetDefinition(prefix: "Cat4", displayName: "루비",
                                 cellSize: (30, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cat5:
            return PetDefinition(prefix: "Cat5", displayName: "보리",
                                 cellSize: (30, 16), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .cat6:
            return PetDefinition(prefix: "Cat6", displayName: "고등어",
                                 cellSize: (30, 15), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .akita:
            return PetDefinition(prefix: "Akita", displayName: "아키타",
                                 cellSize: (23, 17), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .goldenRetriever:
            return PetDefinition(prefix: "GoldenRetriever", displayName: "골든 리트리버",
                                 cellSize: (38, 23), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
        case .greatDane:
            return PetDefinition(prefix: "GreatDane", displayName: "그레이트 데인",
                                 cellSize: (50, 34), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .saintBernard:
            return PetDefinition(prefix: "SaintBernard", displayName: "세인트 버나드",
                                 cellSize: (50, 30), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .snowMountain)
        case .schnauzer:
            return PetDefinition(prefix: "Schnauzer", displayName: "슈나우저",
                                 cellSize: (31, 25), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .husky:
            return PetDefinition(prefix: "Husky", displayName: "허스키",
                                 cellSize: (34, 26), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .snowMountain)
        }
    }

    var displayName: String { def.displayName }
    var cellSize: (w: Int, h: Int) { def.cellSize }
    /// action별 셀 크기 — mythic 특수 모션은 자기 strip 크기, 그 외엔 기본 cellSize.
    func cellSize(for action: PetController.Action) -> (w: Int, h: Int) {
        Mythic.spec(for: self)?.specials[action]?.cell ?? def.cellSize
    }
    var defaultFacingLeft: Bool { def.defaultFacingLeft }

    func resourceName(for action: PetController.Action) -> String {
        if let move = Mythic.spec(for: self)?.specials[action] {
            return "\(def.prefix)_\(move.suffix)"
        }
        return def.resourceName(for: action)
    }
}

@MainActor
enum PetSprite {
    /// NSCache는 ObjectType이 AnyObject여야 해서 frame 배열을 box class로 감싼다.
    private final class FrameBox { let frames: [NSImage]; init(_ frames: [NSImage]) { self.frames = frames } }
    /// strip→frame 배열 / 단일 이미지 캐시. plain dict는 eviction이 없어 앱 수명 동안 단조 증가했다
    /// (issue #19-bonus). NSCache로 전환해 메모리 압력 시 OS가 자동 evict하게 한다.
    private static let cache = NSCache<NSString, FrameBox>()
    private static let imageCache = NSCache<NSString, NSImage>()

    /// SwiftPM 의 자동 생성 Bundle.module 은 .app/<name>.bundle 만 체크하지만
    /// 표준 .app 은 Contents/Resources/ 아래에 리소스가 들어감 → 둘 다 fallback.
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(forResource: "ClaudeUsage_ClaudeUsage", withExtension: "bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return .module
    }()

    /// 단일 아이콘 PNG(basename)를 번들에서 로드. 정적 UI 아이콘(시너지 배지 등)용. 캐시됨.
    static func icon(named name: String) -> NSImage? {
        if let c = imageCache.object(forKey: name as NSString) { return c }
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(img, forKey: name as NSString)
        return img
    }

    /// 동물+동작에 해당하는 strip을 잘라 frame 배열로 반환. 캐시됨.
    static func frames(for kind: PetKind, action: PetController.Action) -> [NSImage] {
        let key = "\(kind.rawValue)/\(action)" as NSString
        if let cached = cache.object(forKey: key) { return cached.frames }

        let name = kind.resourceName(for: action)
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let sheet = bitmap.cgImage
        else {
            DebugLog.log("PetSprite: \(name).png 로드 실패")
            cache.setObject(FrameBox([]), forKey: key)
            return []
        }

        let (w, h) = kind.cellSize(for: action)
        let frameCount = max(1, sheet.width / w)
        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let rect = CGRect(x: i * w, y: 0, width: w, height: h)
            if let cropped = sheet.cropping(to: rect) {
                frames.append(NSImage(cgImage: cropped, size: NSSize(width: w, height: h)))
            }
        }
        cache.setObject(FrameBox(frames), forKey: key)
        return frames
    }

    static func image(
        for kind: PetKind,
        action: PetController.Action,
        frameIndex: Int
    ) -> NSImage? {
        let f = frames(for: kind, action: action)
        guard !f.isEmpty else { return nil }
        return f[frameIndex % f.count]
    }

    // MARK: - 스킨 (시즌 보스 리컬러) + 머리 장식 합성

    nonisolated(unsafe) private static let skinCache = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static let skinContext = CIContext(options: nil)

    /// 스킨을 입힌 프레임. `skin == nil`이면 원본. (kind, action, frame, skin) 캐시.
    static func image(for kind: PetKind, action: PetController.Action, frameIndex: Int, skin: PetSkin?) -> NSImage? {
        guard let skin else { return image(for: kind, action: action, frameIndex: frameIndex) }
        let f = frames(for: kind, action: action)
        guard !f.isEmpty else { return nil }
        let idx = frameIndex % f.count
        let key = "\(kind.rawValue)/\(action)/\(idx)/skin:\(skin.rawValue)" as NSString
        if let cached = skinCache.object(forKey: key) { return cached }
        let out = applySkin(f[idx], skin)
        skinCache.setObject(out, forKey: key)
        return out
    }

    /// 리컬러 필터. 외곽선(어두운 픽셀)은 어둡게 남아 도트 느낌이 유지된다.
    static func applySkin(_ image: NSImage, _ skin: PetSkin) -> NSImage {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return image }
        var ci = CIImage(cgImage: cg)
        switch skin {
        case .snow:
            // 단색화 뒤 톤 커브로 중간톤을 흰색까지 끌어올린다. 밝기/대비 조절(1·2차 프리뷰)은 몸통이 회색에
            // 머물거나 외곽선이 같이 날아갔다 — 커브는 0(외곽선)은 0에 고정하고 0.25부터 급하게 올려
            // 어두운 선은 남기고 몸통만 희게 만든다.
            ci = ci.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 0.94, green: 0.97, blue: 1.0),
                kCIInputIntensityKey: 1.0,
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.00, y: 0.00),
                "inputPoint1": CIVector(x: 0.22, y: 0.62),
                "inputPoint2": CIVector(x: 0.45, y: 0.90),
                "inputPoint3": CIVector(x: 0.70, y: 0.97),
                "inputPoint4": CIVector(x: 1.00, y: 1.00),
            ])
        }
        guard let out = skinContext.createCGImage(ci, from: ci.extent) else { return image }
        return NSImage(cgImage: out, size: image.size)
    }

    /// 스킨 + 머리 장식을 한 장에 합성(위로 모자 높이만큼 여유). 도장 카드·배틀 시트·재생 썸네일 공용.
    /// WalkingCat·메뉴바와 같은 배치식(높이 42%, 상단이 머리 위로 20% 넘침).
    static func composedImage(for kind: PetKind, action: PetController.Action, frameIndex: Int,
                              skin: PetSkin?, headwear: String?) -> NSImage? {
        guard let frame = image(for: kind, action: action, frameIndex: frameIndex, skin: skin) else { return nil }
        guard let headwear, let hat = image(named: headwear),
              let anchor = headAnchor(for: kind, action: action, frameIndex: frameIndex) else { return frame }
        let key = "\(kind.rawValue)/\(action)/\(frameIndex % max(1, frames(for: kind, action: action).count))/skin:\(skin?.rawValue ?? "-")/hat:\(headwear)" as NSString
        if let cached = skinCache.object(forKey: key) { return cached }
        let w = frame.size.width, h = frame.size.height
        let lay = headwearLayout(cellWidth: w, cellHeight: h, anchor: anchor, hatSize: hat.size,
                                 facesLeft: kind.defaultFacingLeft)
        let headroom = max(0, -lay.top)
        let out = NSImage(size: NSSize(width: w, height: h + headroom))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        frame.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        // y-up 변환: 캔버스 높이 = h + headroom, 셀 상단은 y = h 가 아니라 h + headroom - 0 … 셀을 바닥(0)에 두었으므로
        // 셀 좌표 top(아래로 양수) → y = h - top - height.
        hat.draw(in: NSRect(x: lay.centerX - lay.width / 2, y: h - lay.top - lay.height,
                            width: lay.width, height: lay.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        skinCache.setObject(out, forKey: key)
        return out
    }

    // MARK: - 머리 장식 배치 (공용)

    /// 머리 장식의 위치·크기 — 스프라이트 셀 좌표(원점 좌상단, y 아래로), **반전 전** 기준.
    /// WalkingCat·메뉴바·합성 이미지가 전부 이 값을 써서 세 곳이 어긋나지 않는다.
    struct HeadwearLayout: Equatable {
        let centerX: CGFloat
        let top: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// 배치 규칙(사용자 검수로 조정됨):
    ///   * 높이 = 셀 높이의 42%.
    ///   * 세로: 모자 바닥이 머리 꼭대기보다 `height × 0.35`만큼 아래 — 머리에 "눌러쓴" 느낌. (처음 0.20은 떠 보였다.)
    ///   * 가로: 상단 밴드 x 중심에서 **바라보는 방향으로 셀 폭의 10%** 전진 — 옆모습 동물은 가장 높은 곳이
    ///     등·귀라 중심을 그대로 쓰면 모자가 뒤통수에 얹힌다.
    nonisolated static func headwearLayout(cellWidth w: CGFloat, cellHeight h: CGFloat,
                                           anchor: HeadAnchor, hatSize: CGSize,
                                           facesLeft: Bool) -> HeadwearLayout {
        let height = h * 0.42
        let width = height * (hatSize.width / max(1, hatSize.height))
        let forward: CGFloat = (facesLeft ? -1 : 1) * w * 0.10
        let headTop = anchor.top * h
        return HeadwearLayout(centerX: anchor.x * w + forward,
                              top: headTop + height * 0.35 - height,
                              width: width, height: height)
    }

    // MARK: - 머리 앵커 (시즌 headwear)

    /// 프레임 안에서 "머리"의 위치 — 셀 기준 정규화(0...1). `x`는 머리 x 중심, `top`은 가장 위 불투명 행.
    /// 195종의 cellSize·여백이 전부 달라 셀 상단 고정은 작은 펫에서 모자가 공중에 뜬다 — 알파를 직접 스캔한다.
    struct HeadAnchor: Equatable {
        let x: CGFloat
        let top: CGFloat
    }

    private final class AnchorBox { let anchor: HeadAnchor?; init(_ a: HeadAnchor?) { anchor = a } }
    nonisolated(unsafe) private static let anchorCache = NSCache<NSString, AnchorBox>()

    /// 알파 스캔으로는 못 잡는 종의 수동 앵커(셀 정규화, 반전 전). 날개·잎이 머리보다 높은 종 — 검수 시트에서
    /// 사용자가 지목한 것만 넣는다. `headwearLayout`의 전진 10%가 더해지므로, 원하는 중심에서 바라보는 방향의
    /// **반대쪽으로 0.10** 적어 둔다(박쥐·파랑새·무는 전부 왼쪽을 봄 → +0.10).
    nonisolated static let headAnchorOverrides: [PetKind: HeadAnchor] = [
        .bat:      HeadAnchor(x: 0.60, top: 0.13),   // 머리 x 0.50 — 날개 끝이 더 높아 자동 규칙이 날개를 잡는다
        .blueBird: HeadAnchor(x: 0.79, top: 0.28),   // 머리 x 0.69 — 부리가 앞으로 길어 중심이 부리로 쏠린다
        .radish:   HeadAnchor(x: 0.60, top: 0.32),   // 몸통 꼭대기 — 잎 끝(0.13)에 얹으면 공중에 뜬다
        .bear:     HeadAnchor(x: 0.35, top: 0.24),   // 머리 x 0.25 — 걷기 프레임은 등과 머리 높이가 비슷해 앞쪽 규칙이 안 걸린다
        .snail:    HeadAnchor(x: 0.34, top: 0.50),   // 눈 위 — 껍데기가 가장 높아 자동 규칙이 껍데기를 잡는다
        // 오른쪽을 보는 종은 −0.10.
        .snipCrab: HeadAnchor(x: 0.46, top: 0.50),   // 눈자루 사이 — 들어 올린 집게가 더 높다
        .hermie:   HeadAnchor(x: 0.59, top: 0.75),   // 머리(눈) — 소라 껍데기가 더 높다
        .kingHuman: HeadAnchor(x: 0.30, top: 0.31),  // 왕관 위 — 가로로 긴 셀에 방패가 앞쪽이라 앞쪽 규칙이 방패를 잡는다
        // 사용자 지목 2차 (시트 2·3·6)
        .turtle:   HeadAnchor(x: 0.60, top: 0.15),   // 등딱지 꼭대기 가시 사이 (왼쪽 봄)
        .dwarfF:   HeadAnchor(x: 0.40, top: 0.29),   // 머리카락 위
        .elfF:     HeadAnchor(x: 0.40, top: 0.50),   // 머리카락 위 — 셀 위 절반이 비어 있다
        .angel:    HeadAnchor(x: 0.46, top: 0.19),   // 후광 위
        .imp:      HeadAnchor(x: 0.40, top: 0.31),   // 뿔 사이
        .tinySlug: HeadAnchor(x: 0.46, top: 0.19),   // 눈자루 위
        .orc:      HeadAnchor(x: 0.43, top: 0.19),   // 뿔 사이 — 가로로 긴 셀에 창이 앞쪽
        .orangeFruit: HeadAnchor(x: 0.46, top: 0.59),// 몸통 꼭대기 — 잎이 더 높다
    ]

    /// 알파 스캔 결과에 더하는 보정(셀 정규화, 반전 전). 고정 앵커와 달리 프레임을 따라간다 — 머리를 숙이는 프레임이
    /// 있는 종에 쓴다. 사슴은 가는 뿔 끝이 꼭대기라 모자가 뿔에 얹히고, 흰 스킨(Rudolph)은 눈밭에서 뿔이 안 보여
    /// 모자가 공중에 떠 보였다 — 뿔 높이의 절반쯤 내리고 뿔 뒤(머리 쪽)로 민다.
    nonisolated static let headAnchorAdjust: [PetKind: (dx: CGFloat, dTop: CGFloat)] = [
        .deer: (dx: 0.05, dTop: 0.115),
    ]

    /// (kind, action, frameIndex)별 캐시. 알파 스캔은 첫 1회뿐이라 30Hz 메뉴바에서도 비용이 없다.
    /// 전부 투명한 프레임(없어야 하지만)은 nil. 수동 앵커가 있으면 프레임과 무관하게 그 값.
    static func headAnchor(for kind: PetKind, action: PetController.Action, frameIndex: Int) -> HeadAnchor? {
        if let fixed = headAnchorOverrides[kind] { return fixed }
        let f = frames(for: kind, action: action)
        guard !f.isEmpty else { return nil }
        let idx = frameIndex % f.count
        let key = "\(kind.rawValue)/\(action)/\(idx)" as NSString
        if let cached = anchorCache.object(forKey: key) { return cached.anchor }
        var anchor = scanHeadAnchor(f[idx], facesLeft: kind.defaultFacingLeft)
        if let adj = headAnchorAdjust[kind], let a = anchor {
            anchor = HeadAnchor(x: a.x + adj.dx, top: a.top + adj.dTop)
        }
        anchorCache.setObject(AnchorBox(anchor), forKey: key)
        return anchor
    }

    /// 가장 위 불투명 행을 찾고, 그 행부터 셀 높이의 1/6 구간에 있는 불투명 픽셀의 x 평균을 머리 중심으로 본다.
    /// (몸통 전체 평균을 쓰면 꼬리·날개가 중심을 끌어가 모자가 등에 얹힌다.)
    ///
    /// 옆모습인데 **등이 머리보다 높은** 종(곰·멧돼지)은 전체 꼭대기가 등이라 모자가 등에 얹혔다(검수 시트).
    /// 그래서 **가로로 긴(폭 > 높이×1.3) 옆모습**에 한해 바라보는 방향 앞쪽 30% 폭의 꼭대기를 따로 재고,
    /// 그게 전체 꼭대기보다 셀 높이의 12% 이상 낮으면 앞쪽을 머리로 본다. 세로로 긴 정면 캐릭터·로봇은
    /// 앞쪽 구간이 팔이나 어깨라 이 규칙을 끄고 기존 중심 규칙을 쓴다(miniBot이 어깨에 쓰는 사고).
    static func scanHeadAnchor(_ image: NSImage, facesLeft: Bool = false, alphaThreshold: UInt8 = 64) -> HeadAnchor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 비트맵 컨텍스트의 메모리 첫 행이 이미지의 **맨 위**다(좌표계는 y-up이지만 저장은 top-down).
        func alpha(_ x: Int, _ yFromTop: Int) -> UInt8 { pixels[(yFromTop * w + x) * 4 + 3] }
        var topRow: Int? = nil
        outer: for y in 0..<h {
            for x in 0..<w where alpha(x, y) >= alphaThreshold { topRow = y; break outer }
        }
        guard let top = topRow else { return nil }
        let band = Swift.max(2, h / 6)
        func centroid(top: Int, xRange: Range<Int>) -> HeadAnchor? {
            var sumX = 0, n = 0
            for y in top..<Swift.min(h, top + band) {
                for x in xRange where alpha(x, y) >= alphaThreshold { sumX += x; n += 1 }
            }
            guard n > 0 else { return nil }
            return HeadAnchor(x: (CGFloat(sumX) / CGFloat(n) + 0.5) / CGFloat(w), top: CGFloat(top) / CGFloat(h))
        }
        // 불투명 영역의 가로·세로 범위 → 가로로 긴 옆모습만 앞쪽 규칙.
        var minX = w, maxX = -1, bottom = top
        for y in 0..<h {
            for x in 0..<w where alpha(x, y) >= alphaThreshold {
                minX = Swift.min(minX, x); maxX = Swift.max(maxX, x); bottom = y
            }
        }
        guard maxX >= minX else { return nil }
        let span = maxX - minX + 1
        let tall = bottom - top + 1
        guard Double(span) > Double(tall) * 1.3 else { return centroid(top: top, xRange: 0..<w) }
        let frontW = Swift.max(1, Int((Double(span) * 0.30).rounded()))
        let front: Range<Int> = facesLeft ? minX..<(minX + frontW) : (maxX - frontW + 1)..<(maxX + 1)
        var frontTop: Int? = nil
        outerFront: for y in 0..<h {
            for x in front where alpha(x, y) >= alphaThreshold { frontTop = y; break outerFront }
        }
        if let ft = frontTop, ft - top >= Swift.max(2, Int(Double(h) * 0.12)),
           let a = centroid(top: ft, xRange: front) {
            return a
        }
        return centroid(top: top, xRange: 0..<w)
    }

    /// 단일 PNG 로딩 (sprite strip이 아닌 일반 이미지 — 예: 가챠 알). 캐시됨.
    static func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url)
        else {
            DebugLog.log("PetSprite: \(name).png 로드 실패")
            return nil
        }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// PetKind와 무관한 strip PNG (예: 가챠 코인 회전)을 frame 배열로. 캐시됨.
    static func frames(named name: String, cellSize: (w: Int, h: Int)) -> [NSImage] {
        let key = "\(name)/\(cellSize.w)x\(cellSize.h)" as NSString
        if let cached = cache.object(forKey: key) { return cached.frames }
        guard let url = resourceBundle.url(forResource: name, withExtension: "png"),
              let nsImage = NSImage(contentsOf: url),
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let sheet = bitmap.cgImage
        else {
            DebugLog.log("PetSprite: \(name).png strip 로드 실패")
            cache.setObject(FrameBox([]), forKey: key)
            return []
        }
        let frameCount = max(1, sheet.width / cellSize.w)
        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let rect = CGRect(x: i * cellSize.w, y: 0, width: cellSize.w, height: cellSize.h)
            if let cropped = sheet.cropping(to: rect) {
                frames.append(NSImage(cgImage: cropped, size: NSSize(width: cellSize.w, height: cellSize.h)))
            }
        }
        cache.setObject(FrameBox(frames), forKey: key)
        return frames
    }
}
