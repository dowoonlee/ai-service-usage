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
    static func demoNew() -> [RankingAPI.AnnouncementRow] {
        [
            RankingAPI.AnnouncementRow(
                version: "0.14.0",
                title: "그동안의 업데이트 모아보기 🎉",
                body: """
                이제 업데이트 후 바뀐 점을 이 창으로 알려드려요. 상단 📣 버튼으로 언제든 다시 볼 수 있습니다.
                그동안 공지 없이 추가됐던 코스메틱·RP 기능을 한 번에 정리했어요.

                **RP — 랭킹 보상 화폐**
                - 월간·주간 랭킹 순위에 따라 RP 적립
                - RP로 프리미엄 가챠권 구매 (1,500 RP)
                - 코스메틱 이펙트(무지개·후광·오라·잔상·발자국) 장착 재화

                **Mythic 티어 & 프리미엄 가챠**
                - Legendary 위 최상위 Mythic 등급 (★★★★★)
                - 프리미엄 가챠권 전용 [Mythic·Legendary] 정예 풀 (sudo pull)
                - Mythic 펫은 1.5배 크기 + 진홍·금 회전 오라

                **새 펫 · Tiny Swords 5종**
                - 전사·창기병·수도사(Mythic) / 궁수·일꾼(Legendary)
                - 수집 업적 On-Call 컬렉션 (완성 보너스 33,000 coin)

                **차트 맵 테마 12종**
                - 정적 4: 잔디밭·들판·황야·우주
                - 동적 8: 바다·설산·사막·화산·오로라·벚꽃·뇌우·독성 늪
                - 파티 탭 맵 상점에서 코인으로 구매

                **펫 파티 & 코스메틱**
                - 차트당 최대 3마리 동시 보행 (가챠 파티 탭)
                - 트레이너 카드 walk 애니메이션 + 움직이는 GIF 내보내기
                - 랭킹 시상대 펫이 단 위를 걸어다니며 이펙트 표시

                **도장(Gym) 확장**
                - Codex 카테고리 + Registry 지역 추가
                - 지역 마스터 보상(프리미엄 가챠권) + production 칭호
                """,
                publishedAt: Date()),
        ]
    }
    /// 로컬 미리보기용 — 샘플 이전 공지.
    static func demoPrevious() -> [RankingAPI.AnnouncementRow] {
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
