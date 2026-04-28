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

// MARK: - Sparkline

enum Sparkline {
    private static let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// 최대 width 길이의 sparkline 문자열. 값이 부족하면 앞쪽을 공백으로 패딩.
    static func render(values: [Double], width: Int) -> String {
        guard width > 0 else { return "" }
        guard !values.isEmpty else { return String(repeating: " ", count: width) }
        let recent = Array(values.suffix(width))
        let mn = recent.min() ?? 0
        let mx = recent.max() ?? 1
        let range = max(0.001, mx - mn)
        var out = ""
        out.reserveCapacity(width)
        let pad = max(0, width - recent.count)
        out.append(String(repeating: " ", count: pad))
        for v in recent {
            let idx = Int(((v - mn) / range) * Double(blocks.count - 1))
            out.append(blocks[max(0, min(blocks.count - 1, idx))])
        }
        return out
    }
}

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

    /// 사용량(%) 기준 색 — GUI 의 임계치 표시와 같은 traffic-light.
    private static func levelColor(_ pct: Double) -> String {
        if pct >= 80 { return RED }
        if pct >= 50 { return YELL }
        return GREEN
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

        if let pct = snap.fiveHourPct {
            let history = vm.claudeHistory.compactMap { $0.fiveHourPct }
            let suffix = snap.fiveHourResetAt.map {
                "   \(DIM)reset \(formatRemaining(from: now, to: $0))\(RST)"
            } ?? ""
            drawMetric(label: "5h", spark: history, pct: pct, suffix: suffix, cols: cols)
        }
        if let pct = snap.sevenDayPct {
            drawMetric(label: "주간", spark: nil, pct: pct, suffix: "", cols: cols)
        }
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

        if let total = snap.totalCents, let max = snap.maxCents, max > 0 {
            let history = vm.cursorHistory.compactMap { $0.totalCents }
            let pct = total / max * 100
            let detail = "  \(DIM)$\(Int((total / 100).rounded())) / $\(Int((max / 100).rounded()))\(RST)"
            drawMetric(label: "$", spark: history, pct: pct, suffix: detail + resetSuffix, cols: cols)
        } else if let req = snap.totalRequests, let max = snap.maxRequests, max > 0 {
            let history = vm.cursorHistory.compactMap { $0.totalRequests.map(Double.init) }
            let pct = Double(req) / Double(max) * 100
            let detail = "  \(DIM)\(req) / \(max)\(RST)"
            drawMetric(label: "req", spark: history, pct: pct, suffix: detail + resetSuffix, cols: cols)
        }
    }

    /// "    <label>  <sparkline>  <pct%>  <suffix>" 형태로 한 줄.
    /// spark = nil 이면 sparkline 자리 공백.
    private static func drawMetric(label: String, spark: [Double]?, pct: Double, suffix: String, cols: Int) {
        let leftPad = "    "
        let labelW = 6
        // 한글(전각) 문자는 monospace 터미널에서 2 cols 폭이라 padding(toLength:) 가
        // UTF-16 길이로 세면 정렬이 어긋난다. display-width 기준으로 패딩.
        let labelStr = padDisplay(label, labelW)
        let pctText = "\(Int(pct.rounded()))%"
        let pctVisible = pctText.count
        // sparkline 폭 = 전체 - 좌패딩 - 라벨 - pct - suffix 가시 길이 - 여백
        let suffixVisible = stripAnsi(suffix).count
        let used = leftPad.count + labelW + pctVisible + suffixVisible + 6
        let sparkW = max(8, cols - used)

        let sparkPart: String
        if let sp = spark {
            sparkPart = "\(DIM)\(CYAN)\(Sparkline.render(values: sp, width: sparkW))\(RST)"
        } else {
            sparkPart = String(repeating: " ", count: sparkW)
        }
        let pctPart = "\(BOLD)\(levelColor(pct))\(pctText)\(RST)"
        Terminal.write("\(leftPad)\(labelStr)\(sparkPart)  \(pctPart)\(suffix)\r\n")
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
