import AppKit
import SwiftUI

// 미니 게시판 — 100자 텍스트 + 좋아요. 등록 사용자만 작성, 읽기는 모두 가능.
//
// UI 구조:
//   상단 헤더(제목/새로고침) → 입력란(100자 카운터/전송 버튼) → cooldown 안내(있을 때)
//   → 글 리스트 (ScrollView + 좋아요 버튼 + 호버 popover) → 푸터(마지막 새로고침/총 N개)
//
// 자동 새로고침: 윈도우 열려있는 동안 30초 주기. 백그라운드 폴링은 안 함 (트래픽 절약).
// 좋아요 연타 방지: in-flight + 1초 cooldown (likingPostIds Set 가드).

struct BoardView: View {
    @ObservedObject var settings = Settings.shared
    @State private var posts: [RankingAPI.BoardPost] = []
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var lastRefresh: Date?
    @State private var refreshTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    @State private var draft: String = ""
    @State private var posting: Bool = false
    /// 클라이언트측 카운트다운 (서버 cooldownRemainingSec를 매 초 감소).
    @State private var clientCooldownSec: Int = 0
    @State private var cooldownTickTask: Task<Void, Never>?

    /// 좋아요 in-flight + 1초 추가 cooldown 중인 postId 모음. 서버 트래픽 슈팅 방지.
    @State private var likingPostIds: Set<Int> = []

    private static let maxContentLength = 100

    /// 게시판 사용 가능 여부 — 등록 + 활성 둘 다 필요. 일시중지면 false.
    private var rankingActive: Bool {
        settings.rankingRegistered && settings.rankingEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !RankingAPI.isConfigured {
                placeholderView("게시판 기능이 이 빌드에 포함되지 않았습니다.")
            } else if !rankingActive {
                // 랭킹 미참여자/일시중지자는 읽기/쓰기/좋아요 모두 차단.
                gatedView
            } else {
                composeSection
                Divider()
                listSection
                footer
            }
        }
        .frame(minWidth: 480, minHeight: 540)
        .onAppear {
            // 윈도우 표시 → 미확인 카운트 즉시 0. 활성자만 fetch.
            if rankingActive {
                NotificationCenter.default.post(name: .boardSeen, object: nil)
                refresh()
                startPolling()
            }
        }
        .onDisappear {
            refreshTask?.cancel()
            pollTask?.cancel()
            cooldownTickTask?.cancel()
        }
    }

    /// 미참여/일시중지 안내 화면. 케이스별 메시지 + CTA 버튼.
    /// 게시판 콘텐츠 자체는 노출 X — 닉네임 정체성이 랭킹 참여 상태에 묶여 있어야 성립.
    private var gatedView: some View {
        let isPaused = settings.rankingRegistered && !settings.rankingEnabled
        return VStack(spacing: 12) {
            Image(systemName: isPaused ? "pause.circle" : "lock.shield")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(isPaused ? "랭킹 일시중지 — 게시판도 함께 중단되었습니다."
                          : "게시판은 랭킹 참여자 전용입니다.")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Text(isPaused ? "설정에서 랭킹을 다시 시작하면 게시판 사용이 재개됩니다."
                          : "랭킹에 등록하시면 닉네임을 게시판 작성자로 사용할 수 있습니다.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(isPaused ? "설정 열기…" : "랭킹 등록…") { openRankingSettings() }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("💬").font(.system(size: 14))
            Text("게시판").font(.system(size: 14, weight: .semibold))
            Spacer()
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("새로고침")
            }
        }
        .padding(12)
    }

    // MARK: - Compose

    @ViewBuilder
    private var composeSection: some View {
        if !settings.rankingRegistered {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.shield.checkmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("게시판 작성은 랭킹 등록 후 가능합니다.")
                        .font(.system(size: 12))
                    Text("닉네임이 글쓴이로 표시됩니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("랭킹 등록…") { openRankingSettings() }
            }
            .padding(12)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    TextField("100자 이내로 한마디…", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .disabled(posting || clientCooldownSec > 0)
                        .onChange(of: draft) { new in
                            if new.count > Self.maxContentLength {
                                draft = String(new.prefix(Self.maxContentLength))
                            }
                        }
                    Button {
                        submitDraft()
                    } label: {
                        if posting {
                            ProgressView().controlSize(.small).frame(width: 50)
                        } else {
                            Text("전송").frame(width: 50)
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit)
                }
                HStack {
                    Text("\(draft.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(Self.maxContentLength)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(draft.count >= Self.maxContentLength ? .red : .secondary)
                    Spacer()
                    if clientCooldownSec > 0 {
                        Text("다음 글까지 \(formatCooldown(clientCooldownSec))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("⌘↩로 전송")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            .padding(12)
        }
    }

    private var canSubmit: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !posting
            && clientCooldownSec == 0
            && !trimmed.isEmpty
            && trimmed.count <= Self.maxContentLength
            && settings.rankingRegistered
    }

    private func formatCooldown(_ sec: Int) -> String {
        let m = sec / 60, s = sec % 60
        if m > 0 { return "\(m)분 \(s)초" }
        return "\(s)초"
    }

    // MARK: - List

    @ViewBuilder
    private var listSection: some View {
        if posts.isEmpty && !loading {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("아직 글이 없습니다. 첫 글을 남겨보세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 40)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(posts) { post in
                        BoardRow(
                            post: post,
                            isLikeBusy: likingPostIds.contains(post.id),
                            isMyOwnPost: post.isMine,
                            onLikeTap: { toggleLike(postId: post.id) }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let lastRefresh {
                Text("\(lastRefresh.formatted(date: .omitted, time: .shortened)) 기준")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("총 \(posts.count)개 (최대 100)")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func placeholderView(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func refresh() {
        refreshTask?.cancel()
        loading = true
        let deviceId = settings.rankingRegistered && !settings.rankingDeviceID.isEmpty
            ? settings.rankingDeviceID : nil
        refreshTask = Task { @MainActor in
            defer { loading = false }
            do {
                let resp = try await RankingAPI.shared.fetchBoard(deviceId: deviceId)
                posts = resp.posts
                lastRefresh = Date()
                error = nil
                applyServerCooldown(resp.cooldownRemainingSec)
                // 윈도우 active 동안에는 새 글이 와도 사용자가 즉시 본 셈 — 메인 패널 배지를 0 유지.
                // 윈도우 닫히면 polling 멈추고 ViewModel cycle만 새 글 카운트.
                NotificationCenter.default.post(name: .boardSeen, object: nil)
            } catch is CancellationError {
                // 무시
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// 서버가 권위 — 클라이언트 시계 조작/잘못된 캐시 방어. 서버 값이 클라보다 크면 채택.
    private func applyServerCooldown(_ serverSec: Int) {
        if serverSec > clientCooldownSec {
            clientCooldownSec = serverSec
            startCooldownTick()
        } else if serverSec == 0 && clientCooldownSec == 0 {
            cooldownTickTask?.cancel()
        }
    }

    private func startCooldownTick() {
        cooldownTickTask?.cancel()
        cooldownTickTask = Task { @MainActor in
            while clientCooldownSec > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                clientCooldownSec = max(0, clientCooldownSec - 1)
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                // 60s 주기 — 게시판이 채팅 아닌 게시판 톤이라 1분 충분. Supabase free tier
                // (500K invocations/mo) 안전마진 확보. 50명 active 사용자 시 30s는 한계 근처.
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                refresh()
            }
        }
    }

    private func submitDraft() {
        guard canSubmit else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !settings.rankingDeviceID.isEmpty else { return }
        let key = Keychain.loadRankingHmacKey() ?? ""
        guard !key.isEmpty else {
            error = "HMAC 키가 비어 있습니다 — 랭킹 재등록이 필요합니다."
            return
        }
        posting = true
        error = nil
        Task { @MainActor in
            defer { posting = false }
            do {
                _ = try await RankingAPI.shared.submitBoardPost(
                    deviceId: settings.rankingDeviceID,
                    content: content,
                    hmacKeyBase64: key
                )
                draft = ""
                clientCooldownSec = 600
                startCooldownTick()
                refresh()
            } catch let RankingAPI.RankingError.rateLimited(retryAfterSec: s) {
                clientCooldownSec = max(clientCooldownSec, s)
                startCooldownTick()
                error = "다음 글 작성까지 \(formatCooldown(s)) 남았습니다."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func toggleLike(postId: Int) {
        guard settings.rankingRegistered else {
            error = "좋아요는 랭킹 등록 후 가능합니다."
            return
        }
        guard !likingPostIds.contains(postId) else { return }
        let key = Keychain.loadRankingHmacKey() ?? ""
        guard !key.isEmpty, !settings.rankingDeviceID.isEmpty else { return }

        likingPostIds.insert(postId)

        // Optimistic toggle — 즉시 UI 반전. 서버 응답으로 reconcile.
        if let idx = posts.firstIndex(where: { $0.id == postId }) {
            let p = posts[idx]
            let optimistic = RankingAPI.BoardPost(
                id: p.id,
                nickname: p.nickname,
                content: p.content,
                createdAt: p.createdAt,
                isMine: p.isMine,
                likeCount: p.likeCount + (p.likedByMe ? -1 : 1),
                likedByMe: !p.likedByMe,
                likers: p.likers // 정확한 likers는 다음 fetch에서. count만 임시 반영.
            )
            posts[idx] = optimistic
        }

        Task { @MainActor in
            defer {
                // 응답 받든 실패하든 1초 cooldown 후 버튼 다시 활성화.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    likingPostIds.remove(postId)
                }
            }
            do {
                let resp = try await RankingAPI.shared.likeBoardPost(
                    deviceId: settings.rankingDeviceID,
                    postId: postId,
                    hmacKeyBase64: key
                )
                // 서버 응답으로 count/liked 정확히 반영. likers는 다음 polling에서 갱신.
                if let idx = posts.firstIndex(where: { $0.id == postId }) {
                    let p = posts[idx]
                    posts[idx] = RankingAPI.BoardPost(
                        id: p.id,
                        nickname: p.nickname,
                        content: p.content,
                        createdAt: p.createdAt,
                        isMine: p.isMine,
                        likeCount: resp.count,
                        likedByMe: resp.liked,
                        likers: p.likers
                    )
                }
            } catch {
                // 실패 — optimistic 반영 되돌림. 다음 refresh로 진실 반영.
                refresh()
                self.error = error.localizedDescription
            }
        }
    }

    /// 환경설정 → 랭킹 섹션을 띄우는 진입점. 윈도우 닫지 않음 — 작성 끝나면 돌아오기 편하게.
    private func openRankingSettings() {
        NotificationCenter.default.post(name: .openRankingSettings, object: nil)
    }
}

// MARK: - Row

private struct BoardRow: View {
    let post: RankingAPI.BoardPost
    let isLikeBusy: Bool
    let isMyOwnPost: Bool
    let onLikeTap: () -> Void
    @State private var hoveringHeart: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(post.nickname)
                        .font(.system(size: 12, weight: isMyOwnPost ? .semibold : .medium))
                        .foregroundStyle(isMyOwnPost ? Color.accentColor : .primary)
                    Text(relativeTime(post.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if isMyOwnPost {
                        Text("나")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(3)
                    }
                }
                Text(post.content)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 좋아요 버튼 + count + 호버 popover.
            Button(action: onLikeTap) {
                HStack(spacing: 3) {
                    Image(systemName: post.likedByMe ? "heart.fill" : "heart")
                        .foregroundStyle(post.likedByMe ? Color.pink : Color.secondary)
                    Text("\(post.likeCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(isLikeBusy)
            .opacity(isLikeBusy ? 0.5 : 1.0)
            .onHover { hoveringHeart = $0 }
            .popover(isPresented: $hoveringHeart, arrowEdge: .top) {
                likersPopover
                    .padding(8)
            }
        }
    }

    @ViewBuilder
    private var likersPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("좋아요 \(post.likeCount)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if post.likers.isEmpty {
                Text("아직 좋아요가 없습니다.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                // 시간순(오래된 것부터) — 최신 위로 보이게 reverse.
                let visible = Array(post.likers.reversed().prefix(20))
                ForEach(visible, id: \.nickname) { l in
                    HStack(spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.pink)
                        Text(l.nickname).font(.system(size: 11))
                        Spacer(minLength: 8)
                        Text(BoardRow.relativeTimeShort(l.createdAt))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                if post.likers.count > 20 {
                    Text("외 \(post.likers.count - 20)명")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minWidth: 160)
    }

    private func relativeTime(_ date: Date) -> String {
        let now = Date()
        let diff = Int(now.timeIntervalSince(date))
        if diff < 60 { return "방금" }
        if diff < 3600 { return "\(diff / 60)분 전" }
        if diff < 86400 { return "\(diff / 3600)시간 전" }
        let days = diff / 86400
        if days < 7 { return "\(days)일 전" }
        let f = DateFormatter()
        f.dateFormat = "M월 d일"
        return f.string(from: date)
    }

    static func relativeTimeShort(_ date: Date) -> String {
        let now = Date()
        let diff = Int(now.timeIntervalSince(date))
        if diff < 60 { return "방금" }
        if diff < 3600 { return "\(diff / 60)m" }
        if diff < 86400 { return "\(diff / 3600)h" }
        return "\(diff / 86400)d"
    }
}

// MARK: - Window Controller

@MainActor
final class BoardWindowController: NSWindowController {
    static let shared = BoardWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: BoardView())
        let window = NSWindow(contentViewController: host)
        window.title = "게시판"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 540, height: 680))
        window.minSize = NSSize(width: 460, height: 480)
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    /// BoardView가 미등록 사용자에게 "랭킹 등록…" 버튼을 눌렀을 때 emit.
    /// SettingsView가 옵저버로 받아 해당 섹션으로 스크롤/포커스.
    static let openRankingSettings = Notification.Name("openRankingSettings")
    /// BoardView가 윈도우 표시될 때 emit. ViewModel이 받아 boardUnreadCount = 0 + boardLastSeenAt 갱신.
    static let boardSeen = Notification.Name("boardSeen")
}
