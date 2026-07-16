import AppKit
import SwiftUI

/// 길드 탭 — 트레이너 그룹 (docs/plans/guild.md).
/// `GachaView`의 .guild 탭에 임베드, `RankingView`와 동일 패턴 (게이트 + 5분 자동 새로고침).
///
/// 상태 4단계: 빌드 미구성 → 랭킹 미등록 → 미가입(온보딩: 창설/코드 가입)
/// → 가입(내 길드: 사무실 씬 + 점수·멤버·초대 코드).
/// 길드 랭킹 리스트·시상대는 랭킹 탭 → 길드 스코프로 이동 (GuildLeaderboardView).
struct GuildView: View {
    @ObservedObject var settings = Settings.shared

    @State private var info: RankingAPI.GuildInfoResponse?
    /// guild-info가 not_in_guild를 반환 — 온보딩 화면 분기. 최초 로딩(nil 상태)과 구분용.
    @State private var notInGuild: Bool = false
    @State private var loading: Bool = false
    @State private var error: String?
    @State private var refreshTask: Task<Void, Never>?
    @State private var actionBusy: Bool = false

    // 온보딩 입력
    @State private var guildNameDraft: String = ""
    @State private var inviteCodeDraft: String = ""
    /// 서버가 알려준 재가입 쿨다운 만료 시각 — 가입/창설 버튼 비활성 + 안내.
    @State private var cooldownUntil: Date?

    // 초대 (푸시)
    /// 길드장이 초대할 닉네임 입력.
    @State private var inviteNicknameDraft: String = ""

    // 길드명 변경 (길드장, RP 300)
    @State private var renameNameDraft: String = ""
    @State private var confirmingRename: Bool = false

    // 확인 다이얼로그
    @State private var confirmingPermitPurchase: Bool = false
    @State private var confirmingCreate: Bool = false
    @State private var confirmingLeave: Bool = false
    @State private var confirmingDisband: Bool = false
    @State private var confirmingDisbandFinal: Bool = false
    @State private var kickTarget: RankingAPI.GuildMember?
    @State private var copiedCode: Bool = false
    /// 가구 재배치 모드 (길드장) — 가구를 드래그로 자유 이동.
    @State private var rearrangeMode: Bool = false
    /// 테마 미리보기 (구매 확인 전) — 스와치 클릭 시 씬에만 적용, "구매"를 눌러야 결제.
    @State private var previewFloorTheme: Int?
    @State private var previewWallTheme: Int?
    /// 가구 구매 카탈로그 popover — "가구 구매" 버튼이 재배치 진입과 함께 연다.
    @State private var purchaseSheetOpen = false

    /// 온보딩 "길드 둘러보기" 리스트 (guild-leaderboard) + 내가 보낸 가입신청.
    @State private var browseGuilds: [RankingAPI.GuildLeaderboardEntry] = []
    @State private var myRequests: [RankingAPI.GuildOutgoingRequest] = []
    @State private var browseLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !RankingAPI.isConfigured {
                placeholderView("랭킹 기능이 이 빌드에 포함되지 않았습니다.")
            } else if !settings.rankingRegistered {
                registerPrompt
            } else if let info {
                memberContent(info)
            } else if notInGuild {
                onboarding
            } else if let error {
                placeholderView(error)
            } else {
                placeholderView("불러오는 중…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
        .alert("생성권 구매", isPresented: $confirmingPermitPurchase) {
            Button("구매 (\(CoinLedger.guildPermitCost) 코인)") { performPermitPurchase() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("길드 생성권 1장을 \(CoinLedger.guildPermitCost) 코인으로 구매합니다. 생성권은 길드 창설 성공 시에만 소모됩니다.")
        }
        .alert("길드 창설", isPresented: $confirmingCreate) {
            Button("창설 (🎫 1)") { performCreate() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("\"\(guildNameDraft.trimmingCharacters(in: .whitespaces))\" 길드를 만듭니다. 생성권 1장이 소모되며, 길드장이 됩니다.")
        }
        .alert("길드 탈퇴", isPresented: $confirmingLeave) {
            Button("탈퇴", role: .destructive) { performLeave() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("탈퇴 후 7일 동안 다른 길드에 가입하거나 새 길드를 만들 수 없습니다.")
        }
        .alert("길드 해체", isPresented: $confirmingDisband) {
            Button("계속", role: .destructive) { confirmingDisbandFinal = true }
            Button("취소", role: .cancel) {}
        } message: {
            Text("길드를 해체하면 모든 멤버가 흩어지고 되돌릴 수 없습니다.")
        }
        .alert("정말 해체할까요?", isPresented: $confirmingDisbandFinal) {
            Button("해체", role: .destructive) { performDisband() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("마지막 확인입니다. \"\(info?.guild.name ?? "")\" 길드가 영구히 사라집니다.")
        }
        .alert("멤버 추방", isPresented: Binding(
            get: { kickTarget != nil },
            set: { if !$0 { kickTarget = nil } }
        )) {
            Button("추방", role: .destructive) { performKick() }
            Button("취소", role: .cancel) { kickTarget = nil }
        } message: {
            Text("\(kickTarget?.nickname ?? "")님을 추방합니다. 추방된 멤버는 7일 동안 재가입할 수 없습니다.")
        }
        .alert("길드명 변경", isPresented: $confirmingRename) {
            Button("변경 (RP \(RankPointLedger.guildRenameCostRP))") {
                performRename(current: info?.guild.name ?? "")
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("길드명을 \"\(renameNameDraft.trimmingCharacters(in: .whitespaces))\"(으)로 변경합니다. RP \(RankPointLedger.guildRenameCostRP)이 소모됩니다.")
        }
    }

    // MARK: - 헤더

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(.teal)
            Text(info?.guild.name ?? "길드").font(.system(size: 14, weight: .semibold))
            if info?.guild.isLeader == true {
                Text("👑").font(.system(size: 12)).help("길드장")
            }
            if let count = info?.guild.memberCount {
                Text("· \(count)명").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if loading || actionBusy {
                ProgressView().controlSize(.small)
            } else {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("새로고침")
            }
        }
        .padding(12)
    }

    private func placeholderView(_ msg: String) -> some View {
        GateMessageView(icon: "shield.lefthalf.filled", message: msg)
    }

    /// 랭킹 미등록 게이트 — 길드는 랭킹 참여자 전용.
    private var registerPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 28)).foregroundStyle(.secondary)
            Text("길드는 랭킹 참여자 전용입니다.\n설정 → 랭킹에서 참여를 시작하세요.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 온보딩 (미가입)

    private var onboarding: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("트레이너들과 길드를 결성해 월간 랭킹에 도전하세요. 길드 점수는 멤버 중 이번 달 VP 상위 5명의 합산입니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let until = cooldownUntil, until > Date() {
                    cooldownBanner(until)
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 12) {
                    createCard
                    joinCard
                }

                Divider()
                browseSection

                Text("받은 길드 초대는 상단 ✉️ 쪽지함에서 확인·수락할 수 있어요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    // MARK: - 길드 둘러보기 · 가입신청 (온보딩)

    /// 가입신청 대상 길드 리스트 + 내가 보낸 신청(취소). 신청하면 길드장이 수락 시 가입된다.
    private var browseSection: some View {
        let requestedIds = Set(myRequests.map { $0.guildId })
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("길드 둘러보기 · 가입신청", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if browseLoading { ProgressView().controlSize(.mini) }
            }
            Text("마음에 드는 길드에 가입을 신청하면 길드장이 수락할 때 가입돼요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            // 내가 보낸 신청 — 대기중. 둘러보기 리스트에 없는 길드도 여기서 취소 가능.
            if !myRequests.isEmpty {
                Text("보낸 신청 \(myRequests.count)건")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(myRequests) { req in
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill").font(.system(size: 9)).foregroundStyle(.teal)
                        Text(req.guildName).font(.system(size: 11)).lineLimit(1)
                        Text("· 대기중").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Button("취소", role: .destructive) { performCancelJoinRequest(req.requestId) }
                            .font(.system(size: 10)).controlSize(.mini).disabled(actionBusy)
                    }
                }
                Divider().padding(.vertical, 2)
            }

            if browseGuilds.isEmpty {
                if !browseLoading {
                    Text("아직 둘러볼 길드가 없어요. 직접 창설해보는 건 어때요?")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                ForEach(browseGuilds) { g in
                    browseRow(g, alreadyRequested: requestedIds.contains(g.guildId))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.teal.opacity(0.06)))
    }

    private func browseRow(_ g: RankingAPI.GuildLeaderboardEntry, alreadyRequested: Bool) -> some View {
        HStack(spacing: 8) {
            Text("\(g.rank)")
                .font(.system(size: 11, weight: g.rank <= 3 ? .bold : .regular))
                .monospacedDigit().frame(width: 20, alignment: .trailing)
            Text(g.name).font(.system(size: 11)).lineLimit(1)
            Text("\(g.memberCount)명").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Text("\(g.score) VP").font(.system(size: 10, design: .monospaced)).foregroundStyle(.purple)
            if alreadyRequested {
                Text("신청됨").font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
            } else {
                Button("신청") { performSendJoinRequest(g.guildId) }
                    .font(.system(size: 10)).controlSize(.small)
                    .disabled(actionBusy || isCoolingDown)
            }
        }
        .padding(.vertical, 2)
    }

    private func cooldownBanner(_ until: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass").font(.system(size: 11))
            Text("탈퇴/추방 후 재가입 쿨다운 — \(formatCooldownRemaining(until)) 남음")
                .font(.system(size: 11))
        }
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.orange.opacity(0.1)))
    }

    /// 창설 카드 — 생성권 보유 여부로 2단 변신 (구매 → 창설).
    private var createCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("길드 창설", systemImage: "flag.fill")
                .font(.system(size: 12, weight: .semibold))
            if settings.guildPermits > 0 {
                Text("🎫 생성권 \(settings.guildPermits)장 보유")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("길드 이름 (2~24자)", text: $guildNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button {
                    confirmingCreate = true
                } label: {
                    Label("길드 창설 · 🎫 1", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!isValidGuildNameDraft || actionBusy || isCoolingDown)
            } else {
                Text("길드를 만들려면 생성권이 필요합니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    confirmingPermitPurchase = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "ticket.fill")
                        Text("생성권 구매 ·")
                        CoinIcon(size: 12)
                        Text("\(CoinLedger.guildPermitCost)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(settings.coins < CoinLedger.guildPermitCost || actionBusy)
                if settings.coins < CoinLedger.guildPermitCost {
                    Text("코인 부족 — \(CoinLedger.guildPermitCost - settings.coins) 코인 더 필요")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.gray.opacity(0.08)))
    }

    /// 초대 코드 가입 카드.
    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("코드로 가입", systemImage: "envelope.open.fill")
                .font(.system(size: 12, weight: .semibold))
            Text("길드장에게 받은 8자리 초대 코드를 입력하세요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("초대 코드", text: $inviteCodeDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onChange(of: inviteCodeDraft) { newValue in
                    // 8자 영숫자 대문자로 정규화 — 서버 발급 형식과 일치.
                    let cleaned = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(8))
                    if cleaned != newValue { inviteCodeDraft = cleaned }
                }
            Button {
                performJoin()
            } label: {
                Label("가입하기", systemImage: "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .disabled(inviteCodeDraft.count != 8 || actionBusy || isCoolingDown)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.gray.opacity(0.08)))
    }

    // MARK: - 멤버 초대 (길드장, 내 길드)

    /// 닉네임으로 초대 발송 + 보낸 대기중 초대 목록(취소).
    private func inviteSection(_ info: RankingAPI.GuildInfoResponse) -> some View {
        let sent = info.sentInvites ?? []
        return VStack(alignment: .leading, spacing: 6) {
            Label("멤버 초대", systemImage: "person.crop.circle.badge.plus")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                TextField("초대할 트레이너 닉네임", text: $inviteNicknameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { if canSendInvite { performSendInvite() } }
                Button("초대") { performSendInvite() }
                    .font(.system(size: 11))
                    .disabled(!canSendInvite || actionBusy)
            }
            Text("가입 가능한 트레이너(무소속·재가입 쿨다운 없음)만 초대할 수 있어요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !sent.isEmpty {
                Divider().padding(.vertical, 2)
                Text("보낸 초대 \(sent.count)건").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(sent) { inv in
                    HStack(spacing: 6) {
                        Text(inv.nickname ?? "(알 수 없음)").font(.system(size: 11)).lineLimit(1)
                        Text("· 대기중").font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer()
                        Button("취소", role: .destructive) { performCancelInvite(inv.inviteId) }
                            .font(.system(size: 10)).controlSize(.mini)
                            .disabled(actionBusy)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.teal.opacity(0.06)))
    }

    private var canSendInvite: Bool {
        inviteNicknameDraft.trimmingCharacters(in: .whitespaces).count >= 3
    }

    // MARK: - 가입신청 수신함 (길드장, 내 길드)

    /// 받은 가입신청 목록 — 신청자 대표펫 + 닉네임 + 수락/거절. 대기중 신청이 없으면 숨김.
    @ViewBuilder
    private func requestsSection(_ info: RankingAPI.GuildInfoResponse) -> some View {
        let requests = info.joinRequests ?? []
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("가입신청 \(requests.count)건", systemImage: "person.fill.questionmark")
                    .font(.system(size: 12, weight: .semibold))
                Text("가입을 신청한 트레이너입니다. 수락하면 바로 멤버가 됩니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(requests) { req in
                    HStack(spacing: 8) {
                        requestAvatar(req)
                        Text(req.nickname ?? "(알 수 없음)").font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button("수락") { performApproveRequest(req.requestId) }
                            .font(.system(size: 10)).controlSize(.small).disabled(actionBusy)
                        Button("거절", role: .destructive) { performRejectRequest(req.requestId) }
                            .font(.system(size: 10)).controlSize(.small).disabled(actionBusy)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.orange.opacity(0.07)))
        }
    }

    /// 신청자 대표펫 아바타 — 프로필 스냅샷에서 렌더 (없으면 사람 아이콘). 시상대 아바타와 동일 규약.
    @ViewBuilder
    private func requestAvatar(_ req: RankingAPI.GuildIncomingRequest) -> some View {
        if let sel = req.profileJson?.card.avatar,
           let img = PetSprite.image(for: sel.kind, action: .walk, frameIndex: 0) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(sel.variant == PetOwnership.prestigeVariant
                    ? 0 : WalkingCat.hueDegrees(for: sel.variant)))
                .scaleEffect(x: sel.kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    // MARK: - 길드명 변경 (길드장, RP 300)

    /// 새 길드명 입력 + 변경 버튼. 서버가 유일성·형식을 검증하고, 성공 시 RP를 차감한다.
    private func renameSection(_ guild: RankingAPI.GuildInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("길드명 변경", systemImage: "pencil")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                TextField(guild.name, text: $renameNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { if canRename(current: guild.name) { confirmingRename = true } }
                Button {
                    confirmingRename = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.cyan)
                        Text("변경 · \(RankPointLedger.guildRenameCostRP)")
                    }
                }
                .font(.system(size: 11))
                .disabled(!canRename(current: guild.name) || actionBusy)
            }
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(.cyan)
                Text("보유 RP \(settings.rp) · 변경에 \(RankPointLedger.guildRenameCostRP) RP 소모 (2~24자)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if settings.rp < RankPointLedger.guildRenameCostRP {
                Text("RP 부족 — \(RankPointLedger.guildRenameCostRP - settings.rp) RP 더 필요")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.cyan.opacity(0.06)))
    }

    /// 변경 가능 조건 — 2~24자 + 현재 이름과 다름 + RP 충분. 최종 형식은 서버가 검증.
    private func canRename(current: String) -> Bool {
        let t = renameNameDraft.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 24, t != current else { return false }
        return settings.rp >= RankPointLedger.guildRenameCostRP
    }

    private var isValidGuildNameDraft: Bool {
        let t = guildNameDraft.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.count <= 24
    }

    private var isCoolingDown: Bool {
        if let until = cooldownUntil { return until > Date() }
        return false
    }

    // MARK: - 내 길드 (가입)

    private func memberContent(_ info: RankingAPI.GuildInfoResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                scoreBanner(info.guild)
                officeSection(info)
                Divider()
                membersSection(info)
                Divider()
                inviteCodeSection(info.guild)
                if info.guild.isLeader {
                    requestsSection(info)
                    inviteSection(info)
                    renameSection(info.guild)
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
            .padding(14)
        }
    }

    private func scoreBanner(_ guild: RankingAPI.GuildInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trophy.fill").foregroundStyle(.yellow).font(.system(size: 12))
            if let rank = guild.rank {
                Text("이번 달 \(rank)위").font(.system(size: 12, weight: .semibold))
            }
            Text("\(guild.score) VP").font(.system(size: 12, design: .monospaced)).foregroundStyle(.purple)
            Text("(상위 5명 합산)").font(.system(size: 10)).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: AppRadius.md).fill(Color.purple.opacity(0.07)))
    }

    /// 사무실 씬 + 재배치/상점 컨트롤. 멤버 배치는 자동(클라이언트 결정적 해시)이라
    /// 서버 왕복이 없고, 가구 재배치·데코·테마만 서버 반영 후 refresh로 재정합.
    /// 꾸미기 모드는 폐기 — 장식·테마 구매는 상점 시트로 통합 (사용자 피드백).
    private func officeSection(_ info: RankingAPI.GuildInfoResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GuildOfficeView(
                info: info,
                rearrangeMode: $rearrangeMode,
                previewFloorTheme: $previewFloorTheme,
                previewWallTheme: $previewWallTheme,
                onSetFurniture: { serialized in
                    performSetFurniture(serialized)
                },
                onBuyFurniture: { kind, serialized in
                    performBuyFurniture(kind, serialized: serialized)
                },
                onPlaceDecor: { slot, item in
                    performPlaceDecor(slot: slot, item: item)
                },
                onRemoveDecor: { slot in
                    performRemoveDecor(slot: slot)
                },
                onApplyTheme: {
                    performApplyThemePreview()
                },
                purchaseSheetOpen: $purchaseSheetOpen
            )
            HStack(spacing: 8) {
                if info.guild.isLeader {
                    Button(rearrangeMode ? "재배치 종료" : "가구 재배치") {
                        clearThemePreview()
                        rearrangeMode.toggle()
                    }
                    .font(.system(size: 11))
                    .disabled(actionBusy)
                }
                Button {
                    // 길드장은 재배치 모드와 함께 열어 구매 직후 바로 드래그 배치 가능.
                    if info.guild.isLeader { rearrangeMode = true }
                    purchaseSheetOpen = true
                } label: {
                    HStack(spacing: 4) {
                        CoinIcon(size: 12)
                        Text("사무실 상점")
                    }
                }
                .font(.system(size: 11))
                .disabled(actionBusy)
                if rearrangeMode {
                    Text("드래그로 이동 · 액자는 클릭해 문구 입력")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func clearThemePreview() {
        previewFloorTheme = nil
        previewWallTheme = nil
    }

    private func membersSection(_ info: RankingAPI.GuildInfoResponse) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("멤버 (이번 달 기여순)").font(.system(size: 12, weight: .semibold))
                Text("★ = 길드 점수 반영 중").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 2)
            ForEach(sortedMembers(info.members)) { member in
                GuildMemberRow(
                    member: member,
                    canKick: info.guild.isLeader && !member.isMe && member.deviceId != nil,
                    onKick: { kickTarget = member }
                )
                Divider().opacity(0.4)
            }
        }
    }

    /// 기여 VP 내림차순 → 가입 오래된 순. 서버 rn과 동일한 감각의 표시 순서.
    private func sortedMembers(_ members: [RankingAPI.GuildMember]) -> [RankingAPI.GuildMember] {
        members.sorted {
            if $0.monthlyVP != $1.monthlyVP { return $0.monthlyVP > $1.monthlyVP }
            return $0.joinedAt < $1.joinedAt
        }
    }

    private func inviteCodeSection(_ guild: RankingAPI.GuildInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("초대 코드").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                Text(guild.inviteCode)
                    .font(.system(size: 13, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: AppRadius.sm).fill(Color.gray.opacity(0.12)))
                Button(copiedCode ? "복사됨 ✓" : "복사") { copyInviteCode(guild.inviteCode) }
                    .font(.system(size: 11))
                if guild.isLeader {
                    Button("재발급") { performRotateCode() }
                        .font(.system(size: 11))
                        .disabled(actionBusy)
                        .help("코드가 유출됐을 때 — 기존 코드는 즉시 무효화됩니다.")
                }
                Spacer()
            }
            HStack {
                Button("길드 탈퇴", role: .destructive) { confirmingLeave = true }
                    .font(.system(size: 11))
                    .disabled(actionBusy)
                Spacer()
                if guild.isLeader {
                    Button("길드 해체", role: .destructive) { confirmingDisband = true }
                        .font(.system(size: 11))
                        .disabled(actionBusy)
                }
            }
        }
    }

    // MARK: - 액션

    private func startAutoRefresh() {
        refresh()
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if Task.isCancelled { break }
                refresh()
            }
        }
    }

    private func refresh() {
        guard RankingAPI.isConfigured, settings.rankingRegistered else { return }
        loading = true
        error = nil
        Task { @MainActor in
            defer { loading = false }
            let deviceId = settings.rankingDeviceID
            let key = Keychain.loadRankingHmacKey() ?? ""
            do {
                let resp = try await RankingAPI.shared.fetchGuildInfo(deviceId: deviceId, hmacKeyBase64: key)
                info = resp
                notInGuild = false
                cooldownUntil = nil
                // 가입 완료 → 온보딩 둘러보기 데이터는 더 이상 불필요.
                browseGuilds = []
                myRequests = []
                // 표시 캐시 동기화 — 서버가 SSOT.
                settings.guildID = resp.guild.id
                settings.guildName = resp.guild.name
                settings.isGuildLeader = resp.guild.isLeader
            } catch RankingAPI.RankingError.guildConflict(let code) where code == "not_in_guild" {
                info = nil
                notInGuild = true
                if !settings.guildID.isEmpty {
                    settings.guildID = ""
                    settings.guildName = ""
                    settings.isGuildLeader = false
                }
                // 미가입 → 둘러보기 리스트 + 내가 보낸 신청 로드 (가입신청 UI용).
                await loadOnboardingData(deviceId: deviceId, key: key)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
            // 받은 초대는 통합 인박스(쪽지함, DMViewModel)에서 조회·수락/거절한다.
            // 길드 랭킹 리스트는 랭킹 탭 → 길드 스코프로 이동 (RankingView.guildContent).
        }
    }

    /// 온보딩(미가입) 상태에서 둘러볼 길드 목록 + 내가 보낸 대기중 신청을 병렬 로드.
    /// 실패는 조용히 무시 — 창설/코드 가입 경로는 이 데이터 없이도 동작한다.
    private func loadOnboardingData(deviceId: String, key: String) async {
        browseLoading = true
        defer { browseLoading = false }
        async let boardTask = RankingAPI.shared.fetchGuildLeaderboard(deviceId: deviceId)
        async let reqsTask = RankingAPI.shared.listMyJoinRequests(deviceId: deviceId, hmacKeyBase64: key)
        if let board = try? await boardTask { browseGuilds = board.entries }
        if let reqs = try? await reqsTask { myRequests = reqs }
    }

    private func performPermitPurchase() {
        if !CoinLedger.shared.purchaseGuildPermit() {
            error = "코인이 부족합니다."
        }
    }

    // MARK: - 초대 액션

    /// 길드장 — 닉네임으로 초대 발송. 자격 미달/재초대 쿨다운 등은 friendly 메시지로.
    private func performSendInvite() {
        let nickname = inviteNicknameDraft.trimmingCharacters(in: .whitespaces)
        guard nickname.count >= 3 else { return }
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .invite, targetNickname: nickname,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            inviteNicknameDraft = ""
            DebugLog.log("Guild: 초대 발송 → \(nickname)")
        } mapError: { Self.inviteErrorMessage($0) }
    }

    private func performCancelInvite(_ inviteId: String) {
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .cancelInvite, inviteId: inviteId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
        }
    }

    /// 초대 발송 서버 코드 → 사용자 메시지. 프라이버시상 자격 관련은 하나로 뭉갠다.
    private static func inviteErrorMessage(_ error: Error) -> String? {
        guard case RankingAPI.RankingError.guildConflict(let code) = error else { return nil }
        switch code {
        case "cannot_invite", "cannot_invite_self":
            return "초대할 수 없는 사용자입니다 (없거나 이미 길드에 속했거나 최근 탈퇴)."
        case "already_invited":
            return "이미 초대를 보냈습니다."
        case "redecline_cooldown":
            return "최근 거절한 사용자입니다. 24시간 후 다시 초대할 수 있어요."
        case "too_many_pending":
            return "대기 중인 초대가 너무 많습니다."
        default:
            return nil
        }
    }

    // MARK: - 가입신청 액션

    /// 신청자 — 리스트에서 고른 길드에 가입신청. 중복/쿨다운 등은 friendly 메시지.
    private func performSendJoinRequest(_ guildId: String) {
        runAction {
            _ = try await RankingAPI.shared.sendJoinRequest(
                deviceId: settings.rankingDeviceID, guildId: guildId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 가입신청 발송 → \(guildId)")
        }
    }

    /// 신청자 — 내가 보낸 신청 취소.
    private func performCancelJoinRequest(_ requestId: String) {
        runAction {
            _ = try await RankingAPI.shared.cancelJoinRequest(
                deviceId: settings.rankingDeviceID, requestId: requestId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
        }
    }

    /// 길드장 — 받은 가입신청 수락 → 신청자 편입.
    private func performApproveRequest(_ requestId: String) {
        runAction {
            _ = try await RankingAPI.shared.approveJoinRequest(
                deviceId: settings.rankingDeviceID, requestId: requestId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 가입신청 수락 \(requestId)")
        }
    }

    /// 길드장 — 받은 가입신청 거절.
    private func performRejectRequest(_ requestId: String) {
        runAction {
            _ = try await RankingAPI.shared.rejectJoinRequest(
                deviceId: settings.rankingDeviceID, requestId: requestId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 가입신청 거절 \(requestId)")
        }
    }

    private func performCreate() {
        let name = guildNameDraft.trimmingCharacters(in: .whitespaces)
        guard settings.guildPermits > 0, !name.isEmpty else { return }
        runAction {
            let resp = try await RankingAPI.shared.createGuild(
                deviceId: settings.rankingDeviceID, name: name,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            // 생성권 소모는 서버 성공 응답 후 — 실패 시 보존 (기획 §2).
            settings.guildPermits -= 1
            settings.guildID = resp.guildId
            settings.guildName = resp.name
            settings.isGuildLeader = true
            guildNameDraft = ""
            DebugLog.log("Guild: 창설 [\(resp.name)] — 생성권 1 소모 (잔여 \(settings.guildPermits))")
        }
    }

    private func performJoin() {
        let code = inviteCodeDraft
        guard code.count == 8 else { return }
        runAction {
            let resp = try await RankingAPI.shared.joinGuild(
                deviceId: settings.rankingDeviceID, inviteCode: code,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            inviteCodeDraft = ""
            DebugLog.log("Guild: 가입 [\(resp.name)] (\(resp.memberCount)명)")
        }
    }

    private func performLeave() {
        runAction {
            let resp = try await RankingAPI.shared.leaveGuild(
                deviceId: settings.rankingDeviceID,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            cooldownUntil = resp.cooldownUntil
            settings.guildID = ""
            settings.guildName = ""
            settings.isGuildLeader = false
            DebugLog.log("Guild: 탈퇴 — 재가입 쿨다운 \(resp.cooldownUntil?.description ?? "?")")
        }
    }

    private func performDisband() {
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .disband,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            settings.guildID = ""
            settings.guildName = ""
            settings.isGuildLeader = false
            DebugLog.log("Guild: 해체")
        }
    }

    private func performKick() {
        guard let target = kickTarget, let targetDeviceId = target.deviceId else { return }
        kickTarget = nil
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .kick, targetDeviceId: targetDeviceId,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 추방 [\(target.nickname)]")
        }
    }

    /// 가구 재배치 (길드장) — 드래그 결과 좌표 직렬화를 서버에 반영. refresh가 최신 배치로 재정합.
    private func performSetFurniture(_ serialized: String) {
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .setFurniture, furniture: serialized,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 가구 배치 저장 → \(serialized)")
        }
    }

    /// 데코 기부 구매 (P2b) — 코인 선검증 → 서버 place_decor → 성공 후 차감 (생성권 원칙).
    private func performPlaceDecor(slot: Int, item: OfficeLayout.DecorItem) {
        guard settings.coins >= item.price else {
            error = "코인이 부족합니다 (\(item.price) 필요)."
            return
        }
        runAction {
            _ = try await RankingAPI.shared.placeDecor(
                deviceId: settings.rankingDeviceID, slot: slot, itemKind: item.kind,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            CoinLedger.shared.spendGuildDecor(item.price, item: item.name)
        }
    }

    private func performRemoveDecor(slot: Int) {
        runAction {
            _ = try await RankingAPI.shared.removeDecor(
                deviceId: settings.rankingDeviceID, slot: slot,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 데코 제거 slot=\(slot)")
        }
    }

    /// 미리보기 중인 테마 구매·적용 (길드장, 항목당 2,000코인 — 바닥+벽 동시 미리보기면 2건 결제).
    private func performApplyThemePreview() {
        let purchases: [(kind: String, index: Int)] =
            [previewFloorTheme.map { ("floor", $0) }, previewWallTheme.map { ("wall", $0) }]
                .compactMap { $0 }
        guard !purchases.isEmpty else { return }
        let total = OfficeLayout.themePrice * purchases.count
        guard settings.coins >= total else {
            error = "코인이 부족합니다 (\(total) 필요)."
            return
        }
        clearThemePreview()   // 결제 진행 — refresh가 서버 값을 곧 따라잡는다
        runAction {
            for purchase in purchases {
                _ = try await RankingAPI.shared.setOfficeTheme(
                    deviceId: settings.rankingDeviceID, kind: purchase.kind,
                    themeIndex: purchase.index,
                    hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
                CoinLedger.shared.spendGuildDecor(
                    OfficeLayout.themePrice, item: "테마(\(purchase.kind) \(purchase.index))")
            }
        }
    }

    /// 가구 구매 확정 — 코인 검증 후 새 인스턴스 포함 배치를 서버 반영 + 코인 차감.
    private func performBuyFurniture(_ kind: OfficeLayout.FurnitureKind, serialized: String) {
        guard settings.coins >= kind.price else {
            error = "코인이 부족합니다 (\(kind.price) 필요)."
            return
        }
        runAction {
            _ = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .setFurniture,
                furniture: serialized,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            CoinLedger.shared.spendGuildDecor(kind.price, item: "가구(\(kind.name))")
            DebugLog.log("Guild: 가구 구매 \(kind.name) (\(kind.price)코인)")
        }
    }

    private func performRotateCode() {
        runAction {
            let resp = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .rotateCode,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            DebugLog.log("Guild: 초대 코드 재발급 \(resp.inviteCode ?? "?")")
        }
    }

    /// 길드명 변경 (길드장) — 서버 rename 성공 후 RP 차감 (생성권/데코 원칙: 실패 시 보존).
    /// 이름 충돌은 `.guildConflict("name_taken")` → runAction 기본 처리로 friendly 메시지.
    private func performRename(current: String) {
        let name = renameNameDraft.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, name.count <= 24, name != current else { return }
        guard settings.rp >= RankPointLedger.guildRenameCostRP else {
            error = "RP가 부족합니다 (\(RankPointLedger.guildRenameCostRP) 필요)."
            return
        }
        runAction {
            let resp = try await RankingAPI.shared.manageGuild(
                deviceId: settings.rankingDeviceID, action: .rename, newName: name,
                hmacKeyBase64: Keychain.loadRankingHmacKey() ?? "")
            RankPointLedger.shared.spend(RankPointLedger.guildRenameCostRP, reason: "guild.rename")
            settings.guildName = resp.name ?? name
            renameNameDraft = ""
            DebugLog.log("Guild: 길드명 변경 → \(resp.name ?? name) (RP \(RankPointLedger.guildRenameCostRP) 소모)")
        }
    }

    /// 서버 액션 공통 래퍼 — busy 토글, 쿨다운/에러 수집, 성공·실패 무관 refresh로 재정합.
    /// mapError: 특정 서버 코드를 friendly 메시지로 치환(nil 반환 시 기본 처리로 폴백).
    private func runAction(_ op: @escaping () async throws -> Void,
                           mapError: ((Error) -> String?)? = nil) {
        actionBusy = true
        error = nil
        Task { @MainActor in
            defer { actionBusy = false }
            do {
                try await op()
            } catch RankingAPI.RankingError.guildCooldown(let until) {
                cooldownUntil = until
                self.error = RankingAPI.RankingError.guildCooldown(until: until).localizedDescription
            } catch is CancellationError {
                return
            } catch {
                self.error = mapError?(error) ?? error.localizedDescription
            }
            refresh()
        }
    }

    // MARK: - Helpers

    private func copyInviteCode(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copiedCode = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copiedCode = false
        }
    }

    private func formatCooldownRemaining(_ until: Date) -> String {
        let secs = until.timeIntervalSinceNow
        if secs >= 86_400 { return "\(Int(ceil(secs / 86_400)))일" }
        if secs >= 3_600 { return "\(Int(ceil(secs / 3_600)))시간" }
        return "\(max(1, Int(ceil(secs / 60))))분"
    }
}

// MARK: - 멤버 행 (펫 아바타 + ★ + VP, 호버 시 트레이너 카드)

/// 랭킹 보드 행(LeaderboardRowView)의 길드 변형 — 기여 ★, 길드장/나 태그, 추방 버튼.
@MainActor
private struct GuildMemberRow: View {
    let member: RankingAPI.GuildMember
    let canKick: Bool
    let onKick: () -> Void
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Text(member.isTopContributor ? "★" : " ")
                .font(.system(size: 11))
                .foregroundStyle(.yellow)
                .frame(width: 14)
                .help(member.isTopContributor ? "이번 달 길드 점수에 반영 중" : "")
            avatarIcon
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.nickname)
                        .font(.system(size: 12, weight: member.isMe ? .semibold : .regular))
                        .lineLimit(1)
                    if member.isLeader { Text("👑").font(.system(size: 10)).help("길드장") }
                    if member.isMe {
                        Text("나").font(.system(size: 9))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                }
                if let gh = member.githubLogin {
                    Text("@\(gh)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if canKick && hovering {
                Button("추방", role: .destructive) { onKick() }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text("\(member.monthlyVP) VP")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(member.monthlyVP > 0 ? .purple : .secondary)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(member.isMe ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: Binding(
            get: { hovering && member.profileJson != nil },
            set: { if !$0 { hovering = false } }
        ), arrowEdge: .leading) {
            if let profile = member.profileJson {
                TrainerCardView(
                    card: profile.card,
                    trainerID: profile.trainerID,
                    trainerName: member.nickname,
                    stats: profile.stats,
                    badges: profile.badgeRowsForRender(),
                    collections: profile.collectionRowsForRender(),
                    showWatermark: false,
                    width: 460,
                    medals: nil,
                    animatedAvatar: true,
                    equippedEffects: Set((profile.equippedEffects ?? []).compactMap { EffectKind(rawValue: $0) }),
                    guildName: profile.guildName
                )
                .padding(8)
            }
        }
    }

    /// 대표 펫 아바타 — RankingView 행과 동일한 정적 렌더 (variant hue + 레인보우 틴트).
    @ViewBuilder
    private var avatarIcon: some View {
        if let selection = member.profileJson?.card.avatar,
           let nsImage = PetSprite.image(for: selection.kind, action: .walk, frameIndex: 0) {
            let isRainbow = selection.variant == PetOwnership.prestigeVariant
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .hueRotation(.degrees(isRainbow ? 0 : WalkingCat.hueDegrees(for: selection.variant)))
                .colorMultiply(isRainbow ? WalkingCat.prestigeTint(at: 0) : .white)
                .saturation(selection.variant > 0 ? 1.15 : 1.0)
                .scaleEffect(x: selection.kind.defaultFacingLeft ? -1 : 1, y: 1)
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}
