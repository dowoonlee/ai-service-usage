import CoreGraphics

// mythic 펫의 '특별함'을 한 곳에 모은 정의 (SSOT).
//
// 'Rarity로서의 mythic'(등급 enum·가챠 풀·등급 색/별표)은 GachaModels/Gacha에 그대로 두고,
// 여기서는 mythic '펫'의 고유 행동·표현(크기/특수 모션/대사 등)만 다룬다.
// 흩어져 있던 분기들(WalkingCat.renderHeight, PetSprite.specialMoves, Quotes.mythicMoves,
// chooseNextAction 발동)이 모두 이 레지스트리를 조회하도록 일원화했다.
//
// 새 mythic 전용 기능을 추가할 때는 `MythicSpec`에 필드 하나(옵셔널/디폴트)를 더하고,
// 아래 `specs`의 펫별 값과 사용처 한 곳만 채우면 된다.

/// mythic 펫의 특수 모션 1개 — 전용 strip suffix + 그 strip의 셀 크기.
/// 공격 등은 무기 휘두름으로 가로 bbox가 Idle/Run보다 넓어 Action별 cellSize가 필요하다.
struct SpecialMove {
    let suffix: String
    let cell: (w: Int, h: Int)
}

/// mythic 펫 1마리의 특별 정의.
struct MythicSpec {
    /// 차트 위 렌더 크기 배수 (일반 펫=1, mythic=1.5).
    var sizeScale: CGFloat = 1.5
    /// 행동 선택 시 특수 모션 발동 확률.
    var specialChance: Double = 0.10
    /// 특수 모션 (Action.special1/special2 → strip + cellSize).
    var specials: [PetController.Action: SpecialMove]
    /// 특수 모션별 전용 대사 (발동 시 말풍선). 키는 `specials`와 같은 Action.
    var moveQuotes: [PetController.Action: [String]]
    // ── 새 mythic 전용 기능은 여기에 필드로 추가(전부 옵셔널/디폴트로 두면 기존 펫 무영향) ──
    //   var coinBonus: Double = 1.0                      // 특수 모션 시 코인 보너스
    //   var onSpecial: ((PetController) -> Void)? = nil  // 발동 시 커스텀 동작
    //   var auraTint: (crimson: Double, gold: Double)?   // 펫별 오라 색 (기본 진홍/금)
}

enum Mythic {
    /// mythic 펫별 정의. 여기에 등록된 펫만 특수 모션·1.5배 크기·오라가 적용된다.
    /// (가챠 등급 풀 `Gacha.pool[.mythic]`과 동일 3종으로 유지한다.)
    static let specs: [PetKind: MythicSpec] = [
        .warrior: MythicSpec(
            specials: [
                .special1: SpecialMove(suffix: "Attack1", cell: (120, 93)),
                .special2: SpecialMove(suffix: "Attack2", cell: (118, 93)),
            ],
            moveQuotes: [
                .special1: ["이 버그, 한 칼에!", "merge conflict, 베어주마!", "리뷰 거부, 칼로 행사!"],
                .special2: ["레거시 코드, 처단한다!", "deprecated 베기!", "테스트 깬 놈 게 섰거라!"],
            ]),
        .lancer: MythicSpec(
            specials: [.special1: SpecialMove(suffix: "Attack", cell: (186, 75))],
            moveQuotes: [.special1: ["버그를 꿰뚫는다!", "null 포인터, 관통!", "창으로 핫픽스 찌르기!"]]),
        .monk: MythicSpec(
            specials: [.special1: SpecialMove(suffix: "Heal", cell: (121, 71))],
            moveQuotes: [.special1: ["서버야, 쾌차하거라.", "기도하니 CI 초록불!", "힐: rm -rf node_modules."]]),
    ]

    static func spec(for kind: PetKind) -> MythicSpec? { specs[kind] }

    /// mythic 펫 여부 — 특수 모션·1.5배·오라 적용 기준. (등급 enum과 별개의 '행동' 기준이지만
    /// 현재 가챠 풀과 동일 3종으로 유지된다.)
    static func isMythic(_ kind: PetKind) -> Bool { specs[kind] != nil }

    /// 특수 모션 대사 한 줄. 해당 펫/모션 풀이 없으면 종 전용 일반 대사로 폴백.
    static func quote(for kind: PetKind, action: PetController.Action) -> String {
        spec(for: kind)?.moveQuotes[action]?.randomElement() ?? Quotes.random(for: kind)
    }
}
