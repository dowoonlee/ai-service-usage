import Foundation

// 연결된 GitHub 사용자가 머지한 PR을 찾아 코인 보너스를 적립.
//
// 정책:
//   - PR 1개 = 50 coin (CoinLedger.coinPerContributorPR)
//   - dedupe: Settings.creditedPRNumbers (Set<Int>)에 PR 번호 저장 → 한 번 적립된 PR은 영구 제외
//   - 소급: 처음 연결 시 과거 머지된 모든 PR이 한꺼번에 적립됨
//   - 자기 자신(repo owner)도 포함 — 외부 기여자만 분리하지 않음 (사용자 결정 v0.4.0)
@MainActor
final class ContributorBonus {
    static let shared = ContributorBonus()
    private init() {}

    /// 검색 대상 repo. 변경 시 빌드별로 갈라낼 수 있도록 상수 유지.
    private static let repo = "dowoonlee/ai-service-usage"

    /// 동시 sync 폭주 방지용 게이트.
    private var syncing = false

    /// GitHub 토큰 메모리 캐시. 폴링마다 keychain을 다시 치면 ad-hoc 서명 환경에서
    /// 업데이트 후 ACL이 깨졌을 때 사용자에게 keychain 접근 다이얼로그가 반복적으로
    /// 노출됨 — 캐시로 프로세스 수명 동안 1회 접근으로 줄임.
    /// `String??` 사용: nil = 미초기화(아직 keychain 미접근), .some(nil) = 토큰 없음 캐시됨.
    /// 단순 `String?`이면 토큰 없는 사용자는 if-let에 매번 빠져서 keychain을 반복 호출함.
    private var cachedToken: String??

    /// 외부에서 토큰을 저장/삭제할 때 호출 — `SettingsView`의 연결 성공 직후,
    /// `Settings.disconnectGitHub()`의 토큰 폐기 직후.
    func updateToken(_ token: String?) {
        cachedToken = .some(token)
    }

    private func currentToken() -> String? {
        if let cached = cachedToken { return cached }
        let t = Keychain.loadGitHubToken()
        cachedToken = .some(t)
        return t
    }

    /// 토큰 + login이 있을 때만 동작. 호출은 폴링 루프 / 연결 직후 / 앱 시작 시.
    /// 내부에서 모든 예외를 흡수 — 네트워크/토큰 만료 시 조용히 실패.
    func sync() async {
        guard GitHubAuth.isConfigured,
              let token = currentToken(),
              let login = Settings.shared.githubLogin else { return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }

        do {
            let prs = try await fetchMergedPRs(login: login, token: token)
            let already = Settings.shared.creditedPRNumbers
            let newPRs = prs.filter { !already.contains($0.number) }
            guard !newPRs.isEmpty else { return }

            for pr in newPRs {
                Settings.shared.creditedPRNumbers.insert(pr.number)
            }
            CoinLedger.shared.creditContributorBonus(prCount: newPRs.count)

            let total = newPRs.count * CoinLedger.coinPerContributorPR
            let prList = newPRs.map { "#\($0.number)" }.joined(separator: ", ")
            DebugLog.log("ContributorBonus: +\(total) coin for \(newPRs.count) PR (\(prList)) — login=\(login)")
            NotificationManager.shared.contributorBonus(prCount: newPRs.count, totalCoins: total, prList: prList)
        } catch {
            DebugLog.log("ContributorBonus.sync failed: \(error.localizedDescription)")
        }
    }

    struct PR { let number: Int; let title: String }

    /// GitHub Search API로 author=login이고 머지된 PR 조회.
    /// per_page=100 이라 100개 미만이면 1페이지로 끝. 100개 이상은 (현실적으로 거의 없음) 페이지네이션 필요.
    private func fetchMergedPRs(login: String, token: String) async throws -> [PR] {
        let q = "author:\(login) repo:\(Self.repo) is:pr is:merged"
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "ContributorBonus", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub API \(http.statusCode)"])
        }
        struct Resp: Decodable {
            struct Item: Decodable { let number: Int; let title: String }
            let items: [Item]
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        return r.items.map { PR(number: $0.number, title: $0.title) }
    }
}
