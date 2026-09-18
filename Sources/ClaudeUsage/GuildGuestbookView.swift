import AppKit
import SwiftUI

/// 길드 방명록 공용 렌더 (docs/plans/guild-visit.md M2·M3) — 방문 시트(`GuildVisitView`)와
/// 내 길드 화면(`GuildView`)이 같은 줄 모양을 쓴다. 데이터 fetch·작성·삭제 호출은 호출 측이 맡고,
/// 이 뷰는 원글 + 답글(1단) + 답글 작성창의 그림만 책임진다.
///
/// 게시판과 달리 비익명: 작성자 닉네임 + 소속 길드명 + 대표 펫. "○○ 길드의 △△가 다녀감"이
/// 놀러가기의 재미라서 익명화하지 않는다 (길드 표면의 관례).
@MainActor
struct GuildGuestbookRow: View {
    let entry: RankingAPI.GuildGuestbookEntry
    /// 삭제 버튼 노출 — 호출 측이 "작성자 + 윈도우 내" 또는 "길드장"을 판정해 넘긴다.
    let canDelete: Bool
    let deleting: Bool
    let onDelete: () -> Void

    // 답글 (M3) — 호출 측이 넘기지 않으면 원글만 그린다 (구버전 서버·읽기 전용 화면).
    /// 표시할 답글(시간순). 응답의 미리보기(최근 3개)거나 "더 보기"로 받은 전체.
    var replies: [RankingAPI.GuildGuestbookReply] = []
    var replyCount: Int = 0
    /// 답글 작성 가능 — 그 길드 멤버 또는 원글 작성자 + GitHub 게이트 통과.
    var canReply: Bool = false
    var replyMaxLen: Int = 60
    var replyBusy: Bool = false
    var loadingReplies: Bool = false
    var canDeleteReply: (RankingAPI.GuildGuestbookReply) -> Bool = { _ in false }
    var deletingReplyIds: Set<Int> = []
    /// (내용, 완료 콜백) — 성공이면 true를 넘겨 작성창을 닫고 초안을 비운다. 실패면 초안 유지.
    var onReply: ((String, @escaping (Bool) -> Void) -> Void)? = nil
    var onDeleteReply: ((RankingAPI.GuildGuestbookReply) -> Void)? = nil
    /// "답글 N개 더 보기" — 전체 답글을 받아오는 호출.
    var onLoadAllReplies: (() -> Void)? = nil

    @State private var composing = false
    @State private var replyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                petAvatar(kind: entry.kind, variant: entry.variant, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(entry.nickname)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if let guild = entry.guildName, !guild.isEmpty {
                            Text("· \(guild)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(GuildGuestbookFormat.relative(entry.createdAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        if canDelete {
                            trashButton(busy: deleting, help: "방명록 삭제", action: onDelete)
                        }
                    }
                    Text(entry.content)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !replies.isEmpty || replyCount > 0 || canReply {
                repliesBlock
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.sm)
                .fill(entry.isMine ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.06))
        )
    }

    // MARK: - 답글

    /// 원글 아래 들여쓴 답글 목록 + "더 보기" + 작성창. 1단이라 답글의 답글은 없다.
    private var repliesBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(replies) { reply in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                        .padding(.top, 3)
                    petAvatar(kind: reply.kind, variant: reply.variant, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(reply.nickname)
                                .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(GuildGuestbookFormat.relative(reply.createdAt))
                                .font(.system(size: 8)).foregroundStyle(.tertiary)
                            if canDeleteReply(reply) {
                                trashButton(busy: deletingReplyIds.contains(reply.id),
                                            help: "답글 삭제") { onDeleteReply?(reply) }
                            }
                        }
                        Text(reply.content)
                            .font(.system(size: 10))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .padding(.leading, 4)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.sm)
                        .fill(reply.isMine ? Color.accentColor.opacity(0.06) : Color.clear)
                )
            }
            HStack(spacing: 8) {
                if replyCount > replies.count, let onLoadAllReplies {
                    Button {
                        onLoadAllReplies()
                    } label: {
                        if loadingReplies {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("답글 \(replyCount - replies.count)개 더 보기")
                                .font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(loadingReplies)
                }
                if canReply, !composing {
                    Button {
                        composing = true
                    } label: {
                        Label("답글", systemImage: "arrowshape.turn.up.left")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.leading, 18)
            if composing {
                replyComposer
            }
        }
        .padding(.leading, 10)
        .padding(.top, 2)
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                TextField("\(replyMaxLen)자 이내로 답글…", text: $replyDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .lineLimit(1...2)
                    .disabled(replyBusy)
                    .onChange(of: replyDraft) { new in
                        if new.count > replyMaxLen { replyDraft = String(new.prefix(replyMaxLen)) }
                    }
                Button {
                    submitReply()
                } label: {
                    if replyBusy {
                        ProgressView().controlSize(.mini).frame(width: 30)
                    } else {
                        Text("보내기").font(.system(size: 10)).frame(width: 30)
                    }
                }
                .controlSize(.small)
                .disabled(!canSubmitReply)
                Button("취소") {
                    composing = false
                    replyDraft = ""
                }
                .controlSize(.small)
                .font(.system(size: 10))
                .disabled(replyBusy)
            }
            Text("\(replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(replyMaxLen)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(replyDraft.count >= replyMaxLen ? .red : .secondary)
        }
        .padding(.leading, 18)
    }

    private var canSubmitReply: Bool {
        let trimmed = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !replyBusy && !trimmed.isEmpty && trimmed.count <= replyMaxLen && onReply != nil
    }

    private func submitReply() {
        guard canSubmitReply, let onReply else { return }
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onReply(text) { ok in
            if ok {
                replyDraft = ""
                composing = false
            }
        }
    }

    // MARK: - 조각

    private func trashButton(busy: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive) {
            action()
        } label: {
            if busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "trash").font(.system(size: 9))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(busy)
        .help(help)
    }

    @ViewBuilder
    private func petAvatar(kind: PetKind?, variant: Int, size: CGFloat) -> some View {
        if let kind,
           let frame = PetSprite.image(for: kind, action: .walk, frameIndex: 0) {
            Image(nsImage: frame)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(variant == PetOwnership.prestigeVariant
                    ? 0 : WalkingCat.hueDegrees(for: variant)))
                .scaleEffect(x: kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(width: size, height: size * 0.85)
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size * 0.85)
        }
    }
}

enum GuildGuestbookFormat {
    /// "방금" / "N분 전" / "N시간 전" / "N일 전" — 방명록은 정확한 시각보다 "얼마나 최근"이 중요하다.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let secs = max(0, now.timeIntervalSince(date))
        if secs < 60 { return "방금" }
        if secs < 3_600 { return "\(Int(secs / 60))분 전" }
        if secs < 86_400 { return "\(Int(secs / 3_600))시간 전" }
        return "\(Int(secs / 86_400))일 전"
    }

    /// 작성자 본인 삭제 가능 여부 — 서버 윈도우(초)와 같은 기준. 길드장 판정은 호출 측이 OR로 더한다.
    static func isDeletableByAuthor(_ entry: RankingAPI.GuildGuestbookEntry,
                                    windowSec: Int, now: Date = Date()) -> Bool {
        entry.isMine && now.timeIntervalSince(entry.createdAt) <= TimeInterval(windowSec)
    }

    /// 답글 본인 삭제 — 원글과 같은 윈도우.
    static func isDeletableByAuthor(_ reply: RankingAPI.GuildGuestbookReply,
                                    windowSec: Int, now: Date = Date()) -> Bool {
        reply.isMine && now.timeIntervalSince(reply.createdAt) <= TimeInterval(windowSec)
    }

    static func formatCooldown(_ sec: Int) -> String {
        if sec >= 3_600 { return "\(Int(ceil(Double(sec) / 3_600)))시간" }
        let m = sec / 60, s = sec % 60
        if m > 0 { return "\(m)분 \(s)초" }
        return "\(s)초"
    }
}
