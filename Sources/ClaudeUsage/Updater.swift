import AppKit
import Sparkle

@MainActor
final class Updater: NSObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController

    override init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheck: Bool {
        controller.updater.canCheckForUpdates
    }

    // MARK: - 버전 정보 (메인 패널 버전 칩용)

    /// 현재 설치 버전 — `CFBundleShortVersionString`. `swift run` CLI 빌드는 Info.plist가 없어 nil.
    nonisolated static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// Sparkle feed(appcast.xml) URL — package.sh가 Info.plist에 박는 `SUFeedURL`. dev 빌드엔 없음.
    nonisolated static var feedURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else { return nil }
        return URL(string: s)
    }

    /// appcast.xml을 한 번 받아 가장 높은 `sparkle:shortVersionString`을 반환.
    /// 새 항목은 prepend 되지만 순서에 의존하지 않고 전체 중 semantic 최댓값을 취한다.
    /// 실패(네트워크/파싱/feed 없음)는 조용히 nil — 버전 칩은 부가 정보라 에러를 노출하지 않는다.
    nonisolated static func fetchLatestVersion() async -> String? {
        guard let feed = feedURL else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: feed)
            guard let xml = String(data: data, encoding: .utf8) else { return nil }
            let pattern = "<sparkle:shortVersionString>([^<]+)</sparkle:shortVersionString>"
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(xml.startIndex..., in: xml)
            let versions: [String] = regex.matches(in: xml, range: range).compactMap { m in
                guard let r = Range(m.range(at: 1), in: xml) else { return nil }
                return String(xml[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return versions.max(by: { compareVersions($0, $1) == .orderedAscending })
        } catch {
            return nil
        }
    }

    /// "0.13.10" vs "0.13.7" 같은 dotted numeric 버전을 자리별 정수로 비교.
    nonisolated static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// 설치 버전보다 feed의 최신 버전이 더 높으면 true.
    nonisolated static func isUpdateAvailable(current: String?, latest: String?) -> Bool {
        guard let current, let latest else { return false }
        return compareVersions(current, latest) == .orderedAscending
    }
}
