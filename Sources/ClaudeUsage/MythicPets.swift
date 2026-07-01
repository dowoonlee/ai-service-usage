import CoreGraphics

// mythic 펫의 '특별함'을 한 곳에 모은 정의 (SSOT).
//
// 'Rarity로서의 mythic'(등급 enum·가챠 풀·등급 색/별표)은 GachaModels/Gacha에 그대로 두고,
// 여기서는 mythic '펫'의 고유 행동·표현(크기/특수 모션/대사/오라 등)만 다룬다.
// 흩어져 있던 분기들(WalkingCat.renderHeight, PetSprite.specialMoves, Quotes.mythicMoves,
// chooseNextAction 발동, PetEffectOverlay 오라)이 모두 이 레지스트리를 조회하도록 일원화했다.
//
// 새 mythic 전용 기능을 추가할 때는 `MythicSpec`에 필드 하나(옵셔널/디폴트)를 더하고,
// 아래 `specs`의 펫별 값과 사용처 한 곳만 채우면 된다.

/// mythic 펫의 특수 모션 1개 — 전용 strip suffix + 그 strip의 셀 크기.
/// 공격 등은 무기 휘두름으로 가로 bbox가 Idle/Run보다 넓어 Action별 cellSize가 필요하다.
struct SpecialMove {
    let suffix: String
    let cell: (w: Int, h: Int)
}

/// mythic 펫별 기본 오라 스타일. 실제 색 매핑은 `PetEffectOverlay`(뷰)에서 한다.
enum MythicAura {
    case crimsonGold      // 기본 (진홍/금)
    case volcanicFire     // 전사 — 화산 불꽃 (적·금)
    case stormLightning   // 창기병 — 폭풍 번개 (청·백)
    case holyLight        // 수도사 — 성스러운 빛 (금·청록)
    case emeraldWind      // 궁수 — 숲/바람 (초록·연둣빛)
    case earthenGold      // 일꾼 — 대지/황금 (흙갈색·금)
}

/// mythic 펫 1마리의 특별 정의.
struct MythicSpec {
    /// 차트 위 렌더 크기 배수 (일반 펫=1, mythic=1.5).
    var sizeScale: CGFloat = 1.5
    /// 행동 선택 시 특수 모션 발동 확률(평상시). 고사용 구간에선 더 자주 발동한다.
    var specialChance: Double = 0.10
    /// 특수 모션 (Action.special1/special2 → strip + cellSize).
    var specials: [PetController.Action: SpecialMove]
    /// 특수 모션별 전용 대사 (발동 시 말풍선). 키는 `specials`와 같은 Action.
    var moveQuotes: [PetController.Action: [String]]
    /// 펫별 시그니처 오라 (기본 진홍/금 대신 캐릭터 테마색).
    var aura: MythicAura = .crimsonGold
    /// 마우스 호버 시 도망 대신 던지는 도발 대사 (mythic은 물러서지 않는다).
    var taunts: [String] = []
    /// 사용량 위험 구간(고불안)에서 특수 모션과 함께 외치는 대사.
    var stressQuotes: [String] = []
    // ── 새 mythic 전용 기능은 여기에 필드로 추가(전부 옵셔널/디폴트로 두면 기존 펫 무영향) ──
    //   var coinBonus: Double = 1.0                      // 특수 모션 시 코인 보너스
    //   var onSpecial: ((PetController) -> Void)? = nil  // 발동 시 커스텀 동작
}

enum Mythic {
    /// mythic 펫별 정의. 여기에 등록된 펫만 특수 모션·1.5배 크기·오라가 적용된다.
    /// (가챠 등급 풀 `Gacha.pool[.mythic]`과 동일 종으로 유지한다.)
    static let specs: [PetKind: MythicSpec] = [
        .warrior: MythicSpec(
            specials: [
                .special1: SpecialMove(suffix: "Attack1", cell: (120, 93)),
                .special2: SpecialMove(suffix: "Attack2", cell: (118, 93)),
            ],
            moveQuotes: [
                .special1: ["이 버그, 한 칼에!", "merge conflict, 베어주마!", "리뷰 거부, 칼로 행사!"],
                .special2: ["레거시 코드, 처단한다!", "deprecated 베기!", "테스트 깬 놈 게 섰거라!"],
            ],
            aura: .volcanicFire,
            taunts: ["기사는 물러서지 않는다.", "어디 한 번 덤벼보시지.", "그 손, 거두는 게 좋을 거다."],
            stressQuotes: ["한계까지 밀어붙여라!", "이 정도 부하쯤이야!", "전장 한복판이 제격이지."]),
        .lancer: MythicSpec(
            specials: [.special1: SpecialMove(suffix: "Attack", cell: (186, 75))],
            moveQuotes: [.special1: ["버그를 꿰뚫는다!", "null 포인터, 관통!", "창으로 핫픽스 찌르기!"]],
            aura: .stormLightning,
            taunts: ["창 앞에서 멈춰라.", "한 발 더 오면 꿰뚫는다.", "거리를 잘못 쟀군."],
            stressQuotes: ["돌격, 멈추지 않는다!", "한계? 그게 뭐지?", "풀스피드로 돌파!"]),
        .monk: MythicSpec(
            specials: [.special1: SpecialMove(suffix: "Heal", cell: (121, 71))],
            moveQuotes: [.special1: ["서버야, 쾌차하거라.", "기도하니 CI 초록불!", "힐: rm -rf node_modules."]],
            aura: .holyLight,
            taunts: ["폭력은 답이 아닙니다.", "마음을 비우시지요.", "거기까지만 하시길."],
            stressQuotes: ["서버에 평안을...", "과부하엔 명상이 약.", "곧 회복될 겁니다."]),
        .archer: MythicSpec(
            specials: [.special1: SpecialMove(suffix: "Shoot", cell: (87, 90))],
            moveQuotes: [.special1: ["버그를 조준한다... 명중!", "원샷 원킬, 핫픽스!", "저 이슈, 화살 한 방이면 끝."]],
            aura: .emeraldWind,
            taunts: ["이 거리에선 못 피한다.", "가만히 서 있어 줘서 고맙군.", "조준 끝났다."],
            stressQuotes: ["연사 모드, 간다!", "화살 아끼지 않는다!", "전탄 발사!"]),
        .pawn: MythicSpec(
            specials: [
                .special1: SpecialMove(suffix: "Hammer", cell: (84, 69)),
                .special2: SpecialMove(suffix: "Pickaxe", cell: (101, 69)),
            ],
            moveQuotes: [
                .special1: ["뚝딱뚝딱, 빌드 복구!", "망치로 레거시 수리!", "인프라는 내가 짓는다."],
                .special2: ["곡괭이질로 캐시 채굴!", "여기 금맥(로그) 있다!", "파다 보면 원인 나온다."],
            ],
            aura: .earthenGold,
            taunts: ["일하는 사람 건들지 마쇼.", "삽 맛 볼래?", "바쁘니까 저리 비켜요."],
            stressQuotes: ["야근 각이다, 가자!", "이 정도 노가다쯤이야!", "손이 열 개라도 모자라!"]),
    ]

    static func spec(for kind: PetKind) -> MythicSpec? { specs[kind] }

    /// mythic 펫 여부 — 특수 모션·1.5배·오라 적용 기준. (등급 enum과 별개의 '행동' 기준이지만
    /// 현재 가챠 풀과 동일 종으로 유지된다.)
    static func isMythic(_ kind: PetKind) -> Bool { specs[kind] != nil }

    /// 특수 모션 대사 한 줄. 해당 펫/모션 풀이 없으면 종 전용 일반 대사로 폴백.
    static func quote(for kind: PetKind, action: PetController.Action) -> String {
        spec(for: kind)?.moveQuotes[action]?.randomElement() ?? Quotes.random(for: kind)
    }

    /// 호버 도발 대사 한 줄. 풀이 없으면 일반 반응 대사로 폴백.
    static func taunt(for kind: PetKind) -> String {
        let t = spec(for: kind)?.taunts ?? []
        return t.randomElement() ?? Quotes.randomReaction()
    }
}
