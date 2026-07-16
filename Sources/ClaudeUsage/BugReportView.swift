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
        crashSummary: CrashSummary? = nil,
        diagnosticId: String? = nil,
        diagnosticFailed: Bool = false
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
        // 사용량 이슈: raw 는 GitHub 공개 본문이 아니라 비공개 DB 로 갔고, 여기엔 역참조용 ID 만 남긴다.
        if let diagnosticId {
            lines.append("## 진단 데이터")
            lines.append("- ID: `\(diagnosticId)`")
            lines.append("- Claude·Cursor·Codex 사용량 응답 원본(랭킹 디코딩 오류 발생 시 해당 응답 포함)이 비공개로 첨부되었습니다 (개인정보·잔액 제외). 개발자가 이 ID로 조회합니다.")
            lines.append("")
        } else if diagnosticFailed {
            lines.append("## 진단 데이터")
            lines.append("- ⚠️ 사용량 응답 자동 첨부에 실패했습니다. 증상과 재현 방법을 설명에 자세히 적어주세요.")
            lines.append("")
        }
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

    static func readLogTail() -> String? {
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

/// 버그리포트 템플릿. `.usage` 는 사용량 응답 원본(rate_limit 등)을 비공개 DB 로 첨부하고
/// 이슈에는 조회용 ID 만 남긴다 — 로그만으로는 진단이 안 되는 사용량 버그를 위해.
enum ReportTemplate: String, CaseIterable, Identifiable {
    case general, usage
    var id: String { rawValue }
    var label: String { self == .general ? "일반" : "사용량 이슈" }
}

@MainActor
struct BugReportView: View {
    @State private var title: String
    @State private var description: String
    @State private var includeAppVersion: Bool = true
    @State private var includeOSVersion: Bool = true
    @State private var includeLog: Bool
    @State private var includeCrash: Bool
    @State private var template: ReportTemplate = .general
    @State private var submitting = false
    @State private var submitError: String? = nil
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
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.orange.opacity(0.10))
                )
            }

            // 크래시 prefill 은 항상 일반 보고라 템플릿 선택을 노출하지 않는다.
            if crashPrefill == nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("유형").font(.system(size: 11, weight: .medium))
                    Picker("유형", selection: $template) {
                        ForEach(ReportTemplate.allCases) { t in Text(t.label).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if template == .usage {
                        Text("Claude·Cursor·Codex 사용량 응답 구조(랭킹 오류 발생 시 해당 응답 포함)가 비공개로 첨부됩니다 (개인정보·잔액 제외). GitHub 이슈에는 조회용 ID만 적힙니다.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
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
                            RoundedRectangle(cornerRadius: AppRadius.sm)
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
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: AppRadius.sm)
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
                    RoundedRectangle(cornerRadius: AppRadius.md)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }

            Spacer(minLength: 0)

            if let submitError {
                Text(submitError).font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("취소") { close() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                Button {
                    submit()
                } label: {
                    HStack(spacing: 4) {
                        if submitting { ProgressView().controlSize(.small) }
                        Image(systemName: "arrow.up.right.square")
                        Text(submitting ? "진단 수집 중..." : "GitHub에서 작성하기")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || submitting)
            }
        }
        .padding(16)
        .frame(width: 480, height: 540)
    }

    private func submit() {
        // 사용량 이슈는 raw 수집 + Supabase 전송이 선행돼야 하므로 비동기 경로.
        if template == .usage && crashPrefill == nil {
            Task { await submitUsageIssue() }
        } else {
            openIssue(diagnosticId: nil)
        }
    }

    /// GitHub 이슈를 연다. `diagnosticId` 가 있으면 본문에 역참조 ID 를, `diagnosticFailed` 면 실패 안내를 남긴다.
    private func openIssue(diagnosticId: String?, diagnosticFailed: Bool = false) {
        // 사용량 이슈는 로그를 비공개 DB(log_tail)로 보내므로 공개 본문에는 중복 첨부하지 않는다.
        let bodyIncludeLog = template == .usage ? false : includeLog
        let body = BugReport.composeBody(
            description: description,
            includeAppVersion: includeAppVersion,
            includeOSVersion: includeOSVersion,
            includeLog: bodyIncludeLog,
            hasClipboardImage: clipboard.image != nil,
            crashSummary: includeCrash ? crashPrefill : nil,
            diagnosticId: diagnosticId,
            diagnosticFailed: diagnosticFailed
        )
        if let url = BugReport.makeURL(title: title, body: body) {
            NSWorkspace.shared.open(url)
        }
        close()
    }

    /// 3소스 사용률 서브트리를 비공개 DB 에 적재한 뒤, 성공 시 그 row UUID 를 이슈 본문에 남기고 연다.
    /// 전송 실패/미설정 시에는 ID 없이 "자동 첨부 실패" 안내와 함께 일반 이슈로 폴백한다.
    private func submitUsageIssue() async {
        submitting = true
        defer { submitting = false }

        let appVer = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        let dev = Settings.shared.rankingDeviceID
        var sample = DiagnosticSample.newBugReport(
            deviceId: dev.isEmpty ? nil : dev,
            appVersion: appVer,
            osVersion: osVer
        )
        if let codex = await CodexAPI.shared.usageDiagnostic() {
            sample.rateLimitJson = codex.subtreeJson
            sample.planType = codex.planType
        }
        if let claude = await UsageAPI.shared.usageDiagnostic() {
            sample.claudeUsageJson = claude.subtreeJson
        }
        if let cursor = await CursorAPI.shared.usageDiagnostic() {
            sample.cursorUsageJson = cursor.subtreeJson
        }
        if includeLog { sample.logTail = BugReport.readLogTail() }
        // 최근(24h) 랭킹 디코딩 실패가 캡처돼 있으면 함께 첨부 (#56 — #54류 디버깅 사각지대 해소).
        if let rf = RankingDiagnosticStore.recentForAttach(now: Date()) {
            sample.rankingResponseJson = rf.maskedJson
            sample.rankingDecodeError = "path=\(rf.path) status=\(rf.status) err=\(rf.errorDesc.prefix(200))"
        }

        guard RankingAPI.isConfigured else {
            DebugLog.log(" BugReport usage: RankingAPI 미설정 — 진단 데이터 없이 이슈만 작성")
            openIssue(diagnosticId: nil, diagnosticFailed: true)
            return
        }
        do {
            try await RankingAPI.shared.submitDiagnostic(sample)
            openIssue(diagnosticId: sample.id)
        } catch {
            DebugLog.log(" BugReport usage 전송 실패: \(error)")
            openIssue(diagnosticId: nil, diagnosticFailed: true)
        }
    }

    private func close() {
        BugReportWindowController.shared.dismiss()
    }
}

@MainActor
final class BugReportWindowController: NSWindowController, NSWindowDelegate, SingleWindowPresenting {
    static let shared = BugReportWindowController()

    convenience init() {
        let host = NSHostingController(rootView: BugReportView())
        let window = NSWindow(contentViewController: host)
        window.title = "버그 리포트"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    /// 타이틀바 닫기 버튼은 dismiss()를 안 거친다 — 여기서도 1Hz 클립보드 폴링을 반드시
    /// 멈춰야 한다 (안 멈추면 앱 종료까지 계속 돈다).
    func windowWillClose(_ notification: Notification) {
        ClipboardWatcher.shared.stop()
    }

    func present(crashPrefill: BugReport.CrashSummary? = nil) {
        // prefill 갈아끼우려면 매 호출마다 host view 교체. 동시에 두 번 열릴 수 없는 단일 창이라 race 없음.
        let host = NSHostingController(rootView: BugReportView(crashPrefill: crashPrefill))
        window?.contentViewController = host
        window?.title = crashPrefill != nil ? "크래시 리포트" : "버그 리포트"
        ClipboardWatcher.shared.start()
        bringToFront()
    }

    func dismiss() {
        ClipboardWatcher.shared.stop()
        window?.close()
    }
}
