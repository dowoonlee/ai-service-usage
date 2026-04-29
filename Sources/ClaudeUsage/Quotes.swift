import Foundation

// pet이 가끔 멈춰서 던지는 어처구니없는 한 마디 모음.
// 종(kind)당 전용 풀로 매핑 (`perPet`) — 펫의 캐릭터에 맞춰 각자 다른 대사를 친다.
// 톤: 캐릭터 컨셉 + 개발자/CS/AI/LLM 밈을 섞어 한 펫당 1~2줄은 dev 비유가 들어가도록 설계.
// 길이는 말풍선이 너무 커지지 않도록 ~35자 이하 권장.
enum Quotes {
    /// 펫 종(kind)별 전용 대사 풀. 각 종은 독립된 라인 set을 갖고, 다른 종의 라인은 절대 노출하지 않는다.
    /// 새 펫(`PetKind`)을 추가하면 반드시 이 dict에도 항목을 넣어야 한다 — 누락 시 `random(for:)`가
    /// 안전 기본값(`"..."`)을 반환해 사용자에겐 무음에 가까운 표시가 된다.
    static let perPet: [PetKind: [String]] = [
        // ─── wild-animals ─────────────────────────────────────────────
        .fox:    ["Firefox 본가는 아닙니다.", "약삭빠른 게 매력 포인트.", "꼬리가 9개 안 됐는데도 인기."],
        .wolf:   ["lone wolf, pair programming 거부.", "달 뜨면 git push 시작.", "외로움은 사치다."],
        .bear:   ["GC 돌아갈 동안 동면.", "메모리 hibernate 중.", "꿀은 정의다."],
        .boar:   ["branching 개념 없어요.", "force-push 본능.", "직진만이 살길!"],
        .deer:   ["나는 tree 자료구조 위에 살아요.", "조심해요, 화살은 사양.", "뿔 무거워서 목 결림."],
        .rabbit: ["fork() 한 번이면 자식 무한 증식.", "당근 보면 정신 못 차림.", "토끼는 외로우면 죽어요."],

        // ─── pixel-adventure ──────────────────────────────────────────
        .maskDude:  ["오픈소스 익명 메인테이너.", "정의는 마스크 안에서!", "mask 처리는 내 전공."],
        .ninjaFrog: ["stealth deploy 마스터.", "그림자처럼 PR 머지.", "개굴, 닌자 강림!"],
        .mushroom:  ["포자처럼 버그 전파.", "독버섯 아니에요. 진짜로.", "비 오면 fan-out 폭주."],
        .slime:     ["linked list처럼 분열.", "끈적끈적이 매력 포인트.", "RPG 첫 적은 늘 우리."],

        // ─── pixel-adventure-2 ────────────────────────────────────────
        .angryPig:  ["stack overflow 보면 화남.", "꿀꿀, 화났다!", "다 박치기로 해결."],
        .bat:       ["binary tree 야간 순찰.", "낮엔 거꾸로 잠.", "초음파로 라우팅."],
        .bee:       ["honey, DI 컨테이너 정리.", "꿀 만드느라 바쁨.", "쏘면 한 번 죽어요. 슬픈 진실."],
        .blueBird:  ["Twitter API rate limit.", "행복은 먼 곳에 있지 않다.", "지저귀는 게 일이에요."],
        .bunny:     ["git rebase 같은 부드러움.", "당근말고 도전 받아요.", "토끼발은 행운이래요!"],
        .chameleon: ["polymorphism 어렵지 않아요.", "type coercion 마스터.", "지금 무슨 색이게?"],
        .chicken:   ["egg-cellent function 출시!", "꼬꼬댁! prod 다운.", "해 뜨면 알람 시작."],
        .duck:      ["rubber duck debugging 원조.", "꽥꽥 회의 시작.", "수면 위 우아, 아래는 발버둥."],
        .fatBird:   ["메모리 풋프린트 큼.", "다이어트는 내일부터.", "하늘은 마음으로 날아요."],
        .ghost:     ["memory leak 같은 존재.", "null pointer 친구.", "벽 통과 가능. 자랑."],
        .plant:     ["race condition 자라는 중.", "물 주지 마세요. 사람만.", "꽃집에서 탈출."],
        .radish:    ["root 권한 좀 줘요.", "무가 무시당해요.", "단단함 자신 있어요."],
        .rino:      ["DDoS 같은 돌진.", "뿔로 모든 걸 해결.", "각도 따위 무시!"],
        .rock1:     ["rock-solid stable build.", "굴러갈 의지 없음.", "이끼가 친구."],
        .rock2:     ["돌은 돌일 뿐, 언제나 immutable.", "발에 차이는 게 일.", "rocky stack trace."],
        .rock3:     ["atomic reference 그 자체.", "작아도 돌이오.", "주머니에 쏙."],
        .skull:     ["dead code의 친구.", "살아있을 때가 그립다.", "할로윈은 내 시즌."],
        .snail:     ["O(n²)도 빠른 편.", "느린 게 미덕이다.", "내 집은 항상 같이."],
        .trunk:     ["main branch가 곧 trunk.", "...뚝딱.", "한때 푸르렀지."],
        .turtle:    ["TurtleGraphics 향수.", "느려도 도착은 한다.", "장수의 비결은 천천히."],

        // ─── 0x72 DungeonTileset II — heroes ──────────────────────────
        .dwarfF:   ["비트 채굴 가즈아!", "수염 없어도 드워프!", "도끼 한 자루면 충분."],
        .dwarfM:   ["mining: cryptocurrency 아니에요.", "맥주 한 잔 콜!", "수염은 명예입니다."],
        .elfF:     ["binary search처럼 정확한 활.", "숲의 정령과 친구.", "천 살 미만은 어린이."],
        .elfM:     ["선형 검색은 천박하다.", "엘프는 왜 늘 인기 많지.", "나무와 대화 가능."],
        .knightF:  ["기사도는 성별 없음.", "버그를 퇴치하라!", "갑옷 무거워서 어깨 결림."],
        .knightM:  ["코드는 칼날처럼 날카롭게.", "왕을 위하여!", "탱커는 외로워요."],
        .lizardF:  ["탈피 = 리팩토링.", "꼬리 떼고 도망가요.", "차가운 피로 코드 리뷰."],
        .lizardM:  ["혀로 stack frame 읽어요.", "변온동물의 자존심.", "햇볕 쬐는 게 일과."],
        .wizardF:  ["마법은 사실 정규식.", "지팡이 끝에서 별이 핑핑.", "주문 외우는 중. 방해 금지."],
        .wizardM:  ["Avada Kedavra... 농담입니다.", "마법 = 디버그 가능한 코드.", "수염이 길수록 강력."],

        // ─── 0x72 — tall enemies (idle+run) ───────────────────────────
        .chort:        ["evil bit set된 도깨비.", "방망이 휘둘러요!", "재물 가져다 줄까요?"],
        .doc:          ["코드 리뷰가 진료입니다.", "처방전 받아 가세요.", "스트레스가 만병의 근원."],
        .maskedOrc:    ["나는 anonymous function.", "가면 안의 정체는 비밀.", "한정판 마스크입니다."],
        .orcShaman:    ["토템 = 디자인 패턴.", "조상의 영혼이 함께.", "치유와 저주 둘 다 됨."],
        .orcWarrior:   ["WAAAGH! merge conflict!", "전투야말로 인생.", "두꺼운 근육이 답이다."],
        .pumpkinDude:  ["할로윈에 commit 푸시.", "씨앗 까지 마세요. 아파요.", "잭오랜턴이 본명."],
        .wogol:        ["분류불명 = undefined.", "워골이 뭐냐고요? 저요.", "관찰만 하고 가세요."],

        // ─── 0x72 — tall single-anim ──────────────────────────────────
        .necromancer: ["deprecated 코드 부활술.", "해골 친구 100명 있음.", "주문서 5권 읽는 중."],
        .slug:        ["GC가 sluggish.", "껍데기는 없지만 자유.", "소금은 천적입니다."],

        // ─── 0x72 — small enemies (idle+run) ──────────────────────────
        .angel:       ["production guardian angel.", "할렐루야~ deploy!", "후광이 무거워요."],
        .goblin:      ["git stash로 보물 숨김.", "헤헤헤! 보물 어디?", "작아도 사악함은 만렙."],
        .imp:         ["unit test 깨는 게 본업.", "꼬리 잡기 금지.", "지옥에서 잠시 휴가."],
        .skelet:      ["나는 skeleton code 그 자체.", "달그락달그락.", "살은 좀 그리워."],
        .tinyZombie:  ["small zombie 객체.", "두뇌... 작은 거라도...", "엄마 좀비 어디?"],

        // ─── 0x72 — small single-anim ─────────────────────────────────
        .iceZombie:   ["frozen process.", "얼어붙은 분노...", "kill -9 부탁."],
        .muddy:       ["spaghetti code 좋아함.", "샤워는 사양합니다.", "비 오는 날이 좋아."],
        .swampy:      ["tech debt 늪에 사는 중.", "꾸르륵... 늪 친구야.", "악취는 정체성."],
        .tinySlug:    ["micro-service slug.", "꼬물꼬물 작은 영웅.", "큰형 따라 다녀요."],
        .zombie:      ["deprecated 됐는데 아직 동작.", "두뇌 주세요... BRAINS...", "걸음 느려도 끈질김."],

        // ─── 0x72 — big ───────────────────────────────────────────────
        .bigDemon:  ["demonic deadlock 발생.", "지옥에서 왔습니다.", "마계의 자랑."],
        .bigZombie: ["legacy monolith입니다.", "두뇌... 많이 주세요...", "크게 썩었어요."],
        .ogre:      ["ME SMASH compile error!", "양파 같은 layer 가졌어요.", "곤봉 한 자루로 충분."],

        // ─── Kings and Pigs ───────────────────────────────────────────
        .kingHuman: ["code review 최종 결정권자.", "신하는 어디에?", "옥좌가 그립다."],
        .kingPig:   ["PR 승인은 짐의 일이로다.", "꿀꿀, 짐의 명이로다.", "돼지 왕국 만세!"],
        .pig:       ["soldier process 출동.", "꿀꿀! 적 발견!", "단단한 갑옷 자랑."],
        .pigBoxer:  ["container 운반 중.", "택배 알바 중.", "꿀꿀, 무거워!"],
        .pigBomber: ["rm -rf 폭탄 받으세요!", "도화선 물고 다님.", "BOOM~"],

        // ─── Pirate Bomb ──────────────────────────────────────────────
        .bombGuy:        ["fork bomb 던지기 마스터.", "심지에 불 붙이는 손이 빨라요.", "콰광!"],
        .baldPirate:     ["내 머리는 zero-byte 포인터.", "광채가 곧 무기.", "선크림 많이 발라요."],
        .cucumber:       ["나는 ASCII green.", "오이 김밥 먹지 마요.", "바다 야채 동맹 가입."],
        .bigGuy:         ["monolith server 같은 존재.", "한주먹이면 끝!", "선창은 내가 지킨다."],
        .pirateCaptain:  ["나는 tech lead.", "보물 위치는 비밀.", "Yo ho ho!"],
        .whale:          ["Docker whale 친척입니다.", "푸하앗! 분수쇼.", "고래 고기는 사양."],

        // ─── Treasure Hunters ─────────────────────────────────────────
        .clownCaptain: ["production clown show 거부.", "광대 같지만 칼은 진짜.", "코가 빨개요. 자존심."],
        .fierceTooth:  ["치과 = QA team.", "이빨 자랑하러 왔습니다.", "물기 전에 도망가세요."],
    ]

    /// 종 전용 대사를 무작위로 한 줄 뽑는다. dict에 누락된 종은 `"..."`로 폴백 (무음에 가까움).
    static func random(for kind: PetKind) -> String {
        perPet[kind]?.randomElement() ?? "..."
    }

    // 1시간 동안 쉬지 않고 쓰면 펫이 외치는 휴식 권유 멘트.
    // 노란 spiky 말풍선으로 표시되며 클릭하면 사라진다.
    // (종 무관 — 어떤 펫이든 동일한 wellness 풀에서 뽑는다.)
    static let wellness: [String] = [
        "어깨 한번 돌려봐요!",
        "잠깐 일어나서 스트레칭!",
        "5분만 멍 때리고 와요!",
        "물 한 잔 마시고 와요!",
        "눈 좀 감았다 떠봐요!",
        "허리 쭉 펴봐요!",
        "창밖 한 번 보고 와요!",
        "심호흡 세 번!",
        "손목 좀 풀어줘요!",
        "산책 한 바퀴 어때요?",
    ]

    static func randomWellness() -> String {
        wellness.randomElement() ?? "쉬어가요!"
    }

    // 마우스가 펫 위로 hover 했을 때 나오는 리액션. 짧고 귀엽게.
    // (종 무관 — 어떤 펫이든 동일한 reaction 풀에서 뽑는다.)
    static let reactions: [String] = [
        "돈 땃쥐미!",
        "오지 마세용!",
        "건드리지 마!",
        "어디서 오는 손이고!",
        "악! 깜짝이야!",
        "내가 강아지야?",
        "거리 좀 둬요!",
        "왜 그러세용 ㅠㅠ",
        "잡으면 물어요!",
        "안 잡혀잡혀~",
        "1m 떨어져!",
        "스토커 신고함",
        "허락 없이 만지지 마!",
        "꺅!",
        "도망간다!",
    ]

    static func randomReaction() -> String {
        reactions.randomElement() ?? "꺅!"
    }
}
