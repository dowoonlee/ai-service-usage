import Foundation

/// 머지된 PR 기여자 목록을 GitHub `/pulls` 비인증 API로 fetch.
/// repo가 public이라 token 없이 60req/h 가능 — 24h 캐시로 사실상 사용자당 1회 호출.
/// `ContributorBonus`와 별개: 그쪽은 자기 토큰으로 자기 PR 검색 → 코인 적립이 목적이고,
/// 이쪽은 unauthenticated로 모든 머지된 PR의 author를 모음 → UI 표시가 목적.
@MainActor
final class Contributors: ObservableObject {
    static let shared = Contributors()

    @Published private(set) var list: [Contributor] = []

    private static let repo = "dowoonlee/ai-service-usage"
    /// repo owner는 외부 기여자가 아니므로 표시 대상에서 제외.
    private static let ownerLogin = "dowoonlee"
    /// Sparkle 자동 업데이트 체크와 동일한 24h 주기 — rate limit 부담 0.
    private static let cacheTTL: TimeInterval = 24 * 3600
    private static let cacheKey = "contributors.cache.v1"

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
        var comps = URLComponents(string: "https://api.github.com/repos/\(Self.repo)/pulls")!
        comps.queryItems = [
            .init(name: "state", value: "closed"),
            .init(name: "per_page", value: "100"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "Contributors", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub API \(http.statusCode)"])
        }
        struct PRResp: Decodable {
            struct User: Decodable { let login: String; let avatar_url: String? }
            let number: Int
            let title: String
            let merged_at: String?
            let user: User?
        }
        let prs = try JSONDecoder().decode([PRResp].self, from: data)
        return Self.aggregate(prs: prs.map {
            (number: $0.number, title: $0.title, mergedAt: $0.merged_at, login: $0.user?.login, avatar: $0.user?.avatar_url)
        }, ownerLogin: Self.ownerLogin)
    }

    /// 순수 함수 — login 별로 머지된 PR을 그룹화, 가장 최근 머지 시각 기준 정렬.
    /// (number/title/mergedAt 문자열/login/avatar_url) 튜플 입력으로 받아 외부 의존 없음 → 테스트 가능.
    nonisolated static func aggregate(
        prs: [(number: Int, title: String, mergedAt: String?, login: String?, avatar: String?)],
        ownerLogin: String
    ) -> [Contributor] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var bucket: [String: (avatarURL: String?, prs: [PullRequest])] = [:]
        for pr in prs {
            guard let login = pr.login, login != ownerLogin,
                  let mergedAtStr = pr.mergedAt,
                  let mergedAt = iso.date(from: mergedAtStr) ?? isoNoFrac.date(from: mergedAtStr)
            else { continue }
            var entry = bucket[login] ?? (avatarURL: pr.avatar, prs: [])
            entry.prs.append(PullRequest(number: pr.number, title: pr.title, mergedAt: mergedAt))
            if entry.avatarURL == nil { entry.avatarURL = pr.avatar }
            bucket[login] = entry
        }
        return bucket
            .map { (login, v) in
                Contributor(login: login, avatarURL: v.avatarURL,
                            prs: v.prs.sorted { $0.mergedAt > $1.mergedAt })
            }
            .sorted { lhs, rhs in
                // 1차: PR 개수 내림차순 → 많이 기여한 사람이 위.
                if lhs.prs.count != rhs.prs.count { return lhs.prs.count > rhs.prs.count }
                // 2차: 동점이면 최근 머지가 위.
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
