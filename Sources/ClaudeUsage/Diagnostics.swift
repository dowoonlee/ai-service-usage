import Foundation

// `--check [--raw]` 로컬 진단 출력. 배포 GUI/TUI 와 무관한 CLI 전용 경로.
//
// claude.ai·cursor.com 둘 다 비공식 엔드포인트라, 응답 스키마가 조용히 바뀌면 앱이 틀린 값을
// 에러 없이 멀쩡히 표시할 수 있다 (예: Cursor가 numRequests 키 이름을 바꾸면 합계 0인데 200 OK).
// 그래서 이 진단은 두 층위로 점검한다:
//   1) 기계적 정합성 — status·디코드 성공 여부, "200인데 모든 사용률 nil" 같은 스키마 드리프트 신호
//   2) --raw 원본 덤프 — 사람/Claude 가 claude.ai / cursor.com 대시보드 숫자와 직접 대조
// 원본 응답엔 org uuid·모델별 cost 가 들어있으므로 로컬 stdout 한정. BugReport 경로엔 절대 안 흘린다.

enum DiagSeverity: Int, Comparable { case ok = 0, warn = 1, fail = 2
    static func < (lhs: DiagSeverity, rhs: DiagSeverity) -> Bool { lhs.rawValue < rhs.rawValue }
    var icon: String { switch self { case .ok: return "✅"; case .warn: return "⚠️"; case .fail: return "❌" } }
    var text: String { switch self { case .ok: return "정상"; case .warn: return "확인 필요"; case .fail: return "이상" } }
}

enum DiagnosticsCLI {
    static func run(raw: Bool) async {
        print("═══════════════════════════════════════════")
        print(" AIUsage 사용량 진단" + (raw ? " (raw)" : ""))
        print("═══════════════════════════════════════════")

        let c = await UsageAPI.shared.diagnose()
        let (cSev, cLines) = evaluateClaude(c)
        printBlock(title: "Claude (claude.ai)", sev: cSev, lines: cLines)
        if raw {
            printRaw("organizations", c.orgRawData)
            printRaw("usage", c.usageRawData)
        }

        let cu = await CursorAPI.shared.diagnose()
        let (cuSev, cuLines) = evaluateCursor(cu)
        printBlock(title: "Cursor (cursor.com)", sev: cuSev, lines: cuLines)
        if raw {
            printRaw("usage", cu.usageRawData)
            if cu.plan == .ultra { printRaw("aggregated-usage-events", cu.aggRawData) }
        }

        let overall = max(cSev, cuSev)
        print("\n═══════════════════════════════════════════")
        print(" 종합: \(overall.icon) \(overall.text)   (Claude \(cSev.icon) / Cursor \(cuSev.icon))")
        print("═══════════════════════════════════════════")

        exit(overall == .fail ? 1 : 0)
    }

    // MARK: - Claude 판정

    private static func evaluateClaude(_ d: ClaudeDiagnostics) -> (DiagSeverity, [String]) {
        var lines: [String] = []
        var sev: DiagSeverity = .ok
        func bump(_ s: DiagSeverity) { sev = max(sev, s) }

        guard d.loggedIn else {
            return (.fail, ["인증: ❌ \(d.fatal ?? "로그인 안 됨")"])
        }
        lines.append("인증: ✅ Keychain sessionKey 존재")

        let os = d.orgStatus ?? -1
        lines.append("GET /api/organizations: \(statusText(os))")
        if os != 200 { bump(.fail) }

        if let id = d.orgID {
            lines.append("조직 ID: \(id.prefix(8))… (파싱 OK)")
        } else {
            lines.append("조직 ID: ❌ 파싱 실패")
            bump(.fail)
        }
        lines.append("플랜: \(d.planName ?? "❓ 미확인")")
        if d.planName == nil || d.planName == "?" { bump(.warn) }

        if let fatal = d.fatal {
            lines.append("중단: \(fatal)")
            return (max(sev, .fail), lines)
        }

        let us = d.usageStatus ?? -1
        lines.append("GET …/usage: \(statusText(us))")
        if us != 200 { bump(.fail) }

        if let snap = d.snapshot {
            lines.append("파싱: ✅")
            lines.append("  5h 사용률: \(pct(snap.fiveHourPct))  (리셋 \(dateText(snap.fiveHourResetAt)))")
            lines.append("  7d 사용률: \(pct(snap.sevenDayPct))  (리셋 \(dateText(snap.sevenDayResetAt)))")
            if snap.extraUsageEnabled == true {
                lines.append("  추가 사용: 활성 \(pct(snap.extraUsageUtilPct))")
            } else {
                lines.append("  추가 사용: 비활성")
            }
            // 200인데 5h·7d 둘 다 nil → 응답 스키마가 바뀌었을 가능성 (실제 미사용이면 0.0 이 와야 정상)
            if us == 200, snap.fiveHourPct == nil, snap.sevenDayPct == nil {
                lines.append("  ⚠️ 5h·7d 사용률이 둘 다 nil — 스키마 변경 의심 (--raw로 원본 키 확인)")
                bump(.warn)
            }
        } else {
            lines.append("파싱: ❌ usage 응답 디코드 실패 (--raw로 원본 확인)")
            bump(.fail)
        }
        return (sev, lines)
    }

    // MARK: - Cursor 판정

    private static func evaluateCursor(_ d: CursorDiagnostics) -> (DiagSeverity, [String]) {
        var lines: [String] = []
        var sev: DiagSeverity = .ok
        func bump(_ s: DiagSeverity) { sev = max(sev, s) }

        guard d.dbExists else { return (.fail, ["DB: ❌ \(d.fatal ?? "state.vscdb 없음")"]) }
        lines.append("DB: ✅ state.vscdb 존재")
        guard d.tokenFound else { return (.fail, lines + ["토큰: ❌ \(d.fatal ?? "accessToken 없음")"]) }
        lines.append("토큰: ✅ JWT 발견")
        guard d.userIdOK else { return (.fail, lines + ["JWT: ❌ \(d.fatal ?? "디코드 실패")"]) }
        lines.append("플랜: \(d.planName ?? "❓") (\(d.plan.rawValue))")
        if d.plan == .unknown { bump(.warn) }

        let us = d.usageStatus ?? -1
        lines.append("GET /api/usage: \(statusText(us))")
        if us != 200 { bump(.fail) }

        guard let snap = d.snapshot else {
            lines.append("파싱: ❌ usage 응답 디코드 실패 (--raw로 원본 확인)")
            return (max(sev, .fail), lines)
        }
        lines.append("파싱: ✅")

        if d.plan == .ultra {
            lines.append("  누적: \(centsText(snap.totalCents)) / \(centsText(snap.maxCents))")
            let ags = d.aggStatus ?? -1
            lines.append("  POST aggregated-usage-events: \(statusText(ags))")
            if ags != 200 { bump(.fail) }
            if ags == 200, (snap.totalCents ?? 0) == 0 {
                lines.append("  ⚠️ 누적 cents=0 — 실제 미사용이거나 스키마 변경 (--raw로 확인)")
                bump(.warn)
            }
        } else {
            let total = snap.totalRequests ?? 0
            let maxr = snap.maxRequests
            lines.append("  요청 수: \(total)\(maxr.map { " / \($0)" } ?? "")")
            lines.append("  리셋: \(dateText(snap.resetAt))")
            // 200인데 요청 수 0 + 한도 nil → 동적 모델 키 파싱이 깨졌을 가능성
            if us == 200, total == 0, maxr == nil {
                lines.append("  ⚠️ 요청 수·한도 모두 비어있음 — 스키마 변경 의심 (--raw로 확인)")
                bump(.warn)
            }
        }
        return (sev, lines)
    }

    // MARK: - 출력 helper

    private static func printBlock(title: String, sev: DiagSeverity, lines: [String]) {
        print("\n┌─ \(title)")
        for l in lines { print("│ \(l)") }
        print("│ 판정: \(sev.icon) \(sev.text)")
        print("└─")
    }

    private static func printRaw(_ label: String, _ data: Data?) {
        print("\n  ── raw: \(label) ──")
        guard let data else { print("  (응답 없음)"); return }
        print(prettyJSON(data))
    }

    private static func prettyJSON(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "(JSON 아님, \(data.count) bytes)"
        }
        return s
    }

    private static func statusText(_ s: Int) -> String {
        switch s {
        case 200: return "200 ✅"
        case -1: return "요청 실패 ❌ (네트워크/타임아웃)"
        case 401, 403: return "\(s) ❌ 인증 만료"
        default: return "\(s) ❌"
        }
    }

    private static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0) } ?? "nil ⚠️" }
    private static func centsText(_ v: Double?) -> String { v.map { String(format: "$%.2f", $0 / 100) } ?? "—" }

    private static func dateText(_ d: Date?) -> String {
        guard let d else { return "—" }
        return ISO8601DateFormatter().string(from: d)
    }
}
