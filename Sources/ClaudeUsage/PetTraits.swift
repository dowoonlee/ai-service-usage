import Foundation

/// 펫 종별 metadata — 렌더링과 무관한 게임 로직용 속성.
///
/// `PetDefinition`(prefix/cellSize/suffixes/theme/facing)은 *렌더링용*이므로 거기에 게임
/// 속성을 섞으면 매번 시그니처가 늘어나고 75 case의 라인을 통째로 다시 손대야 한다.
/// 여기 extension은 trait당 한 매핑 함수만 추가하면 되도록 분리 — 미래에 element/archetype
/// 같은 속성을 추가할 때 기존 라인은 건드리지 않는다.
extension PetKind {
    /// 어느 컬렉션(셋 보너스 단위)에 속하는지. 1:1 매핑 — 모든 75종이 정확히 하나에 속한다.
    /// 합 검산: 8+6+5+5+8+8+8+8+5+6+8+4 = 79.
    var collection: PetCollection {
        switch self {
        // 야생 포유류 (8) — Works on My Machine
        case .fox, .wolf, .bear, .boar, .deer, .rabbit, .bunny, .rino:
            return .mainframe

        // 하늘 친구 (6) — It's Always DNS
        case .bat, .bee, .blueBird, .chicken, .duck, .fatBird:
            return .dns

        // 땅 위 작은 친구 (5) — npm install
        case .chameleon, .turtle, .snail, .slug, .tinySlug:
            return .npmInstall

        // 돼지족 (5) — node_modules
        case .angryPig, .kingPig, .pig, .pigBoxer, .pigBomber:
            return .nodeModules

        // 자연물·정령 (8) — TODO Since 2019
        case .mushroom, .slime, .plant, .radish, .trunk, .rock1, .rock2, .rock3:
            return .todoSince2019

        // 언데드 (8) — WONTFIX
        case .ghost, .skull, .necromancer, .skelet, .tinyZombie, .iceZombie, .zombie, .bigZombie:
            return .wontfix

        // 악마·괴물 (8) — Friday Deploy
        case .chort, .pumpkinDude, .imp, .muddy, .swampy, .bigDemon, .ogre, .wogol:
            return .fridayDeploy

        // 모험가·전사 (8) — Vibe Coders
        case .maskDude, .ninjaFrog, .dwarfF, .dwarfM, .elfF, .elfM, .knightF, .knightM:
            return .vibeCoders

        // 마법·신성·왕족 (5) — Token Burners
        case .wizardF, .wizardM, .doc, .angel, .kingHuman:
            return .tokenBurners

        // 이종족 전사 (6) — Rust Evangelists
        case .maskedOrc, .orcShaman, .orcWarrior, .lizardF, .lizardM, .goblin:
            return .rustEvangelists

        // 해적단 (8) — --no-verify
        case .bombGuy, .baldPirate, .cucumber, .bigGuy, .pirateCaptain, .whale, .clownCaptain, .fierceTooth:
            return .noVerify

        // 밝고 귀여운 마스코트 (4) — Happy Path
        case .jellySlime, .sunFrog, .oposum, .sunFox:
            return .happyPath
        }
    }

    /// `Gacha.pool` 역인덱스. `PetCollection.bonusCoins` 산정에 쓰임.
    /// pool에 없는 kind(이론상 없음)는 nil 반환 — 호출 측에서 Common 가치로 fallback.
    /// `Gacha.pool`이 nonisolated static let이라 여기도 nonisolated.
    static func rarityFor(_ kind: PetKind) -> Rarity? {
        for (rarity, kinds) in Gacha.pool where kinds.contains(kind) {
            return rarity
        }
        return nil
    }
}
