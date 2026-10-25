import Foundation

/// 패치 공지 — 업데이트 후 첫 실행 시 (직전 본 버전, 현재 버전] 구간 공지를 별도 창으로 표시.
///
/// 정책:
///   * **업데이트할 때만** — 신규 설치(lastSeen=nil)는 현재 버전으로 seed만 하고 표시 안 함.
///   * fetch 성공 시에만 lastSeen 전진(빈 결과여도). 네트워크 실패면 전진 안 함 → 다음 실행 재시도.
///     따라서 운영자는 공지 row를 릴리스 시점에 미리 넣어 둬야 한다(늦게 넣으면 먼저 올린
///     사용자는 그 버전 공지를 놓침).
///   * RankingAPI 미구성(dev/번들 없음) 또는 사용자 설정 off면 조용히 skip — 앱 동작에 영향 없음.
@MainActor
final class AnnouncementManager {
    static let shared = AnnouncementManager()
    private init() {}

    /// 새 공지와 함께 가져올 이전(이미 본) 공지 개수.
    static let previousCount = 3

    /// 앱 시작 시 1회. `App.applicationDidFinishLaunching`에서 호출.
    func checkOnLaunch() {
        guard Settings.shared.patchNotesEnabled else { return }
        guard RankingAPI.isConfigured else { return }
        // dev 실행(번들 없음)은 appVersion=nil → skip.
        guard let current = RankingAPI.appVersion, !current.isEmpty else { return }

        guard let lastSeen = Settings.shared.lastSeenAnnouncementVersion, !lastSeen.isEmpty else {
            // 신규 설치 — 현재 버전으로 seed, 표시 안 함 (업데이트할 때만 정책).
            Settings.shared.lastSeenAnnouncementVersion = current
            return
        }
        // 동일 버전 / 다운그레이드 → 표시할 것 없음. lastSeen 유지.
        guard Self.isNewer(current, than: lastSeen) else { return }

        Task { [current, lastSeen] in
            do {
                let resp = try await RankingAPI.shared.fetchAnnouncements(
                    currentVersion: current, sinceVersion: lastSeen, previousCount: Self.previousCount)
                // 성공 → lastSeen 전진(빈 결과여도). 실패면 catch로 빠져 전진 안 함 → 다음 실행 재시도.
                Settings.shared.lastSeenAnnouncementVersion = current
                // 창 표시 여부는 "새 공지" 유무로만 판단 — 이전 공지는 매번 존재하므로 트리거에서 제외.
                guard !resp.announcements.isEmpty else {
                    DebugLog.log("Announcements: \(lastSeen)→\(current) 표시할 새 공지 없음")
                    return
                }
                AnnouncementWindowController.shared.present(
                    new: resp.announcements, previous: resp.previous ?? [])
            } catch {
                DebugLog.log("Announcements: fetch 실패, 다음 실행 재시도: \(error)")
            }
        }
    }

#if DEBUG
    /// 로컬 미리보기용 — 샘플 새 공지. `presentDemo` + 확성기 브라우즈 데모가 공유.
    /// 실제 발행 본문 초안과 동일하게 맞춰, dev 미리보기에서 copy/스크롤을 그대로 검증한다.
    /// 순수 데이터 빌더라 `nonisolated` — 비격리 컨텍스트(View.loadBrowse)에서 await 없이 호출.
    nonisolated static func demoNew() -> [RankingAPI.AnnouncementRow] {
        [
            RankingAPI.AnnouncementRow(
                version: "0.19.0",
                title: "직접 지휘하는 아레나와 레인보우 특전",
                body: """
                내 펫을 직접 지휘하는 수동 전투가 추가되었습니다.

                ## 수동 전투

                - 아레나 → 연습전 → **직접 조작·수동 연습전**에서 기술·교체·방어를 선택할 수 있습니다.
                - 기술 사용 횟수(PP), 상성, 상태이상, 궁극기를 언제 사용할지 직접 판단합니다.
                - 펫이 없어도 **대여 팀으로 배우기**로 시작할 수 있습니다.
                - 저장·이어하기, 같은 조건 재도전, AI에게 맡기기, 빠른 연출을 지원합니다.
                - 기존 자동 관전과 자동 랭크전은 그대로 이용할 수 있습니다.

                ## 레인보우 궁극기 두 갈래

                - 레인보우 펫은 전투 전에 궁극기 A·B를 무료로 선택합니다. 6타입에 총 12종입니다.
                - 광역과 단일 공격, 방어 관통과 자기 보호, 자기 회복과 팀 회복처럼 서로 다른 역할을 고를 수 있습니다.
                - 팀 공용 게이지를 누구의 궁극기에 사용할지도 전략이 됩니다.

                ## 전투 업적과 숙련 훈장

                - 트레이너 업적 일반 6개·히든 2개와 전용 칭호 8종을 추가했습니다.
                - 레인보우 펫이 활약하며 쌓은 승리에는 1·10·30·100승 훈장과 궁극기 A·B 문양을 제공합니다.
                - 공식 기록은 **보유 기록이 검증된 서버 경기**에서만 적립됩니다. 미검증 팀에는 미적립 안내가 표시됩니다.
                - 연습전에서는 조건 달성 여부를 미리 확인할 수 있으며, 연습 달성은 공식 칭호를 해금하지 않습니다.
                - 수동 서버 도전은 베타로 하루 10회(KST), 경기 이어하기 24시간이며 코인·Elo 보상은 없습니다.

                ## 도장 업적이 더 명확해졌습니다

                - 19개 업적에 한국어 이름, 해야 할 활동, 현재 기록, 다음 지표 기준과 남은 수치를 표시합니다.
                - 예를 들어 Tenure는 **길드 최초 가입 후 지난 기간**이라는 설명과 기준 날짜를 보여줍니다.
                - 툴팁에서 집계 방식과 제외 조건을 확인할 수 있으며, 관장 격파 후 뱃지·보상을 얻는 흐름도 안내합니다.

                자세한 조작 방법은 앱의 책 아이콘 → **아레나(수동·자동 전투)** 가이드에서 확인할 수 있습니다.
                """,
                publishedAt: Date()),
        ]
    }
    /// 로컬 미리보기용 — 샘플 이전 공지. 동일 이유로 `nonisolated`.
    nonisolated static func demoPrevious() -> [RankingAPI.AnnouncementRow] {
        let now = Date()
        return [
            RankingAPI.AnnouncementRow(
                version: "0.13.3", title: "안정성 개선",
                body: "- Codex credits 견고화\n- 진단 화이트리스트 확장", publishedAt: now),
            RankingAPI.AnnouncementRow(
                version: "0.13.2", title: "도장 레이아웃 수정",
                body: "가챠 패널 탭별 상단 공백 불일치를 제거했습니다.", publishedAt: now),
            RankingAPI.AnnouncementRow(
                version: "0.13.1", title: "버그 수정",
                body: "도장 vibe 맵 선택 시 레이아웃 점프를 제거했습니다.", publishedAt: now),
        ]
    }
    /// `AIUSAGE_ANNOUNCE_DEMO=1 swift run` 에서만 호출(App.swift). 릴리스 빌드엔 미포함.
    /// Supabase 미구성/번들 없는 dev 실행에서도 자동 팝업 UI 확인 가능.
    func presentDemo() {
        AnnouncementWindowController.shared.present(new: Self.demoNew(), previous: Self.demoPrevious())
    }
#endif

    // MARK: - semver 비교 ("a.b.c" 숫자 컴포넌트). 서버 cmpVersion과 동일 규칙.

    static func isNewer(_ a: String, than b: String) -> Bool { compare(a, b) > 0 }

    /// a<b → -1, a==b → 0, a>b → 1. 컴포넌트 수가 달라도 짧은 쪽을 0으로 패딩.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
