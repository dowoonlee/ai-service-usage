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
            return PetDefinition(prefix: "Archer", displayName: "궁수",
                                 cellSize: (78, 94), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .field)
        case .pawn:
            return PetDefinition(prefix: "Pawn", displayName: "일꾼",
                                 cellSize: (70, 81), defaultFacingLeft: false,
                                 walkSuffix: "Run", runSuffix: "Run", idleSuffix: "Idle",
                                 defaultTheme: .grassland)
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
