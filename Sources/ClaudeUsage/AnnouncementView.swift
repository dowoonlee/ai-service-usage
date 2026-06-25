import AppKit
import SwiftUI

/// 패치 공지 창 본문. 두 가지 모드:
///   * `.popup`  — 업데이트 후 자동 팝업. 미리 받은 새 공지 + 이전 공지.
///   * `.browse` — 확성기 버튼. 직접 fetch해 전체 공지를 브라우즈(로딩/빈/에러 상태 포함).
///
/// 한 화면에 한 공지만 표시하고 `<` `>` 로 페이지를 넘긴다(좌/우 방향키도 동작).
/// 콘텐츠 영역은 고정 높이라 페이지 전환 시 창 크기가 흔들리지 않는다.
struct AnnouncementView: View {
    enum Mode {
        case popup(new: [RankingAPI.AnnouncementRow], previous: [RankingAPI.AnnouncementRow])
        case browse
    }

    let mode: Mode
    var onClose: () -> Void

    @State private var browseState: BrowseState = .loading
    @State private var page: Int = 0

    private enum BrowseState {
        case loading
        case loaded([RankingAPI.AnnouncementRow])
        case empty
        case failed
    }

    /// 페이지별 배지 종류.
    private enum Tag { case new, previous, none }

    /// 콘텐츠 영역 고정 높이 — 페이지/상태가 바뀌어도 창 크기 유지.
    private let contentHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
                .frame(height: contentHeight)
            Divider()
            footer
        }
        .frame(width: 420)
        .task {
            if case .browse = mode { await loadBrowse() }
        }
    }

    // MARK: - 영역

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: headerIcon)
                .foregroundStyle(headerTint)
            Text(headerTitle)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if case .browse = mode {
            switch browseState {
            case .loading: placeholder { ProgressView() }
            case .empty:   placeholder { message("표시할 공지가 없습니다.") }
            case .failed:  placeholder { message("공지를 불러오지 못했습니다.\n네트워크 상태를 확인해 주세요.") }
            case .loaded:  pageView
            }
        } else {
            pageView
        }
    }

    @ViewBuilder
    private var pageView: some View {
        let items = pages
        if items.isEmpty {
            placeholder { message("표시할 공지가 없습니다.") }
        } else {
            let idx = min(page, items.count - 1)
            ScrollView {
                versionBlock(items[idx], tag: tag(for: idx))
                    .padding(18)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if pages.count > 1 {
                Button { page = max(0, currentPage - 1) } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .disabled(currentPage <= 0)
                .keyboardShortcut(.leftArrow, modifiers: [])

                Text("\(currentPage + 1) / \(pages.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button { page = min(pages.count - 1, currentPage + 1) } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(currentPage >= pages.count - 1)
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            Spacer()
            Button("확인") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 페이지 데이터

    /// 표시할 공지 목록(최신순). popup=새 공지+이전 공지, browse=fetch 결과.
    private var pages: [RankingAPI.AnnouncementRow] {
        switch mode {
        case let .popup(new, previous):
            return new + previous
        case .browse:
            if case let .loaded(rows) = browseState { return rows }
            return []
        }
    }

    /// pages 앞쪽 몇 개가 "새 공지"인지(NEW 배지 경계). browse는 0.
    private var newCount: Int {
        switch mode {
        case let .popup(new, _): return new.count
        case .browse: return 0
        }
    }

    /// 클램프된 현재 페이지.
    private var currentPage: Int { max(0, min(page, pages.count - 1)) }

    private func tag(for idx: Int) -> Tag {
        switch mode {
        case .popup:  return idx < newCount ? .new : .previous
        case .browse: return .none
        }
    }

    // MARK: - 공지 블록

    @ViewBuilder
    private func versionBlock(_ item: RankingAPI.AnnouncementRow, tag: Tag) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("v\(item.version)")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.headline)
                Spacer(minLength: 0)
                tagBadge(tag)
            }
            bodyText(item.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tagBadge(_ tag: Tag) -> some View {
        switch tag {
        case .new:
            Text("NEW")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.green, in: Capsule())
        case .previous:
            Text("이전 공지")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    /// 줄 단위 렌더 — "- "/"• "로 시작하면 불릿, 빈 줄은 간격, 나머지는 문단. 인라인 마크다운 지원.
    @ViewBuilder
    private func bodyText(_ body: String) -> some View {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Spacer().frame(height: 2)
                } else if line.hasPrefix("- ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.markdown(String(line.dropFirst(2))))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text(Self.markdown(line))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholder<V: View>(@ViewBuilder _ inner: () -> V) -> some View {
        inner()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
    }

    // MARK: - 헤더 스타일 (모드별)

    private var headerTitle: String {
        switch mode {
        case .popup:  return "업데이트 안내"
        case .browse: return "공지사항"
        }
    }
    private var headerIcon: String {
        switch mode {
        case .popup:  return "sparkles"
        case .browse: return "megaphone.fill"
        }
    }
    private var headerTint: Color {
        switch mode {
        case .popup:  return .yellow
        case .browse: return .orange
        }
    }

    // MARK: - browse fetch

    private func loadBrowse() async {
        browseState = .loading
        // dev(미구성) — 릴리스는 빈 상태, DEBUG는 데모 데이터로 레이아웃 확인 가능.
        guard RankingAPI.isConfigured else {
            #if DEBUG
            browseState = .loaded(AnnouncementManager.demoNew() + AnnouncementManager.demoPrevious())
            #else
            browseState = .empty
            #endif
            return
        }
        do {
            let rows = try await RankingAPI.shared.fetchRecentAnnouncements(
                currentVersion: RankingAPI.appVersion)
            browseState = rows.isEmpty ? .empty : .loaded(rows)
        } catch {
            DebugLog.log("Announcements browse fetch 실패: \(error)")
            browseState = .failed
        }
    }

    /// 인라인 마크다운만(굵게/링크 등). 실패 시 원문 그대로.
    private static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}

/// 공지 단일 창. `BugReportWindowController`와 동일하게 단일 인스턴스 — 동시에 두 번 열릴 수
/// 없어 race 없음. LSUIElement 앱이라 표시 직전 `NSApp.activate`로 앞으로 가져온다.
@MainActor
final class AnnouncementWindowController: NSWindowController {
    static let shared = AnnouncementWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "공지"
        window.titleVisibility = .hidden          // 본문 헤더와 중복 방지.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    /// 업데이트 후 자동 팝업 — 미리 받은 새 공지 + 이전 공지.
    func present(new items: [RankingAPI.AnnouncementRow],
                 previous: [RankingAPI.AnnouncementRow]) {
        guard !items.isEmpty else { return }
        show(mode: .popup(new: items, previous: previous))
    }

    /// 확성기 버튼 — 전체 공지 브라우즈(창이 직접 fetch).
    func presentBrowse() {
        show(mode: .browse)
    }

    private func show(mode: AnnouncementView.Mode) {
        let root = AnnouncementView(mode: mode) { [weak self] in
            self?.window?.close()
        }
        window?.contentViewController = NSHostingController(rootView: root)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
