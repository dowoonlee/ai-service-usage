import Foundation
import Combine
import Darwin

// htop 스타일의 터미널 dashboard. `swift run ClaudeUsage --tui` 또는
// `/Applications/AIUsage.app/Contents/MacOS/ClaudeUsage --tui` 로 실행.
// 인증은 GUI와 동일 — Claude 는 Keychain 의 sessionKey, Cursor 는 로컬 SQLite JWT.
// 따라서 Claude 처음 사용자는 GUI 앱에서 한 번 로그인 후에 TUI 사용 가능.

@MainActor
enum TUIApp {
    static func run() {
        Terminal.enterRawMode()
        Terminal.enterAlternateBuffer()
        Terminal.hideCursor()

        // Ctrl-C / 종료 시 터미널 상태 복원.
        signal(SIGINT)  { _ in TUIApp.shutdown() }
        signal(SIGTERM) { _ in TUIApp.shutdown() }
        atexit { Terminal.cleanup() }

        let vm = ViewModel()
        vm.startPolling(interval: 300)

        // 1초마다 다시 그림 (countdown 등 라이브 표시 위해).
        let renderTimer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { Renderer.draw(vm: vm) }
        }
        RunLoop.main.add(renderTimer, forMode: .common)
        Renderer.draw(vm: vm)

        // stdin 읽기 — DispatchSource 가 main queue 에 이벤트 보내준다.
        let src = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
        src.setEventHandler {
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) == 1 {
                MainActor.assumeIsolated { handleKey(byte, vm: vm) }
            }
        }
        src.resume()

        RunLoop.main.run() // blocks
    }

    private static func handleKey(_ byte: UInt8, vm: ViewModel) {
        switch byte {
        case 0x71, 0x51, 0x03: // q, Q, Ctrl-C
            shutdown()
        case 0x72, 0x52: // r, R
            Task { @MainActor in
                await vm.refreshClaude()
                await vm.refreshCursor()
            }
        default:
            break
        }
    }

    private nonisolated static func shutdown() {
        Terminal.cleanup()
        exit(0)
    }
}

// MARK: - Terminal helpers

enum Terminal {
    private nonisolated(unsafe) static var savedTermios = termios()

    static func enterRawMode() {
        tcgetattr(STDIN_FILENO, &savedTermios)
        var raw = savedTermios
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    nonisolated static func cleanup() {
        write("\u{1B}[?1049l")  // 대체 buffer 종료
        write("\u{1B}[?25h")    // cursor 다시 보이기
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
    }

    static func enterAlternateBuffer() { write("\u{1B}[?1049h") }
    static func hideCursor()           { write("\u{1B}[?25l") }
    static func clear()                { write("\u{1B}[2J\u{1B}[H") }
    static func moveTo(row: Int, col: Int) { write("\u{1B}[\(row);\(col)H") }

    nonisolated static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    /// 현재 터미널 (rows, cols). 못 가져오면 80x24 기본.
    static func size() -> (rows: Int, cols: Int) {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return (Int(w.ws_row), Int(w.ws_col))
        }
        return (24, 80)
    }
}

// (별도 visualization helper 없음 — Renderer 가 직접 tile 행 그림)

// MARK: - Renderer

@MainActor
enum Renderer {
    // ANSI 색/스타일 상수.
    private static let RST   = "\u{1B}[0m"
    private static let DIM   = "\u{1B}[2m"
    private static let BOLD  = "\u{1B}[1m"
    private static let CYAN  = "\u{1B}[36m"
    private static let MAG   = "\u{1B}[35m"
    private static let GREEN = "\u{1B}[32m"
    private static let YELL  = "\u{1B}[33m"
    private static let RED   = "\u{1B}[31m"

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// GUI 의 `SectionFormat.continuousColor` 와 동일 — HSV 에서 hue 만 0.33(green)
    /// 에서 0.0(red) 으로 선형 보간, saturation 0.75, brightness 0.9. 24-bit truecolor
    /// ANSI escape 로 출력. 0% = 초록, 50% = 노랑, 100% = 빨강.
    private static func levelColor(_ pct: Double) -> String {
        let clamped = max(0, min(100, pct)) / 100
        let hue = 0.33 * (1 - clamped)
        let (r, g, b) = hsvToRGB(h: hue, s: 0.75, v: 0.9)
        return "\u{1B}[38;2;\(r);\(g);\(b)m"
    }

    /// HSV(0..1, 0..1, 0..1) → RGB(0..255, 0..255, 0..255).
    private static func hsvToRGB(h: Double, s: Double, v: Double) -> (Int, Int, Int) {
        let h6 = h * 6
        let c = v * s
        let x = c * (1 - abs(h6.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h6 {
        case ..<1:    (r1, g1, b1) = (c, x, 0)
        case ..<2:    (r1, g1, b1) = (x, c, 0)
        case ..<3:    (r1, g1, b1) = (0, c, x)
        case ..<4:    (r1, g1, b1) = (0, x, c)
        case ..<5:    (r1, g1, b1) = (x, 0, c)
        default:      (r1, g1, b1) = (c, 0, x)
        }
        return (
            Int(((r1 + m) * 255).rounded()),
            Int(((g1 + m) * 255).rounded()),
            Int(((b1 + m) * 255).rounded())
        )
    }

    static func draw(vm: ViewModel) {
        let (_, cols) = Terminal.size()
        Terminal.clear()
        let now = Date()

        // Header — 가운데에 시각, 양옆을 ─ 로 채워서 박스처럼.
        let title = " AIUsage TUI "
        let timeStr = " \(timeFmt.string(from: now)) "
        let pad = max(0, cols - title.count - timeStr.count - 2)
        let leftPad = pad / 2
        let rightPad = pad - leftPad
        let line = "\(CYAN)╭\(String(repeating: "─", count: leftPad))\(BOLD)\(title)\(RST)\(CYAN)\(String(repeating: "─", count: rightPad))\(DIM)\(timeStr)\(RST)\(CYAN)╮\(RST)"
        Terminal.write(line + "\r\n\r\n")

        drawClaude(vm: vm, cols: cols, now: now)
        Terminal.write("\r\n")
        drawCursor(vm: vm, cols: cols, now: now)
        Terminal.write("\r\n")

        // Footer
        let auto = vm.claudeLoading || vm.cursorLoading ? "갱신 중…" : "5분마다 자동"
        Terminal.write("\r\n \(DIM)[q]\(RST)\(DIM) 종료  ·  \(RST)\(DIM)[r]\(RST)\(DIM) 즉시 갱신  ·  (\(auto))\(RST)\r\n")
        Terminal.write("\(CYAN)╰\(String(repeating: "─", count: max(0, cols - 2)))╯\(RST)\r\n")
    }

    /// 한 metric row 의 입력. history 가 있으면 시간축 tile 행을 그리고,
    /// nil 이면 시각화 자리는 비워두고 pct 만 표시.
    private struct MetricRow {
        let label: String
        let history: [Double]?  // 각 원소는 0..100 의 % 값 (timestep 별 사용량)
        let pct: Double
        let suffix: String
    }

    private static func drawClaude(vm: ViewModel, cols: Int, now: Date) {
        Terminal.write(" \(CYAN)●\(RST)  \(BOLD)Claude\(RST)")
        if let plan = vm.claudeCurrent?.planName {
            Terminal.write("  \(DIM)\(plan)\(RST)")
        }
        Terminal.write("\r\n")

        if vm.claudeNeedsLogin {
            Terminal.write("    \(YELL)로그인 필요 — GUI 앱에서 먼저 로그인하세요.\(RST)\r\n")
            return
        }
        guard let snap = vm.claudeCurrent else {
            Terminal.write("    \(DIM)로딩 중…\(RST)\r\n")
            return
        }

        var rows: [MetricRow] = []
        if let pct = snap.fiveHourPct {
            let history = vm.claudeHistory.compactMap { $0.fiveHourPct }
            let suffix = snap.fiveHourResetAt.map {
                "   \(DIM)reset \(formatRemaining(from: now, to: $0))\(RST)"
            } ?? ""
            rows.append(MetricRow(label: "5h", history: history, pct: pct, suffix: suffix))
        }
        if let pct = snap.sevenDayPct {
            rows.append(MetricRow(label: "주간", history: nil, pct: pct, suffix: ""))
        }
        drawSection(rows: rows, cols: cols)
    }

    private static func drawCursor(vm: ViewModel, cols: Int, now: Date) {
        Terminal.write(" \(MAG)●\(RST)  \(BOLD)Cursor\(RST)")
        if let plan = vm.cursorCurrent?.planName {
            Terminal.write("  \(DIM)\(plan)\(RST)")
        }
        Terminal.write("\r\n")

        if vm.cursorNeedsSetup {
            Terminal.write("    \(YELL)Cursor 앱이 설치/로그인되어 있지 않습니다.\(RST)\r\n")
            return
        }
        guard let snap = vm.cursorCurrent else {
            Terminal.write("    \(DIM)로딩 중…\(RST)\r\n")
            return
        }
        let resetSuffix = snap.resetAt.map {
            "   \(DIM)reset \(dateFmt.string(from: $0))\(RST)"
        } ?? ""

        var rows: [MetricRow] = []
        if let total = snap.totalCents, let max = snap.maxCents, max > 0 {
            // tile 행은 % 단위로 색을 결정 → cents history 도 % 로 변환.
            let history = vm.cursorHistory.compactMap { snap -> Double? in
                guard let c = snap.totalCents else { return nil }
                return c / max * 100
            }
            let pct = total / max * 100
            let detail = "  \(DIM)$\(Int((total / 100).rounded())) / $\(Int((max / 100).rounded()))\(RST)"
            rows.append(MetricRow(label: "$", history: history, pct: pct, suffix: detail + resetSuffix))
        } else if let req = snap.totalRequests, let max = snap.maxRequests, max > 0 {
            let history = vm.cursorHistory.compactMap { snap -> Double? in
                guard let r = snap.totalRequests else { return nil }
                return Double(r) / Double(max) * 100
            }
            let pct = Double(req) / Double(max) * 100
            let detail = "  \(DIM)\(req) / \(max)\(RST)"
            rows.append(MetricRow(label: "req", history: history, pct: pct, suffix: detail + resetSuffix))
        }
        drawSection(rows: rows, cols: cols)
    }

    /// 섹션의 모든 row 를 같은 tile 폭으로 그려서 % 위치를 column-정렬.
    /// tilesW 는 row 들 중 가장 긴 suffix 기준으로 산정 → 모든 row 의 % 가 같은 x.
    private static func drawSection(rows: [MetricRow], cols: Int) {
        guard !rows.isEmpty else { return }
        let leftPad = "    "
        let labelW = 6
        let pctVisible = 4   // "100%" 까지 4자
        let maxSuffixW = rows.map { stripAnsi($0.suffix).count }.max() ?? 0
        let used = leftPad.count + labelW + pctVisible + maxSuffixW + 4
        let tilesW = max(8, cols - used)
        for row in rows {
            drawMetric(row, leftPad: leftPad, labelW: labelW, tilesW: tilesW)
        }
    }

    private static func drawMetric(_ row: MetricRow, leftPad: String, labelW: Int, tilesW: Int) {
        // 한글(전각) 문자는 monospace 터미널에서 2 cols 폭이라 padding(toLength:) 가
        // UTF-16 길이로 세면 정렬이 어긋난다. display-width 기준으로 패딩.
        let labelStr = padDisplay(row.label, labelW)
        let pctText = padDisplay("\(Int(row.pct.rounded()))%", 4)
        let tilesPart: String = (row.history != nil)
            ? tileRow(values: row.history!, width: tilesW)
            : String(repeating: " ", count: tilesW)
        let pctPart = "\(BOLD)\(levelColor(row.pct))\(pctText)\(RST)"
        Terminal.write("\(leftPad)\(labelStr)\(tilesPart)  \(pctPart)\(row.suffix)\r\n")
    }

    /// 각 timestep 을 █ tile 한 칸으로 렌더하되, 색은 표출된 history 의
    /// min/max 를 0..100 범위에 매핑한 **상대 위치**로 결정.
    /// → 사용량이 60~80 사이에서만 변동하는 구간이면 60 = 초록, 80 = 빨강.
    /// 절대값이 아니라 그 시점의 트렌드를 보여줌.
    /// 데이터가 width 보다 적으면 좌측을 공백으로 패딩 (가장 최근이 우측).
    private static func tileRow(values: [Double], width: Int) -> String {
        guard width > 0 else { return "" }
        let recent = Array(values.suffix(width))
        let pad = max(0, width - recent.count)
        var out = String(repeating: " ", count: pad)
        let mn = recent.min() ?? 0
        let mx = recent.max() ?? 1
        let range = mx - mn
        // range 가 거의 0 이면 모두 거의 같은 값 → 중간 색(노랑)으로 통일.
        if range < 0.001 {
            for _ in recent { out += "\(levelColor(50))█\(RST)" }
            return out
        }
        for v in recent {
            let relative = (v - mn) / range * 100
            out += "\(levelColor(relative))█\(RST)"
        }
        return out
    }

    private static func formatRemaining(from now: Date, to target: Date) -> String {
        let secs = Int(target.timeIntervalSince(now))
        if secs <= 0 { return "지남" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    /// 한글/CJK 전각 문자는 2 cols 로 세는 display-width 측정.
    /// 충분히 일반적인 wide 범위만 다룬다 (Hangul 음절 + CJK Unified + 호환).
    private static func displayWidth(_ s: String) -> Int {
        var w = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if (0x1100...0x115F).contains(v) ||
                (0x2E80...0x303E).contains(v) ||
                (0x3041...0x33FF).contains(v) ||
                (0x3400...0x4DBF).contains(v) ||
                (0x4E00...0x9FFF).contains(v) ||
                (0xA000...0xA4CF).contains(v) ||
                (0xAC00...0xD7A3).contains(v) ||
                (0xF900...0xFAFF).contains(v) ||
                (0xFE30...0xFE4F).contains(v) ||
                (0xFF00...0xFF60).contains(v) ||
                (0xFFE0...0xFFE6).contains(v) {
                w += 2
            } else {
                w += 1
            }
        }
        return w
    }

    /// display-width 기준으로 우측 공백 패딩.
    private static func padDisplay(_ s: String, _ targetWidth: Int) -> String {
        let cur = displayWidth(s)
        if cur >= targetWidth { return s }
        return s + String(repeating: " ", count: targetWidth - cur)
    }

    /// ANSI escape 시퀀스를 제거한 문자열의 가시 길이 측정용.
    /// `\u{1B}[...m` 패턴을 모두 떼어낸다.
    private static func stripAnsi(_ s: String) -> String {
        var out = ""
        var iter = s.makeIterator()
        while let ch = iter.next() {
            if ch == "\u{1B}" {
                // [ 다음 문자 m 까지 스킵
                while let next = iter.next() {
                    if next == "m" { break }
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
