import AppKit
import SwiftUI

/// 다른 길드 사무실 "놀러가기" 시트 (docs/plans/guild-visit.md M1).
///
/// 랭킹 탭 길드 리더보드 행과 미가입 온보딩 둘러보기 행에서 열린다. 진입 시 `guild-visit`을
/// 1회 호출하고 주기 폴링은 두지 않는다 (guild-info가 300s 루프를 걷어낸 이유와 같다).
/// 사무실은 `GuildOfficeView`를 읽기 전용으로 쓴다 — 재배치 바인딩은 상수 false, 콜백은 no-op.
/// 내 대표 펫이 방문객으로 들어가 배회한다 (`OfficeSimulation.Guest`).
///
/// 시트는 폭만 정하면 높이를 받은 만큼만 쓰므로 `minHeight`가 필수(CLAUDE.md "Sheets need an
/// explicit minHeight"). 최상위 `ScrollView` + `maxHeight`로 작은 화면에서도 안에 들어간다.
@MainActor
struct GuildVisitView: View {
    let guildId: String
    /// 응답이 오기 전 헤더에 보여줄 이름 (리더보드 행이 알고 있던 값).
    let guildName: String
    /// 프리뷰/테스트용 — 주입되면 네트워크를 타지 않는다.
    var preloaded: RankingAPI.GuildVisitResponse? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = Settings.shared
    @State private var response: RankingAPI.GuildVisitResponse?
    @State private var error: String?
    @State private var loading = false

    // 방명록 (M2) — 응답에서 떼어 로컬 상태로 둔다: 작성/삭제 후 서버 재조회 없이 즉시 반영.
    @State private var guestbook: [RankingAPI.GuildGuestbookEntry] = []
    @State private var policy: RankingAPI.GuildGuestbookPolicy?
    @State private var draft: String = ""
    @State private var posting = false
    @State private var guestbookError: String?
    /// 서버가 알려준 남은 쿨다운(초) — 1초 tick으로 줄이고 0이 되면 작성창이 열린다.
    @State private var cooldownSec: Int = 0
    @State private var cooldownTask: Task<Void, Never>?
    @State private var deletingIds: Set<Int> = []
    // 답글 (M3)
    @State private var replyBusyIds: Set<Int> = []
    @State private var loadingReplyIds: Set<Int> = []
    @State private var deletingReplyIds: Set<Int> = []

    /// 방문객 = 내 대표 펫. 랭킹 미등록이면 닉네임이 비어 "나"로 표시.
    private var guest: OfficeSimulation.Guest {
        let avatar = settings.trainerCard.avatar
        let name = settings.rankingNickname.isEmpty ? "나" : settings.rankingNickname
        return OfficeSimulation.Guest(name: name, kind: avatar.kind, variant: avatar.variant,
                                      effects: settings.equippedEffects[avatar.kind] ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let response {
                        header(response.guild)
                        officeSection(response)
                        membersSection(response)
                        Divider()
                        guestbookSection(response)
                    } else if let error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("사무실로 가는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 540)
        .frame(minHeight: 460, maxHeight: 700)
        .onAppear(perform: load)
        .onDisappear { cooldownTask?.cancel() }
    }

    // MARK: - 방명록

    /// 방명록 목록 + 작성창. 작성 가능 여부는 서버 정책(`guestbookPolicy`)이 결정한다 —
    /// 자기 길드(열람·삭제만) / GitHub 미연동(읽기 전용) / 쿨다운 중 / 구버전 서버(작성창 없음).
    private func guestbookSection(_ response: RankingAPI.GuildVisitResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("방명록", systemImage: "book.closed")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(guestbook.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
            }
            guestbookComposer(response)
            if guestbook.isEmpty {
                Text(response.guild.isMine
                     ? "아직 놀러온 사람이 없어요. 다른 길드에 먼저 다녀와 보세요."
                     : "첫 방명록을 남겨보세요 ✍️")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(guestbook) { entry in
                    GuildGuestbookRow(
                        entry: entry,
                        canDelete: canDelete(entry),
                        deleting: deletingIds.contains(entry.id),
                        onDelete: { deleteEntry(entry) },
                        replies: entry.replies ?? [],
                        replyCount: entry.replyCount ?? 0,
                        canReply: canReply(entry, in: response),
                        replyMaxLen: policy?.maxLen ?? 60,
                        replyBusy: replyBusyIds.contains(entry.id),
                        loadingReplies: loadingReplyIds.contains(entry.id),
                        canDeleteReply: { canDeleteReply($0) },
                        deletingReplyIds: deletingReplyIds,
                        onReply: { text, done in submitReply(entry, text: text, done: done) },
                        onDeleteReply: { deleteReply(entry, reply: $0) },
                        onLoadAllReplies: { loadAllReplies(entry) })
                }
            }
        }
    }

    @ViewBuilder
    private func guestbookComposer(_ response: RankingAPI.GuildVisitResponse) -> some View {
        if let policy {
            if response.guild.isMine {
                Text(policy.isLeader
                     ? "내 길드 방명록이에요. 길드장은 언제든 지울 수 있어요."
                     : "내 길드 방명록이에요. 다른 길드에 놀러가서 남겨보세요.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if !policy.canInteract {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(.secondary)
                    Text("방명록 작성은 GitHub 인증 후 가능해요. 읽기는 그대로예요.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(Color.gray.opacity(0.08)))
            } else if policy.canWrite {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        TextField("\(policy.maxLen)자 이내로 한마디…", text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                            .disabled(posting || cooldownSec > 0)
                            .onChange(of: draft) { new in
                                if new.count > policy.maxLen { draft = String(new.prefix(policy.maxLen)) }
                            }
                        Button {
                            submitGuestbook(response)
                        } label: {
                            if posting {
                                ProgressView().controlSize(.small).frame(width: 44)
                            } else {
                                Text("남기기").frame(width: 44)
                            }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSubmit(policy))
                    }
                    HStack {
                        Text("\(draft.trimmingCharacters(in: .whitespacesAndNewlines).count) / \(policy.maxLen)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(draft.count >= policy.maxLen ? .red : .secondary)
                        Spacer()
                        if cooldownSec > 0 {
                            Text("다음 방명록까지 \(GuildGuestbookFormat.formatCooldown(cooldownSec))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        } else {
                            Text("같은 길드에는 하루 한 번 · ⌘↩")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    if let guestbookError {
                        Text(guestbookError).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func canSubmit(_ policy: RankingAPI.GuildGuestbookPolicy) -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !posting && cooldownSec == 0 && !trimmed.isEmpty && trimmed.count <= policy.maxLen
    }

    private func canDelete(_ entry: RankingAPI.GuildGuestbookEntry) -> Bool {
        guard let policy else { return false }
        return policy.isLeader
            || GuildGuestbookFormat.isDeletableByAuthor(entry, windowSec: policy.deleteWindowSec)
    }

    // MARK: - 답글 (M3) — 권한은 그 길드 멤버(집주인) 또는 원글 작성자. 서버가 최종 판정.

    private func canReply(_ entry: RankingAPI.GuildGuestbookEntry,
                          in response: RankingAPI.GuildVisitResponse) -> Bool {
        guard let policy, policy.canInteract else { return false }
        return response.guild.isMine || entry.isMine
    }

    private func canDeleteReply(_ reply: RankingAPI.GuildGuestbookReply) -> Bool {
        guard let policy else { return false }
        return policy.isLeader
            || GuildGuestbookFormat.isDeletableByAuthor(reply, windowSec: policy.deleteWindowSec)
    }

    private func mutateEntry(_ id: Int, _ body: (inout RankingAPI.GuildGuestbookEntry) -> Void) {
        guard let idx = guestbook.firstIndex(where: { $0.id == id }) else { return }
        body(&guestbook[idx])
    }

    private func submitReply(_ entry: RankingAPI.GuildGuestbookEntry, text: String,
                             done: @escaping (Bool) -> Void) {
        guard let response, !replyBusyIds.contains(entry.id) else { return done(false) }
        replyBusyIds.insert(entry.id)
        guestbookError = nil
        Task { @MainActor in
            defer { replyBusyIds.remove(entry.id) }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                let resp = try await RankingAPI.shared.replyGuestbook(
                    deviceId: settings.rankingDeviceID, guildId: response.guild.id,
                    entryId: entry.id, content: text, hmacKeyBase64: key)
                mutateEntry(entry.id) {
                    $0.replies = ($0.replies ?? []) + [resp.reply]
                    $0.replyCount = ($0.replyCount ?? 0) + 1
                }
                done(true)
            } catch is CancellationError {
                done(false)
            } catch {
                guestbookError = error.friendlyDescription
                done(false)
            }
        }
    }

    private func deleteReply(_ entry: RankingAPI.GuildGuestbookEntry,
                             reply: RankingAPI.GuildGuestbookReply) {
        guard let response, !deletingReplyIds.contains(reply.id) else { return }
        deletingReplyIds.insert(reply.id)
        guestbookError = nil
        Task { @MainActor in
            defer { deletingReplyIds.remove(reply.id) }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                try await RankingAPI.shared.deleteGuestbookReply(
                    deviceId: settings.rankingDeviceID, guildId: response.guild.id,
                    replyId: reply.id, hmacKeyBase64: key)
            } catch RankingAPI.RankingError.guildConflict(let code) where code == "reply_not_found" {
                // 이미 없음 — 아래에서 로컬만 정리.
            } catch is CancellationError {
                return
            } catch {
                guestbookError = error.friendlyDescription
                return
            }
            mutateEntry(entry.id) {
                $0.replies = ($0.replies ?? []).filter { $0.id != reply.id }
                $0.replyCount = max(0, ($0.replyCount ?? 1) - 1)
            }
        }
    }

    private func loadAllReplies(_ entry: RankingAPI.GuildGuestbookEntry) {
        guard let response, !loadingReplyIds.contains(entry.id) else { return }
        loadingReplyIds.insert(entry.id)
        Task { @MainActor in
            defer { loadingReplyIds.remove(entry.id) }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                let all = try await RankingAPI.shared.listGuestbookReplies(
                    deviceId: settings.rankingDeviceID, guildId: response.guild.id,
                    entryId: entry.id, hmacKeyBase64: key)
                mutateEntry(entry.id) {
                    $0.replies = all
                    $0.replyCount = all.count
                }
            } catch is CancellationError {
                return
            } catch {
                guestbookError = error.friendlyDescription
            }
        }
    }

    private func submitGuestbook(_ response: RankingAPI.GuildVisitResponse) {
        guard let policy, canSubmit(policy) else { return }
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        posting = true
        guestbookError = nil
        Task { @MainActor in
            defer { posting = false }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                let resp = try await RankingAPI.shared.writeGuestbook(
                    deviceId: settings.rankingDeviceID, guildId: response.guild.id,
                    content: content, hmacKeyBase64: key)
                guestbook.insert(resp.entry, at: 0)
                draft = ""
                // 같은 길드 24h — 서버 재조회 없이 클라 카운트다운을 하루로 시드.
                startCooldown(24 * 3_600)
            } catch RankingAPI.RankingError.rateLimited(let retryAfterSec) {
                startCooldown(retryAfterSec)
                guestbookError = RankingAPI.RankingError.rateLimited(retryAfterSec: retryAfterSec).localizedDescription
            } catch RankingAPI.RankingError.guildConflict(let code) where code == "guestbook_cooldown" {
                startCooldown(24 * 3_600)
                guestbookError = RankingAPI.RankingError.guildConflict(code).localizedDescription
            } catch is CancellationError {
                return
            } catch {
                guestbookError = error.friendlyDescription
            }
        }
    }

    private func deleteEntry(_ entry: RankingAPI.GuildGuestbookEntry) {
        guard let response, !deletingIds.contains(entry.id) else { return }
        deletingIds.insert(entry.id)
        guestbookError = nil
        Task { @MainActor in
            defer { deletingIds.remove(entry.id) }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                try await RankingAPI.shared.deleteGuestbook(
                    deviceId: settings.rankingDeviceID, guildId: response.guild.id,
                    entryId: entry.id, hmacKeyBase64: key)
                guestbook.removeAll { $0.id == entry.id }
            } catch RankingAPI.RankingError.guildConflict(let code) where code == "entry_not_found" {
                guestbook.removeAll { $0.id == entry.id }
            } catch is CancellationError {
                return
            } catch {
                guestbookError = error.friendlyDescription
            }
        }
    }

    private func startCooldown(_ sec: Int) {
        cooldownTask?.cancel()
        cooldownSec = max(0, sec)
        guard cooldownSec > 0 else { return }
        cooldownTask = Task { @MainActor in
            while cooldownSec > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                cooldownSec = max(0, cooldownSec - 1)
            }
        }
    }

    private func applyGuestbook(_ resp: RankingAPI.GuildVisitResponse) {
        guestbook = resp.guestbook ?? []
        policy = resp.guestbookPolicy
        startCooldown(resp.guestbookPolicy?.cooldownRemainingSec ?? 0)
        // 이 길드의 답글을 본 것으로 — 랭킹 탭·길드 스코프·놀러가기 버튼의 점이 꺼진다.
        settings.guestbookReplySeen[resp.guild.id.lowercased()] = Date()
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk").font(.system(size: 12))
            Text("\(response?.guild.name ?? guildName) 놀러가기")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button("닫기") { dismiss() }
                .font(.system(size: 11))
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// 로고 · 이름 · 이번 달 순위/점수 · 인원. 내 길드면 배지.
    private func header(_ guild: RankingAPI.GuildVisitGuild) -> some View {
        HStack(spacing: 10) {
            GuildLogoBanner(logo: guild.logo, guildID: guild.id, width: 72)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(guild.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if guild.isMine {
                        Text("내 길드")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill").foregroundStyle(.yellow).font(.system(size: 10))
                    if let rank = guild.rank {
                        Text("이번 달 \(rank)위").font(.system(size: 11, weight: .semibold))
                    } else {
                        Text("이번 달 순위 없음").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("\(guild.score) VP")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.purple)
                }
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill").font(.system(size: 8))
                    Text("\(guild.memberCount)명").font(.system(size: 10))
                    Text("· \(Self.formatCreated(guild.createdAt)) 창설").font(.system(size: 10))
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.purple.opacity(0.07)))
    }

    /// 읽기 전용 사무실 + 방문객 펫. 콜백은 전부 no-op — 방문자는 아무것도 바꿀 수 없다.
    private func officeSection(_ response: RankingAPI.GuildVisitResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GuildOfficeView(
                info: response.asInfoResponse,
                rearrangeMode: .constant(false),
                previewFloorTheme: .constant(nil),
                previewWallTheme: .constant(nil),
                onSetFurniture: { _ in },
                onSetLogoPos: { _, _ in },
                onBuyFurniture: { _, _ in },
                onPlaceDecor: { _, _ in },
                onRemoveDecor: { _ in },
                onApplyTheme: {},
                guest: guest,
                purchaseSheetOpen: .constant(false)
            )
            Text("내 대표 펫이 놀러가 있어요. 펫을 클릭하면 이름이 보여요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// 멤버 칩 — 대표 펫 + 닉네임 (+★ 기여자 / 👑 길드장). 트레이너 카드는 일부러 열지 않는다:
    /// 방문 응답은 profileJson을 싣지 않는다 (Egress — guild-visit.md §1).
    private func membersSection(_ response: RankingAPI.GuildVisitResponse) -> some View {
        let members = response.members.sorted {
            if $0.isLeader != $1.isLeader { return $0.isLeader }
            if $0.isTopContributor != $1.isTopContributor { return $0.isTopContributor }
            if $0.monthlyVP != $1.monthlyVP { return $0.monthlyVP > $1.monthlyVP }
            return $0.nickname < $1.nickname
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("멤버").font(.system(size: 12, weight: .semibold))
                Text("★ = 길드 점수 반영 중").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(members) { member in
                    memberChip(member)
                }
            }
        }
    }

    private func memberChip(_ member: RankingAPI.GuildMember) -> some View {
        let avatar = member.officeAvatar
        return HStack(spacing: 5) {
            if let frame = PetSprite.image(for: avatar.kind, action: .walk, frameIndex: 0) {
                Image(nsImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .hueRotation(.degrees(avatar.variant == PetOwnership.prestigeVariant
                        ? 0 : WalkingCat.hueDegrees(for: avatar.variant)))
                    .scaleEffect(x: avatar.kind.defaultFacingLeft ? -1 : 1, y: 1)
                    .frame(width: 22, height: 20)
            }
            if member.isLeader { Text("👑").font(.system(size: 9)) }
            Text(member.nickname).font(.system(size: 11)).lineLimit(1)
            if member.isTopContributor {
                Text("★").font(.system(size: 9)).foregroundStyle(.yellow)
            }
            Text("\(member.monthlyVP)")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.purple.opacity(0.8))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(member.isMe ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.1)))
        .help("\(member.nickname) · 이번 달 \(member.monthlyVP) VP")
    }

    private func load() {
        if let preloaded {
            response = preloaded
            applyGuestbook(preloaded)
            return
        }
        guard response == nil, !loading else { return }
        guard RankingAPI.isConfigured, settings.rankingRegistered else {
            error = "랭킹 참여 후 다른 길드를 방문할 수 있어요."
            return
        }
        loading = true
        Task { @MainActor in
            defer { loading = false }
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                let resp = try await RankingAPI.shared.visitGuild(
                    deviceId: settings.rankingDeviceID, guildId: guildId, hmacKeyBase64: key)
                response = resp
                applyGuestbook(resp)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.friendlyDescription
            }
        }
    }

    private static func formatCreated(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy.M.d"
        return f.string(from: date)
    }
}

// MARK: - DEBUG 데모 (`AIUSAGE_VISIT_DEMO=1 swift run`)

#if DEBUG
/// 서버 없이 mock 길드·방명록으로 방문 시트를 띄운다. 방문객 펫 입장 연출·방명록 작성창·삭제
/// 버튼·쿨다운 문구를 눈으로 확인하는 용도. 작성/삭제는 서버를 치므로 데모에선 실패 문구가 뜬다.
/// 릴리스 빌드 미포함.
@MainActor
enum GuildVisitDemo {
    private static var window: NSWindow?

    static func present() {
        func member(_ nick: String, kind: PetKind, variant: Int = 0, vp: Int, top: Bool,
                    leader: Bool = false, effects: [String] = []) -> RankingAPI.GuildMember {
            RankingAPI.GuildMember(
                nickname: nick, monthlyVP: vp, isTopContributor: top, officeSlot: nil,
                isLeader: leader, isMe: false, joinedAt: Date(), githubLogin: nil,
                profileJson: nil, deviceId: nil,
                petKind: kind.rawValue, petVariant: variant, equippedEffects: effects)
        }
        let members = [
            member("kimcoder", kind: .warrior, vp: 2400, top: true, leader: true, effects: ["flag"]),
            member("vibewolf", kind: .wolf, variant: 4, vp: 1800, top: true),
            member("nightowl", kind: .whale, vp: 700, top: true, effects: ["glow"]),
            member("lurker42", kind: .ninjaFrog, vp: 400, top: true),
            member("ghostdev", kind: .slime, vp: 0, top: false),
            member("newbie", kind: .pawn, vp: 120, top: false),
        ]
        let now = Date()
        func reply(_ id: Int, _ nick: String, _ kind: PetKind, _ text: String,
                   minutesAgo: Double, mine: Bool = false) -> RankingAPI.GuildGuestbookReply {
            RankingAPI.GuildGuestbookReply(
                id: id, nickname: nick, petKind: kind.rawValue, petVariant: 0,
                content: text, createdAt: now.addingTimeInterval(-minutesAgo * 60), isMine: mine)
        }
        func entry(_ id: Int, _ nick: String, _ guild: String?, _ kind: PetKind, _ text: String,
                   minutesAgo: Double, mine: Bool = false,
                   replies: [RankingAPI.GuildGuestbookReply] = [], replyCount: Int? = nil)
            -> RankingAPI.GuildGuestbookEntry {
            RankingAPI.GuildGuestbookEntry(
                id: id, nickname: nick, guildName: guild, petKind: kind.rawValue, petVariant: 0,
                content: text, createdAt: now.addingTimeInterval(-minutesAgo * 60), isMine: mine,
                replies: replies, replyCount: replyCount ?? replies.count)
        }
        let guestbook = [
            entry(5, "pipelinepete", "It's Always DNS", .whale, "사무실 좋네요, 커피머신 부럽다 ☕", minutesAgo: 2, mine: true,
                  replies: [reply(11, "kimcoder", .warrior, "커피는 셀프입니다 ☕", minutesAgo: 1),
                            reply(12, "pipelinepete", .whale, "ㅋㅋ 다음에 원두 들고 올게요", minutesAgo: 0.5, mine: true)]),
            entry(4, "nullpointer", "Works on My Machine", .slime, "놀러왔다 감. 다음 달 1위는 우리 거", minutesAgo: 40,
                  replies: [reply(13, "vibewolf", .wolf, "어림도 없지", minutesAgo: 30)], replyCount: 5),
            entry(3, "yamlwrangler", nil, .fox, "무소속인데 구경 잘 했습니다 👋", minutesAgo: 180),
            entry(2, "cronjobkim", "--no-verify", .wolf, "액자 문구 웃기네요 ㅋㅋ", minutesAgo: 900),
            entry(1, "gitblame", "It's Always DNS", .ninjaFrog, "화분에 물 좀 주세요", minutesAgo: 3000),
        ]
        let furniture = [
            RankingAPI.GuildFurnitureItem(slotId: 0, itemKind: "SMALL_PAINTING", donorNickname: "kimcoder"),
            RankingAPI.GuildFurnitureItem(slotId: 6, itemKind: "CACTUS", donorNickname: "vibewolf"),
        ]
        let visit = RankingAPI.GuildVisitResponse(
            guild: RankingAPI.GuildVisitGuild(
                id: "demo-guild", name: "데드락클럽", floorTheme: 2, wallTheme: 1,
                officeFurniture: nil, logo: GuildLogo.encode(sample: 4), logoX: nil, logoY: nil,
                createdAt: now.addingTimeInterval(-86_400 * 200), score: 8_420, rank: 3,
                memberCount: members.count, isMine: false),
            members: members, furniture: furniture,
            guestbook: guestbook,
            guestbookPolicy: RankingAPI.GuildGuestbookPolicy(
                canWrite: true, maxLen: 60, cooldownRemainingSec: 0, deleteWindowSec: 300,
                requiresGitHub: true, canInteract: true, isLeader: false))

        let root = GuildVisitView(guildId: visit.guild.id, guildName: visit.guild.name, preloaded: visit)
        let w = NSWindow(contentViewController: NSHostingController(rootView: root))
        // 시트의 maxHeight(700)까지 펼쳐 방명록이 스크롤 없이 보이게 — 실사용 시트와 같은 폭.
        w.setContentSize(NSSize(width: 540, height: 700))
        w.title = "길드 방문 데모"
        w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // 캡처 자동화용 — `screencapture -l<이 번호>` (GuildOfficeDemo와 동일).
        print("VISIT_DEMO_WINDOW=\(w.windowNumber)")
        fflush(stdout)
    }
}
#endif
