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

    static func draw(vm: ViewModel) {
        let (_, cols) = Terminal.size()
        Terminal.clear()
        let now = Date()

        // Header
        let header = " AIUsage TUI · \(timeFmt.string(from: now))"
        Terminal.write("\u{1B}[1m\(header)\u{1B}[0m\r\n")
        Terminal.write(String(repeating: "─", count: cols) + "\r\n\r\n")

        drawClaude(vm: vm, cols: cols, now: now)
        Terminal.write("\r\n")
        drawCursor(vm: vm, cols: cols, now: now)
        Terminal.write("\r\n\r\n")

        // Footer
        let auto = vm.claudeLoading || vm.cursorLoading ? "갱신 중…" : "5분마다 자동"
        Terminal.write(" \u{1B}[2m[q] 종료   [r] 즉시 갱신   (\(auto))\u{1B}[0m\r\n")
    }

    private static func drawClaude(vm: ViewModel, cols: Int, now: Date) {
        Terminal.write(" \u{1B}[1mClaude\u{1B}[0m")
        if let plan = vm.claudeCurrent?.planName {
            Terminal.write("  \u{1B}[2m\(plan)\u{1B}[0m")
        }
        Terminal.write("\r\n")

        if vm.claudeNeedsLogin {
            Terminal.write("   \u{1B}[33m로그인 필요 — GUI 앱에서 먼저 로그인하세요.\u{1B}[0m\r\n")
            return
        }
        guard let snap = vm.claudeCurrent else {
            Terminal.write("   \u{1B}[2m로딩 중…\u{1B}[0m\r\n")
            return
        }

        // 5h: sparkline + 값. GUI 와 동일하게 sparkline 은 5h 만 그리고
        // 주간은 숫자만 표시.
        if let pct = snap.fiveHourPct {
            let history = vm.claudeHistory.compactMap { $0.fiveHourPct }
            drawMetricLine(label: "5h", spark: history, value: "\(Int(pct.rounded()))%", cols: cols)
        }
        if let pct = snap.sevenDayPct {
            Terminal.write("   주간      \(Int(pct.rounded()))%\r\n")
        }
        if let resetAt = snap.fiveHourResetAt {
            let r = formatRemaining(from: now, to: resetAt)
            Terminal.write("   \u{1B}[2m5h reset   \(r)\u{1B}[0m\r\n")
        }
    }

    private static func drawCursor(vm: ViewModel, cols: Int, now: Date) {
        Terminal.write(" \u{1B}[1mCursor\u{1B}[0m")
        if let plan = vm.cursorCurrent?.planName {
            Terminal.write("  \u{1B}[2m\(plan)\u{1B}[0m")
        }
        Terminal.write("\r\n")

        if vm.cursorNeedsSetup {
            Terminal.write("   \u{1B}[33mCursor 앱이 설치/로그인되어 있지 않습니다.\u{1B}[0m\r\n")
            return
        }
        guard let snap = vm.cursorCurrent else {
            Terminal.write("   \u{1B}[2m로딩 중…\u{1B}[0m\r\n")
            return
        }

        // Ultra: 누적 cents, Pro: 요청 수
        if let total = snap.totalCents, let max = snap.maxCents, max > 0 {
            let history = vm.cursorHistory.compactMap { $0.totalCents }
            let value = "$\(Int((total / 100).rounded())) / $\(Int((max / 100).rounded()))  (\(String(format: "%.1f", total / max * 100))%)"
            drawMetricLine(label: "$", spark: history, value: value, cols: cols)
        } else if let req = snap.totalRequests, let max = snap.maxRequests, max > 0 {
            let history = vm.cursorHistory.compactMap { $0.totalRequests.map(Double.init) }
            let value = "\(req) / \(max)  (\(String(format: "%.1f", Double(req) / Double(max) * 100))%)"
            drawMetricLine(label: "req", spark: history, value: value, cols: cols)
        }
        if let resetAt = snap.resetAt {
            Terminal.write("   \u{1B}[2mreset      \(dateFmt.string(from: resetAt))\u{1B}[0m\r\n")
        }
    }

    /// "   <label>   <sparkline>   <value>" 형태로 한 줄 출력.
    private static func drawMetricLine(label: String, spark: [Double], value: String, cols: Int) {
        let leftPad = "   "
        let labelW = 8  // label 영역 폭
        let valuePad = "  "
        let labelStr = label.padding(toLength: labelW, withPad: " ", startingAt: 0)
        let used = leftPad.count + labelW + valuePad.count + value.count
        let sparkW = max(8, cols - used - 4)
        let line = leftPad + labelStr + Sparkline.render(values: spark, width: sparkW) + valuePad + value
        Terminal.write(line + "\r\n")
    }

    private static func formatRemaining(from now: Date, to target: Date) -> String {
        let secs = Int(target.timeIntervalSince(now))
        if secs <= 0 { return "지남" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }
}
