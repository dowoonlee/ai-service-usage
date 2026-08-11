import Foundation

/// 머지된 PR 기여자 목록 — **서버(`contributors` Edge Function)에서** 받아온다.
///
/// 예전엔 클라가 각자 GitHub `/pulls?state=closed&per_page=100`을 직접 호출했는데 두 군데서 깨졌다:
///   1. 비인증 GitHub API는 **IP 단위** 60req/h다. 사내망 NAT이면 전 사용자가 한 IP를 공유해 소진된다.
///   2. `/pulls`는 생성 역순 100개만 준다. 리포 PR이 215개까지 늘면서 외부 기여자 PR(#3·#8·#45·#59)이
///      조회 창(#95~#215) 밖으로 밀려 목록이 **조용히 빈 배열**이 됐다(캐시에 `[]`가 그대로 저장됨).
/// 서버는 Search API로 조건에 맞는 PR만 받아 DB에 캐시하므로 PR 수가 늘어도 재발하지 않는다.
///
/// `ContributorBonus`와는 여전히 별개다: 그쪽은 사용자 자기 토큰으로 자기 PR을 검색해 코인을 적립하고,
/// 이쪽은 공개 목록을 UI에 표시하는 용도다.
@MainActor
final class Contributors: ObservableObject {
    static let shared = Contributors()

    @Published private(set) var list: [Contributor] = []

    /// 로컬 재조회 주기. 서버가 24h TTL로 GitHub을 긁으므로 클라는 자주 물어볼 이유가 없다.
    /// 실제 GitHub 호출량은 클라 수와 무관하다 — 서버 한 곳에서만 나간다.
    /// (오너 제외는 서버가 한다 — 클라엔 그 규칙이 남아 있지 않다.)
    private static let cacheTTL: TimeInterval = 6 * 3600
    /// v1에는 옛 경로가 만들어 둔 **빈 배열**이 남아 있다. 키를 올리지 않으면 업데이트 직후에도
    /// TTL이 만료될 때까지 빈 목록이 그대로 보인다 — 그래서 v2로 끊는다.
    private static let cacheKey = "contributors.cache.v2"

    private struct Cache: Codable {
        let fetchedAt: Date
        let contributors: [Contributor]
    }

    private init() {
        list = loadCache()?.contributors ?? []
    }

    /// App 시작 시 + 추후 24h 주기 호출용. 캐시가 신선하면 no-op.
    /// 모든 예외 흡수 — 네트워크 실패 시 기존 캐시 유지.
    func refreshIfNeeded() async {
        if let c = loadCache(), Date().timeIntervalSince(c.fetchedAt) < Self.cacheTTL {
            return
        }
        do {
            let fetched = try await fetch()
            list = fetched
            save(Cache(fetchedAt: Date(), contributors: fetched))
            DebugLog.log("Contributors: refreshed, \(fetched.count) external contributor(s)")
        } catch {
            DebugLog.log("Contributors: refresh failed: \(error.localizedDescription)")
        }
    }

    private func fetch() async throws -> [Contributor] {
        guard RankingAPI.isConfigured else {
            throw NSError(domain: "Contributors", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "랭킹 서버 미설정"])
        }
        let resp = try await RankingAPI.shared.fetchContributors()
        // 정렬은 서버가 이미 해 두지만(PR 많은 순 → 최근 머지순), 표시 순서는 클라가 책임진다.
        // 구버전 서버가 정렬 없이 주더라도 화면이 흔들리지 않도록 여기서 한 번 더 확정한다.
        return Self.sorted(resp.contributors.map {
            Contributor(login: $0.login, avatarURL: $0.avatarURL,
                        prs: $0.prs.sorted { $0.mergedAt > $1.mergedAt })
        })
    }

    /// 표시 순서 — 1차 PR 개수 내림차순, 동점이면 최근 머지가 위.
    nonisolated static func sorted(_ list: [Contributor]) -> [Contributor] {
        list.sorted { lhs, rhs in
            if lhs.prs.count != rhs.prs.count { return lhs.prs.count > rhs.prs.count }
            return (lhs.prs.first?.mergedAt ?? .distantPast) > (rhs.prs.first?.mergedAt ?? .distantPast)
        }
    }

    private func loadCache() -> Cache? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let c = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        return c
    }

    private func save(_ c: Cache) {
        if let data = try? JSONEncoder().encode(c) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

struct Contributor: Codable, Hashable, Identifiable {
    let login: String
    let avatarURL: String?
    let prs: [PullRequest]
    var id: String { login }
}

struct PullRequest: Codable, Hashable {
    let number: Int
    let title: String
    let mergedAt: Date
}
