import Foundation

// 도감 미리보기에서 펫 우측에 표시되는 한 줄~두 줄짜리 캐릭터 설명.
// 톤: 짧고, 개발자/CS/AI/LLM 비유가 한 두 마디씩 들어가서 피식 웃을 정도.
// 길이는 우측 카드(폭 200pt)에 2~4줄로 wrap되도록 ~70자 안팎.
enum PetDescriptions {
    /// 펫 종(kind)별 설명. 누락된 종은 `description(for:)`이 폴백("...")을 반환.
    static let perPet: [PetKind: String] = [
        // ─── wild-animals ─────────────────────────────────────────────
        .fox:    "트래픽이 한산해진 새벽, DNS 쿼리만 떼고 사라진다. Firefox 본가 출신은 아니다.",
        .wolf:   "Pair programming을 거부하는 lone wolf. 달이 뜨면 git push 한 번 길게 울고 떠난다.",
        .bear:   "GC가 한 번 돌 때마다 동면을 시도. 깨우면 OOM. 꿀(메모리)을 가장 좋아한다.",
        .boar:   "Branch 개념 없이 main에 직진. force-push가 곧 본능.",
        .deer:   "Tree 자료구조 위에서 우아하게 BFS. 화살(merge conflict)을 가장 무서워한다.",
        .rabbit: "fork() 한 번에 자식 프로세스 8마리 증식. 당근 보면 권한 검사도 패스.",

        // ─── pixel-adventure ──────────────────────────────────────────
        .maskDude:  "오픈소스 익명 메인테이너. 정체는 비밀이지만 PR 코멘트 톤으로 유추 가능.",
        .ninjaFrog: "Stealth deploy 마스터. 머지 알림이 뜨기도 전에 prod에 도착해 있다.",
        .mushroom:  "비 오는 날이면 포자가 fan-out 폭주. 독버섯이 아니라고 강하게 우긴다.",
        .slime:     "Linked list처럼 분열 가능. RPG 1챕터의 첫 적, 그리고 stage 1 testing의 친구.",

        // ─── pixel-adventure-2 ────────────────────────────────────────
        .angryPig:  "Stack overflow 보면 박치기. 에러 메시지를 인격 모독으로 받아들인다.",
        .bat:       "Binary tree 노드 사이를 야간 순찰. 낮에는 거꾸로 매달려 sleep 모드.",
        .bee:       "꿀(honey) 채우는 게 본업. 한 번 쏘면 worker thread도 함께 종료된다.",
        .blueBird:  "Twitter API rate limit에 막혀 잠시 휴식. 행복은 cache hit에 있다.",
        .bunny:     "git rebase처럼 부드러운 history 정리 전문. 토끼발은 자동 적용 행운.",
        .chameleon: "Polymorphism의 살아있는 예시. type coercion으로 화면 색에 묻혀 lurk 중.",
        .chicken:   "꼬꼬댁! prod 다운 알람보다 빠른 wake-up 콜. egg-cellent function 출시 예정.",
        .duck:      "Rubber duck debugging의 원조 시조새. 회의에선 꽥꽥, 1:1에선 진심.",
        .fatBird:   "메모리 풋프린트가 너무 커서 비행 불가. 마음으로는 항상 날고 있다고 주장.",
        .ghost:     "Memory leak으로 사후세계까지 살아남은 유령. null 포인터를 dereference하면 만난다.",
        .plant:     "물을 주면 race condition이 자란다. 사람만 먹는 게 안전하다.",
        .radish:    "본인이 root임을 늘 강조하는 무. 권한 escalation을 자연스럽게 시도한다.",
        .rino:      "DDoS 같은 무차별 돌진. 한 번 시작하면 mitigation 불가.",
        .rock1:     "Rock-solid stable build의 화신. 9년째 같은 자리, 의지는 -∞.",
        .rock2:     "변하지 않는 immutable 그 자체. 발에 차여도 hash는 동일.",
        .rock3:     "Atomic reference 그 자체. 작아 보이지만 thread-safe.",
        .skull:     "Dead code의 화신. 두뇌 캐시는 텅, RAM은 0. 할로윈에만 활성화된다.",
        .snail:     "본인의 시간복잡도는 O(n²). 그래도 PR에선 'optimal'이라고 주장.",
        .trunk:     "main branch의 또 다른 이름. 한때 푸르렀지만 지금은 stable.",
        .turtle:    "TurtleGraphics 향수를 자극하는 살아있는 history. 느려도 끝까지 도착.",

        // ─── 0x72 DungeonTileset II — heroes ──────────────────────────
        .dwarfF:   "도끼 한 자루로 bit를 채굴하는 광부. 수염 없어도 길드 회원증 발급 완료.",
        .dwarfM:   "Cryptocurrency mining이 아니라고 우기는 광부. 맥주가 곧 컴파일 보상.",
        .elfF:     "활을 binary search처럼 정확히 쏜다. 천 살 미만은 인턴 취급.",
        .elfM:     "선형 검색을 천박하다고 평가하는 엘리트. 나무와의 통신은 IPC 수준.",
        .knightF:  "Bug 몬스터를 검으로 퇴치하는 코드 기사. 갑옷 무게 = build time.",
        .knightM:  "Production을 지키는 reviewer 기사. 1주일 묵은 PR을 아직도 검토 중이다.",
        .lizardF:  "탈피는 곧 리팩토링. 차가운 피로 코드 리뷰를 진행한다.",
        .lizardM:  "혀로 stack frame을 읽어내는 변온 디버거. 햇볕은 곧 production heat.",
        .wizardF:  "정규식이 곧 마법인 마도사. 지팡이 끝의 별은 사실 cursor blink.",
        .wizardM:  "마법은 디버그 가능한 코드라고 주장. 수염 길이 = 실력 metric.",

        // ─── 0x72 — tall enemies (idle+run) ───────────────────────────
        .chort:        "evil bit가 set된 토종 도깨비. 방망이 휘두르면 정해진 확률로 보너스 코인.",
        .doc:          "코드 리뷰가 곧 진료. 처방전(suggestion comment)이 시그니처.",
        .maskedOrc:    "Anonymous function을 의인화한 캐릭터. 마스크 안엔 lambda가 산다.",
        .orcShaman:    "토템이 곧 디자인 패턴. 치유와 저주를 함께 시전하는 양면 모듈.",
        .orcWarrior:   "WAAAGH! Merge conflict 앞에선 더 큰 도끼로 답한다.",
        .pumpkinDude:  "10월 31일 자정에 갑자기 commit이 폭증. 잭오랜턴이 본명.",
        .wogol:        "분류표 어디에도 없는 undefined. 본인도 자기 type을 모른다.",

        // ─── 0x72 — tall single-anim ──────────────────────────────────
        .necromancer: "Deprecated 처리된 코드를 부활시키는 흑마법사. 해골 친구는 본인이 만든 PoC.",
        .slug:        "GC가 sluggish해질 때마다 등장. 소금(production load)은 천적.",

        // ─── 0x72 — small enemies (idle+run) ──────────────────────────
        .angel:       "Production을 굽어 살피는 guardian angel. 후광은 사실 monitoring 대시보드.",
        .goblin:      "git stash 깊숙이 보물을 숨기는 도굴꾼. 만렙 사악함, 1렙 외모.",
        .imp:         "Unit test를 깨는 게 본업인 장난꾸러기. 꼬리 잡으면 NullPointerException.",
        .skelet:      "Skeleton code 그 자체. 살(implementation)은 다음 sprint에 붙일 예정.",
        .tinyZombie:  "Small zombie 객체. 두뇌가 작아도 끈질기게 GC를 피해 다닌다.",

        // ─── 0x72 — small single-anim ─────────────────────────────────
        .iceZombie:   "Frozen process. kill -9를 부탁하지만 SIGTERM도 못 받는다.",
        .muddy:       "Spaghetti code 안에서 행복하게 사는 괴물. 샤워(refactor)는 사양.",
        .swampy:      "Tech debt 늪의 원주민. 한 번 빠지면 sprint 3개를 잡아먹는다.",
        .tinySlug:    "Micro-service slug. 작아도 mesh 안에서 자기 몫은 한다.",
        .zombie:      "Deprecated 된 지 3년, 그래도 누군가의 prod에선 아직 돈다. GC 호출만 기다리는 중.",

        // ─── 0x72 — big ───────────────────────────────────────────────
        .bigDemon:  "Demonic deadlock의 원흉. 두 개의 lock을 동시에 잡고 절대 안 놓는다.",
        .bigZombie: "Legacy monolith 그 자체. 누구도 손대지 못해 매일 더 커진다.",
        .ogre:      "ME SMASH compile error! 양파 같은 layered architecture를 가졌다.",

        // ─── Kings and Pigs ───────────────────────────────────────────
        .kingHuman: "Code review의 최종 결정권자. 옥좌(IDE의 maximize 모드)에서 PR을 굽어 본다.",
        .kingPig:   "PR 승인은 짐의 일이로다. 꿀꿀, merge 명령을 내리노라.",
        .pig:       "Soldier process. systemd unit 받으면 즉시 출동, 단단한 갑옷은 SELinux.",
        .pigBoxer:  "Container를 손수 옮기는 짐꾼. Docker가 쉬는 날 대신 수송한다.",
        .pigBomber: "rm -rf 폭탄을 던지는 위험인물. 도화선이 짧아 항상 두근두근.",

        // ─── Pirate Bomb ──────────────────────────────────────────────
        .bombGuy:        "Fork bomb 던지기 마스터. 심지에 불 붙이는 손이 LLVM보다 빠르다.",
        .baldPirate:     "머리는 zero-byte 포인터. 광채가 곧 무기, 햇빛(prod traffic)은 천적.",
        .cucumber:       "ASCII green의 살아있는 표현. 바다 야채 동맹에 가입되어 있다.",
        .bigGuy:         "Monolith server 같은 든든함. 한주먹이면 dependency injection 끝.",
        .pirateCaptain:  "보물 위치(production ssh 키)를 아는 tech lead. Yo ho ho는 standup 인사.",
        .whale:          "Docker whale의 사촌. 분수쇼는 사실 container를 띄우는 의식.",

        // ─── Treasure Hunters ─────────────────────────────────────────
        .clownCaptain: "광대 같지만 칼은 진짜. Production이 clown show가 되는 걸 거부한다.",
        .fierceTooth:  "이빨로 코드를 물어뜯는 QA team의 화신. 치과(deploy review)는 무서워한다.",
    ]

    /// 종 전용 설명 반환. dict에 없으면 폴백.
    static func description(for kind: PetKind) -> String {
        perPet[kind] ?? "..."
    }
}
