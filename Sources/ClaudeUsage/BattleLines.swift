import Foundation

// 아레나 배틀 중 펫이 내뱉는 짧은 대사 풀 (오리지널, dev-밈 톤 — 기존 Quotes와 일관).
// 순수 코스메틱: 승패에 영향 없음. 로컬 재생 시 무작위 선택(서버 authoritative 도입 시 인덱스 동기화 가능).
enum BattleLines {
    /// 공격 시.
    static let attack: [String] = [
        "받아라, 핫픽스!",
        "이건 못 막지 ㅋ",
        "머지 강행!",
        "force push 간다",
        "성능 최적화 나간다",
        "프로덕션 반영각",
        "리팩터 한 방",
        "커밋 앤 푸시!",
        "이 버그, 내가 잡는다",
        "빌드 통과각",
        "배포 준비 완료",
        "네 코드는 여기까지다",
    ]

    /// 리타이어(기절) 시.
    static let faint: [String] = [
        "롤백된다…",
        "장애 접수…",
        "다음 스프린트에 보자…",
        "이슈 재오픈 좀…",
        "메모리가… 부족…",
        "커넥션 끊김…",
        "postmortem 부탁해…",
        "504… 게이트웨이…",
        "OOM… killed…",
        "다운타임… 시작…",
    ]

    /// 패링(퍼펙트 가드) 성공 시.
    static let parry: [String] = [
        "그 공격, 읽었다",
        "퍼펙트 가드!",
        "막았다!",
        "그 정도로는 안 돼",
        "예외 처리 완료",
        "try-catch 완벽",
        "가드 성공",
    ]

    static func attackLine() -> String { attack.randomElement() ?? "받아라!" }
    static func faintLine() -> String { faint.randomElement() ?? "다운…" }
    static func parryLine() -> String { parry.randomElement() ?? "막았다!" }

    /// 컬렉션별 시그니처 기술명 (dev-밈 톤). basic은 무미건조한 "기본 공격" 대신 짧은 플레이버.
    static let signatureMove: [PetCollection: String] = [
        .mainframe:        "메인프레임 강타",
        .dns:              "DNS 전파 지연",
        .npmInstall:       "의존성 폭탄",
        .nodeModules:      "node_modules 낙하",
        .todoSince2019:    "기술부채 청구서",
        .wontfix:          "won't fix",
        .fridayDeploy:     "금요일 5시 배포",
        .vibeCoders:       "바이브 코딩",
        .tokenBurners:     "토큰 올인",
        .rustEvangelists:  "rewrite it in Rust",
        .noVerify:         "--no-verify",
        .happyPath:        "해피 패스",
        .onCall:           "온콜 호출",
        .ciRunners:        "CI 파이프라인",
        .helloWorld:       "Hello, World!",
        .oomKilled:        "OOM Kill",
        .deprecated:       "deprecated 태그",
        .tenXEngineer:     "10x 리팩터",
        .emotionalSupport: "정서적 지지",
    ]

    /// 이벤트 무브 표시명. signature면 컬렉션 기술명, basic이면 짧은 기본 공격명.
    static func moveName(collection: PetCollection, signature: Bool) -> String {
        signature ? (signatureMove[collection] ?? "시그니처") : "기본 공격"
    }
}
