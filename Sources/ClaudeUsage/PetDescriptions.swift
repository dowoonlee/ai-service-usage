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

        // ─── Calciumtrice Slime / Ansimuz Sunny Land ──────────────────
        .jellySlime: "초보 사냥터의 영원한 마스코트. 물컹한 겉모습과 달리 속은 의외로 thread-safe하다.",
        .sunFrog:    "배를 부풀리면 buffer overflow 직전. 파리 잡기가 곧 GC, 점프 한 번이 main loop.",
        .oposum:     "위협받으면 즉시 죽은 척 graceful shutdown. 주머니에 캐시를 넣고 night build를 돌리는 야행성.",
        .sunFox:     "side-scroller 월드의 주인공. 점프 한 방에 플랫폼을 클리어하고 모험을 daily routine처럼 떠난다.",
        // Tiny Swords 엘리트 기사단 (Mythic/Legendary)
        .warrior:    "프로덕션 장애가 터지면 가장 먼저 칼을 빼 든다. main 브랜치의 최후 방어선.",
        .lancer:     "긴 창으로 멀리서도 레거시 코드를 꿰뚫는다. 기마 배포 속도는 따라올 자가 없다.",
        .monk:       "조용히 기도하면 빨간 CI도 초록으로. 힐링 스택은 rm -rf node_modules와 재시작.",
        .archer:     "원거리 저격수. 프로덕션 버그를 핫픽스 화살로 정확히 떨군다.",
        .pawn:       "묵묵한 막내 일꾼. 잡일과 빌드잡을 도맡지만 언젠가 전설이 될 재목.",
        // 0x72 Robot Tileset — "CI Runners" (자동화 봇)
        .scrapBot:   "9년째 재부팅 없이 도는 레거시 러너. 어디를 만져도 삐걱대지만 빌드는 통과시킨다.",
        .antennaBot: "안테나로 webhook을 수신하는 이벤트 드리븐 봇. 알림이 뜨면 가장 먼저 깨어난다.",
        .pixelBot:   "LED 격자 얼굴로 로그를 스크롤한다. 표정이 곧 stdout, 빨간 픽셀은 stderr.",
        .spiderBot:  "여덟 다리로 사이트를 기어다니는 크롤러. robots.txt는 가끔 못 본 척한다.",
        .sentryBot:  "분홍 눈으로 대시보드를 감시하는 모니터링 봇. 임계값 넘으면 즉시 페이지.",
        .miniBot:    "제일 작지만 병렬로 100개씩 뜨는 경량 러너. 컨테이너 하나가 곧 본체.",
        .visorBot:   "보라 바이저 뒤에서 파이프라인을 지휘하는 오케스트레이터. 실패한 잡을 재시도로 되살린다.",
        .batBot:     "야간 배치를 도맡는 박쥐귀 크론봇. 낮엔 대기, 새벽 3시에 조용히 출동.",
        .beaconBot:  "머리 위 신호등으로 배포 상태를 알린다. 초록이면 안심, 노랑이면 롤백 준비.",
        // GrafxKid Sprite Pack 1 — "Hello World" (레트로 플랫포머 마스코트)
        .mrMan:      "튜토리얼 스테이지의 주인공. 어떤 프레임워크를 깔아도 가장 먼저 찍히는 첫 캐릭터.",
        .bumpyBot:   "범프 매핑도 모르면서 범피라 불린다. 부딪히며 배우는 게 그의 디버깅 방식.",
        .princessSera: "성(城) 아키텍처의 소유자. 접근하려면 인증 두 단계와 드레스 코드를 통과해야 한다.",
        .bushly:     "config에 박혀 자란 덤불. 아무도 안 건드려서 프로덕션의 일부가 되어버렸다.",
        .devoDevil:  "금요일 오후에 나타나는 꼬마 악마. \"deploy 한 번만 더\"를 속삭인다.",
        .rollingNero: "한 번 구르기 시작하면 못 멈추는 무한 루프. break 조건을 깜빡했다.",
        .gloppySlime: "가장 낮은 레벨의 첫 적. 튜토리얼에서 죽어주는 게 존재 이유인 착한 슬라임.",
        .chiChiBird: "트윗처럼 짧게 지저귄다. 날갯짓은 poll 주기, 착지는 rate limit.",
        .diverFish:  "prod 로그의 심해까지 잠수하는 물고기. 산소는 곧 배터리, 부상은 곧 flush.",
        .bub:        "버블 하나 뿜으면 적이 갇힌다. 원조 arcade 감성의 mutex.",
        .spikeyBub:  "가시가 돋아 함부로 못 안는다. 방어적 프로그래밍의 화신.",
        .pokeyBub:   "뾰족한 성격이지만 사실 겁쟁이. 위협받으면 보호막(try/catch)부터 친다.",
        .blockyBub:  "각진 몸으로 stack에 착착 쌓인다. 정렬(align)은 그의 신념.",
        // GrafxKid Sprite Pack 2 — 음식·사물 마스코트
        .onionLad:   "까면 깔수록 레이어가 나온다. 디버깅하다 눈물 흘리게 만드는 그 양파.",
        .mrMochi:    "말랑한 겉과 달리 코어는 단단하다. 늘려도 안 끊기는 sticky session.",
        .octi:       "다리 8개로 동시에 8스레드. 먹물 한 방이 곧 코드 obfuscation.",
        .roboPumpkin: "할로윈에만 배포되는 시즌 한정 봇. cron은 '0 0 31 10 *'.",
        .daikon:     "뿌리부터 root 권한. 뽑으면 의존성이 줄줄이 딸려 나온다.",
        .roboTotem:  "쌓을수록 강해지는 스택 머신. 맨 아래 칸이 base case.",
        .rocketCherry: "체리픽 커밋 하나로 급가속. 착지 지점은 아무도 예측 못 한다.",
        .cheesePuff: "탱크 몰고 다니는 과자. 부스러기(로그)를 흘리며 전진한다.",
        .snipCrab:   "옆으로만 걷는 legacy 마이그레이션. 집게에 잡히면 deadlock.",
        // GrafxKid Sprite Pack 3 — 로봇·모험가
        .gumBot:     "화면 머리에 로그를 띄우는 봇. 씹을수록 늘어나는 게 껌인지 기술부채인지.",
        .twiggy:     "초록 머리의 픽셀 소녀. 나뭇가지처럼 가볍게 브랜치를 쳐 나간다.",
        .robotJ5:    "불을 뿜는 구형 로봇. \"쇼트 서킷\" 나던 시절 레거시지만 아직 안 죽었다.",
        .tommy:      "달리기가 특기인 소년. 벤치마크에선 늘 1등, 별명이 'fast runner'.",
        .geralt:     "버그 사냥으로 먹고사는 백발의 위쳐. 계약(티켓)만 있으면 어디든 간다.",
        // GrafxKid Sprite Pack 4~8 — 마스코트·몬스터·모험가·기사
        .agentMike: "권총 든 픽셀 요원. 침투는 stealth deploy, 정체는 always 익명.",
        .martianRed: "화성에서 온 빨간 외계인. 우리 코드베이스가 그에겐 미지의 행성.",
        .hermie: "남의 껍데기(레거시 코드) 주워 사는 소라게. 리팩터링? 그냥 이사간다.",
        .ballooney: "둥둥 뜨는 풍선. 스코프 하나 터지면 같이 팡 하고 사라진다.",
        .robotWalky: "뚜벅뚜벅 순찰만 도는 워커 봇. health check가 유일한 취미.",
        .jumpyLumpy: "통통 튀는 파란 젤리. 스택 프레임을 트램펄린 삼아 뛴다.",
        .orchidOwl: "밤에만 깨어나 로그를 감시하는 올빼미. 야근의 상징.",
        .roach: "never die 바퀴벌레. prod에서 아무리 밟아도 재현되는 그 버그.",
        .mrCircuit: "회로가 훤히 보이는 투명 로봇. 그의 사고는 전부 오픈소스.",
        .blankey: "둥둥 떠다니는 담요 유령. 덮으면 따뜻하지만 memory leak은 못 막는다.",
        .roboRetro: "조종석 딸린 구형 메카. 부팅에 5분, 하지만 한 번 뜨면 절대 안 죽는다.",
        .lilWiz: "작지만 토큰을 펑펑 태우는 견습 마법사. 주문 하나가 곧 프롬프트.",
        .bigRed: "커질 대로 커진 빨간 덩어리. 기술부채가 인격을 얻으면 이렇게 된다.",
        .squirmyWormy: "꿈틀대며 나아가는 분홍 지렁이. linked list를 몸으로 시연한다.",
        .moeScotty: "팔랑이는 청록 나방. 로그 불빛만 보면 못 참고 달려든다.",
        .mrChomps: "닥치는 대로 씹어 삼키는 촘퍼. context window를 통째로 먹어치운다.",
        .grizzly: "GC 돌 때마다 동면하는 회색곰. 깨우면 그 자리에서 OOM.",
        .orc: "덩치로 밀어붙이는 오크. \"Rust로 다시 짜면 되잖아\"가 입버릇.",
        .wispyFire: "일렁이는 도깨비불. 5년째 안 꺼지는 TODO 주석의 화신.",
        .penguin: "날지 못하지만 수영은 1등. 콜드 스토리지 담당 펭귄.",
        .fairy: "반짝이는 가루를 뿌리는 요정. hotfix에 마법의 한 방을 더한다.",
        .skeletonG: "다시 일어서는 해골 병사. 닫은 이슈처럼 자꾸 부활한다.",
        .orangeFruit: "데굴데굴 구르는 오렌지. 짜면 나오는 건 주스가 아니라 스택 트레이스.",
        .diego: "총잡이 모험가. 프로덕션 버그를 정조준으로 핫픽스한다.",
        .holly: "초록 머리의 여전사. 던전이든 레거시든 겁 없이 뛰어든다.",
        .gordon: "대검 든 청기사. 한 번 휘두르면 merge conflict가 두 동강.",
        .toggle: "방패 든 기사 토글. feature flag를 켰다 껐다 하며 싸운다.",
        .tracy: "석궁 든 여궁수. 버그를 원거리에서 한 발에 떨군다.",
        .armand: "백전노장 기사. 어떤 레거시 던전도 눈 감고 클리어한다.",
        .percy: "호기심 많은 꼬마 모험가. 첫 커밋의 설렘을 아직 간직한다.",
        .vessa: "춤추는 소녀 베사. 그린 CI가 뜨면 스텝을 밟는다.",
        .angie: "분홍빛 요정 앤지. 반짝임으로 스탠드업을 밝힌다.",
        .barryCherry: "쌍둥이 체리 배리. 체리픽 커밋이 특기, 늘 둘이 붙어 다닌다.",
        // LuizMelo Monsters Creatures Fantasy — 다크판타지 몬스터
        .flyingEye: "허공을 떠도는 외눈 감시자. 모든 PR을 노려보지만 approve는 안 한다.",
        .goblinBrute: "단검 든 고블린. 코드 리뷰 대신 일단 칼부터 뽑는다.",
        .myconid: "포자를 뿜는 버섯 마수. 한 번 감염되면 모듈 전체로 fan-out.",
        .skeletonLord: "방패와 검을 든 해골 기사. 죽어서도 on-call을 놓지 않는 언데드.",
        // Superpowers 공룡 — "Deprecated" (멸종했지만 prod에 남은 것들)
        .tRex: "생태계 최상위 포식자. prod를 지배하는 절대 권력이지만, 팔이 짧아 키보드가 멀다.",
        .miniRex: "작지만 이빨은 진짜. 언젠가 대장이 될 주니어 렉스.",
        .pterodactyl: "하늘을 지배한 익룡. 배포 현장을 공중에서 내려다본다.",
        .dinoDragon: "아직 불을 못 뿜는 새끼 용. 언젠가 prod를 통째로 태울 재목.",
        .dinoLizard: "재빠른 고생대 도마뱀. 꼬리 자르고 도망치는 게 그의 롤백 전략.",
        .dinoPlant: "지나가는 요청을 덥석 무는 쥐라기 식충식물. 뿌리는 못 옮겨도 입은 빠르다.",
        .dinoBug: "삼엽충 시절부터 기어온 벌레. 코드베이스에서 가장 오래된 레거시 종.",
        .dinoTurtle: "느리지만 절대 안 죽는 고대 거북. 등껍질이 곧 방화벽.",
        .dinoBat: "쥐라기 밤하늘을 순찰하는 익수룡. 야간 배치의 원조.",
    ]

    /// 종 전용 설명 반환. dict에 없으면 폴백.
    static func description(for kind: PetKind) -> String {
        perPet[kind] ?? "..."
    }
}
