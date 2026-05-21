import Foundation

/// 크래시 회수 — in-process signal handler 없이 macOS가 자동 생성한 `.ips`만 활용.
///
/// 흐름:
///  1. 시작 시 `handleLaunch()` — 직전 실행이 비정상 종료였고 신규 `.ips`가 발견되면 `CrashRecord` 반환.
///  2. AppDelegate가 다이얼로그를 띄우고 `markReported(_:)` 로 같은 `.ips`를 재안내하지 않도록 마킹.
///  3. 정상 종료 경로 (`applicationWillTerminate`)에서 `markCleanShutdown()` — kill -9/크래시 시엔 호출 안 됨.
///
/// 핸들러를 in-process로 설치하지 않는 이유: signal handler 안에서 async-signal-safe 가 아닌 코드를
/// 실행하면 secondary crash 위험. OS의 `.ips` 본문에 이미 stack trace + thread state가 다 들어있어서
/// 충분히 actionable.
struct CrashRecord {
    let ipsPath: URL
    let crashedAt: Date
    let signalSummary: String   // "Exception Type: EXC_BAD_ACCESS (SIGSEGV)" 같은 한 줄
    let bodyExcerpt: String     // .ips 첫 ~80줄. URL query에 안전한 크기로 cap.
}

@MainActor
enum CrashReporter {
    private static let cleanShutdownKey = "crash.cleanShutdown"
    private static let lastLaunchAtKey  = "crash.lastLaunchAt"
    private static let reportedIPSKey   = "crash.reportedIPS"

    /// `.ips` 파싱 시 읽을 최대 바이트. 거대한 파일에서 메모리 폭주 방지.
    private static let ipsReadCap = 60 * 1024
    /// bodyExcerpt 최대 라인 수.
    private static let bodyMaxLines = 80
    /// bodyExcerpt 최대 문자 수. URL query 한계(BugReport.maxBodyLength=6000) 안에서 여유.
    private static let bodyMaxChars = 4500

    /// 시작 시 1회 호출. 직전 실행이 비정상 종료였고 회수할 `.ips`가 있으면 반환.
    /// 호출 직후 키들을 다음 사이클을 위해 갱신.
    static func handleLaunch() -> CrashRecord? {
        let d = UserDefaults.standard
        let now = Date()

        // 첫 실행 감지 — lastLaunchAt 키가 없으면 fresh install. 비정상 종료로 오인 금지.
        let isFreshInstall = d.object(forKey: lastLaunchAtKey) == nil
        let lastLaunch = d.object(forKey: lastLaunchAtKey) as? Double
        let cleanShutdown = d.bool(forKey: cleanShutdownKey)

        // 이번 launch 기록은 항상 갱신.
        d.set(now.timeIntervalSince1970, forKey: lastLaunchAtKey)
        d.set(false, forKey: cleanShutdownKey)

        guard !isFreshInstall, !cleanShutdown else { return nil }

        // DiagnosticReports 폴더 스캔.
        let cutoff = lastLaunch.map { Date(timeIntervalSince1970: $0) }
        guard let ips = findRecentIPS(after: cutoff) else { return nil }

        return parse(ipsPath: ips)
    }

    /// `applicationWillTerminate` 에서 호출 — 정상 종료 마킹.
    /// `synchronize()` 는 deprecated 이지만 종료 직전 동기 flush 보장이 필요해서 의도적으로 호출.
    static func markCleanShutdown() {
        let d = UserDefaults.standard
        d.set(true, forKey: cleanShutdownKey)
        d.synchronize()
    }

    /// 사용자에게 한 번 안내한 `.ips` 는 다시 안 보이도록 등록. "무시하기" 눌러도 호출.
    static func markReported(_ ipsPath: URL) {
        let d = UserDefaults.standard
        var list = d.stringArray(forKey: reportedIPSKey) ?? []
        let name = ipsPath.lastPathComponent
        if !list.contains(name) {
            list.append(name)
            // 최근 20개만 유지 — 폴더 자체도 macOS가 알아서 회전하므로 그 이상 둘 필요 없음.
            if list.count > 20 { list = Array(list.suffix(20)) }
            d.set(list, forKey: reportedIPSKey)
        }
    }

    // MARK: - private

    private static func findRecentIPS(after cutoff: Date?) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let reported = Set(UserDefaults.standard.stringArray(forKey: reportedIPSKey) ?? [])

        // `AIUsage-2026-...ips` 패턴 매칭. 번들 ID prefix가 아니라 실행파일명 (CFBundleExecutable) prefix가
        // OS 컨벤션 — package.sh 가 SwiftPM 산출물(ClaudeUsage)을 `AIUsage` 로 rename 해서 넣음.
        let candidates: [(URL, Date)] = entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("AIUsage-"), name.hasSuffix(".ips") else { return nil }
            guard !reported.contains(name) else { return nil }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if let cutoff = cutoff, mtime < cutoff { return nil }
            return (url, mtime)
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private static func parse(ipsPath: URL) -> CrashRecord? {
        guard let handle = try? FileHandle(forReadingFrom: ipsPath) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: ipsReadCap)) ?? Data()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        let mtime = (try? ipsPath.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? Date()

        let lines = text.components(separatedBy: "\n")
        let body = lines.dropFirst()

        var excerpt = body.prefix(bodyMaxLines).joined(separator: "\n")
        if excerpt.count > bodyMaxChars {
            excerpt = String(excerpt.prefix(bodyMaxChars)) + "\n…(truncated)"
        }

        return CrashRecord(
            ipsPath: ipsPath,
            crashedAt: mtime,
            signalSummary: extractSignalSummary(text),
            bodyExcerpt: excerpt
        )
    }

    /// `.ips` 에서 사람이 읽을 수 있는 한 줄 요약 — "EXC_BAD_ACCESS (SIGSEGV)" 같은 형태.
    ///
    /// macOS 11+ 의 `.ips` 는 첫 줄 한 줄짜리 JSON metadata + 둘째 줄부터 multi-line JSON body.
    /// metadata 와 body 양쪽에 `"type": "EXC_..."` / `"signal": "SIG..."` 가 들어있으므로
    /// 정규식으로 직접 뽑는다. 옛 텍스트 포맷 호환 위해 `Exception Type:` 라인도 fallback.
    private static func extractSignalSummary(_ text: String) -> String {
        var parts: [String] = []
        if let exc = firstCapture(text, pattern: #""type"\s*:\s*"(EXC_[A-Z_]+)""#) {
            parts.append(exc)
        }
        if let sig = firstCapture(text, pattern: #""signal"\s*:\s*"(SIG[A-Z]+)""#) {
            parts.append("(\(sig))")
        }
        if !parts.isEmpty { return parts.joined(separator: " ") }

        // 옛 텍스트 포맷 (macOS 10.x 시절): "Exception Type: EXC_BAD_ACCESS (SIGSEGV)"
        if let line = text.split(separator: "\n").first(where: { $0.contains("Exception Type:") }) {
            return String(line.prefix(200))
        }
        // 마지막 fallback — bug_type 코드 (309 = exc_crash 등). actionable 하진 않지만 빈 줄 보단 낫다.
        if let bug = firstCapture(text, pattern: #""bug_type"\s*:\s*"([0-9]+)""#) {
            return "Bug Type \(bug)"
        }
        return "(crash type unknown)"
    }

    private static func firstCapture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
