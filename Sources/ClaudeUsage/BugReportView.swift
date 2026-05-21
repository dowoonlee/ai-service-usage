import AppKit
import SwiftUI

// 버그 리포트 — 앱 안에서 본문 작성 후 GitHub Issues new URL로 브라우저 오픈.
// 스크린샷은 우리가 자동 업로드 안 함 (GitHub user-attachments 공식 API 없음 + 외부 호스팅 의존 회피).
// 대신 클립보드에 이미지가 있으면 사용자에게 안내해서 GitHub 페이지에서 직접 Cmd+V.

enum BugReport {
    static let repoOwner = "dowoonlee"
    static let repoName  = "ai-service-usage"

    /// GitHub URL query string은 사실상 ~8KB 한계 — 본문이 그 이상이면 일부 브라우저에서 잘림.
    /// 안전하게 6KB로 cap, 로그 첨부 시 마지막 100줄만 + 추가 길이 제한.
    static let maxBodyLength = 6000
    /// percent-encoded 후 바이트 한계. 한국어 한 글자가 9바이트로 폭증하므로 raw cap 만으로는 부족.
    /// base URL + title 인코딩 여유분 잡고 6500 (GitHub 안전 한계 ~8KB 안쪽).
    static let maxEncodedBodyBytes = 6500
    static let logTailLines  = 100
    static let logMaxLength  = 3000

    static func composeBody(
        description: String,
        includeAppVersion: Bool,
        includeOSVersion: Bool,
        includeLog: Bool,
        hasClipboardImage: Bool,
        crashSummary: CrashSummary? = nil
    ) -> String {
        var lines: [String] = []
        if hasClipboardImage {
            lines.append("<!-- 이 줄 위에 스크린샷을 Cmd+V로 붙여넣으세요 -->")
            lines.append("")
        }
        // 크래시 정보는 설명보다 위 — 이슈를 받는 사람이 가장 먼저 보게.
        if let crash = crashSummary {
            lines.append("## 크래시 정보")
            lines.append("- 시각: \(crash.crashedAtString)")
            lines.append("- \(crash.signalSummary)")
            lines.append("- 파일: `\(crash.ipsFileName)`")
            lines.append("")
            lines.append("<details><summary>크래시 리포트 발췌</summary>")
            lines.append("")
            lines.append("```")
            lines.append(crash.bodyExcerpt)
            lines.append("```")
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }
        lines.append("## 설명")
        lines.append(description.isEmpty ? "_(여기에 내용을 작성해주세요)_" : description)
        lines.append("")
        if includeAppVersion || includeOSVersion {
            lines.append("## 환경")
            if includeAppVersion {
                let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                lines.append("- 앱 버전: v\(v ?? "?")")
            }
            if includeOSVersion {
                lines.append("- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
            }
            lines.append("")
        }
        if includeLog, let tail = readLogTail() {
            lines.append("## 디버그 로그 (마지막 \(logTailLines)줄)")
            lines.append("```")
            lines.append(tail)
            lines.append("```")
        }
        return trimToLimits(lines.joined(separator: "\n"))
    }

    /// 본문을 raw 문자 한계 + percent-encoded 바이트 한계 둘 다로 cap.
    /// 한국어 비율이 높으면 raw 6000 자라도 encoded 15-20KB 가능 — GitHub 거부.
    private static func trimToLimits(_ s: String) -> String {
        let suffix = "\n\n_(본문이 길어 일부 잘렸습니다)_"
        func enc(_ x: String) -> Int {
            x.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?.count ?? x.count
        }
        if s.count <= maxBodyLength && enc(s) <= maxEncodedBodyBytes { return s }
        var trimmed = s.count > maxBodyLength
            ? String(s.prefix(maxBodyLength - suffix.count))
            : s
        let suffixEnc = enc(suffix)
        // 한 번에 200자씩 줄여가며 encoded 한계 만족 — 입력이 KB 단위라 비용 무시 가능.
        while enc(trimmed) + suffixEnc > maxEncodedBodyBytes && trimmed.count > 200 {
            trimmed = String(trimmed.prefix(trimmed.count - 200))
        }
        return trimmed + suffix
    }

    /// composeBody 에 전달하는 크래시 요약. `CrashRecord` 와 View 사이의 어댑터.
    struct CrashSummary {
        let crashedAtString: String
        let signalSummary: String
        let ipsFileName: String
        let bodyExcerpt: String
    }

    static func makeURL(title: String, body: String) -> URL? {
        var comps = URLComponents(string: "https://github.com/\(repoOwner)/\(repoName)/issues/new")!
        let effectiveTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "[Bug Report]"
            : title
        comps.queryItems = [
            .init(name: "title", value: effectiveTitle),
            .init(name: "body", value: body),
            .init(name: "labels", value: "bug"),
        ]
        return comps.url
    }

    private static func readLogTail() -> String? {
        guard let data = try? Data(contentsOf: DebugLog.fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let split = text.split(separator: "\n", omittingEmptySubsequences: true)
        var tail = split.suffix(logTailLines).joined(separator: "\n")
        if tail.count > logMaxLength {
            tail = String(tail.suffix(logMaxLength))
            tail = "(앞부분 생략)\n" + tail
        }
        return tail
    }
}

/// 클립보드 이미지 폴링. 다이얼로그 열리는 동안만 1초 주기로 체크.
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let shared = ClipboardWatcher()
    @Published var image: NSImage?
    private var lastChangeCount: Int = -1
    private var timer: Timer?

    func start() {
        check()
        timer?.invalidate()
        // shared singleton 직접 참조 — `[weak self]` 캡처를 Task가 사용하면 CI strict
        // concurrency가 "reference to captured var 'self' in concurrently-executing code"
        // 로 거부함. 인스턴스가 항상 살아있으므로 안전.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in ClipboardWatcher.shared.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let first = imgs.first {
            image = first
        } else {
            image = nil
        }
    }
}

@MainActor
struct BugReportView: View {
    @State private var title: String
    @State private var description: String
    @State private var includeAppVersion: Bool = true
    @State private var includeOSVersion: Bool = true
    @State private var includeLog: Bool
    @State private var includeCrash: Bool
    @ObservedObject var clipboard: ClipboardWatcher = .shared
    private let crashPrefill: BugReport.CrashSummary?

    init(crashPrefill: BugReport.CrashSummary? = nil) {
        self.crashPrefill = crashPrefill
        let isCrash = crashPrefill != nil
        _title = State(initialValue: isCrash ? "[Crash] " : "")
        _description = State(initialValue: "")
        _includeLog = State(initialValue: isCrash)   // 크래시 컨텍스트에는 로그가 사실상 필수.
        _includeCrash = State(initialValue: isCrash)
    }

    var canSubmit: Bool {
        // 크래시 prefill 이 있으면 사용자가 설명 못 적어도 (정보 모자라도) 보낼 수 있게 — 정보 0보다는 낫다.
        if crashPrefill != nil { return true }
        return !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: crashPrefill != nil ? "exclamationmark.triangle.fill" : "ladybug.fill")
                    .foregroundStyle(crashPrefill != nil ? .orange : .red)
                Text(crashPrefill != nil ? "크래시 리포트" : "버그 리포트")
                    .font(.system(size: 16, weight: .semibold))
            }
            if let crash = crashPrefill {
                VStack(alignment: .leading, spacing: 2) {
                    Text("앱이 비정상 종료되었어요 (\(crash.crashedAtString))")
                        .font(.system(size: 11, weight: .medium))
                    Text(crash.signalSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.10))
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("제목").font(.system(size: 11, weight: .medium))
                TextField("예: 메뉴바에서 펫이 사라짐", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("설명").font(.system(size: 11, weight: .medium))
                ZStack(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(crashPrefill != nil
                             ? "크래시 직전에 어떤 작업을 하고 계셨나요? 재현 방법이 있다면 큰 도움이 됩니다. (비워둬도 제출 가능)"
                             : "어떤 문제가 있었나요? 재현 방법과 기대 동작도 알려주시면 수정에 큰 도움이 됩니다.")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $description)
                        .font(.system(size: 12))
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("자동 첨부").font(.system(size: 11, weight: .medium))
                Toggle("앱 버전", isOn: $includeAppVersion)
                Toggle("macOS 버전", isOn: $includeOSVersion)
                Toggle("최근 디버그 로그 마지막 \(BugReport.logTailLines)줄", isOn: $includeLog)
                if crashPrefill != nil {
                    Toggle("크래시 리포트 발췌 (.ips 일부)", isOn: $includeCrash)
                }
                if includeLog {
                    Text("로그에는 사용량 % 같은 정보가 포함됩니다. GitHub 페이지에서 제출 전에 한 번 더 검토해주세요.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            if let img = clipboard.image {
                HStack(spacing: 10) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 70, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("📎 클립보드에 스크린샷이 있습니다")
                            .font(.system(size: 11, weight: .medium))
                        Text("GitHub 페이지가 열리면 본문 영역에 Cmd+V로 붙여넣을 수 있어요.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("취소") { close() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                        Text("GitHub에서 작성하기")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(width: 480, height: 540)
    }

    private func submit() {
        let body = BugReport.composeBody(
            description: description,
            includeAppVersion: includeAppVersion,
            includeOSVersion: includeOSVersion,
            includeLog: includeLog,
            hasClipboardImage: clipboard.image != nil,
            crashSummary: includeCrash ? crashPrefill : nil
        )
        if let url = BugReport.makeURL(title: title, body: body) {
            NSWorkspace.shared.open(url)
        }
        close()
    }

    private func close() {
        BugReportWindowController.shared.dismiss()
    }
}

@MainActor
final class BugReportWindowController: NSWindowController {
    static let shared = BugReportWindowController()

    convenience init() {
        let host = NSHostingController(rootView: BugReportView())
        let window = NSWindow(contentViewController: host)
        window.title = "버그 리포트"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present(crashPrefill: BugReport.CrashSummary? = nil) {
        // prefill 갈아끼우려면 매 호출마다 host view 교체. 동시에 두 번 열릴 수 없는 단일 창이라 race 없음.
        let host = NSHostingController(rootView: BugReportView(crashPrefill: crashPrefill))
        window?.contentViewController = host
        window?.title = crashPrefill != nil ? "크래시 리포트" : "버그 리포트"
        ClipboardWatcher.shared.start()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        ClipboardWatcher.shared.stop()
        window?.close()
    }
}
