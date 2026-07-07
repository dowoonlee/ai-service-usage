import AppKit
import SwiftUI

/// 1:1 쪽지 전용 창 (docs/plans/direct-messages.md). E2EE(HPKE) — 본문은 이 기기에서만 복호.
/// 통합 인박스(쪽지 + 받은 길드 초대) · 스레드 · 작성. 랭킹 참여자 전용.

// MARK: - ViewModel

@MainActor
final class DMViewModel: ObservableObject {
    static let shared = DMViewModel()

    @Published var threads: [ThreadRow] = []
    @Published var totalUnread: Int = 0
    @Published var loading = false
    @Published var error: String?
    /// 열려 있는 스레드(peerDevice) → 메시지.
    @Published var openPeer: String?
    @Published var openMessages: [DisplayMessage] = []
    @Published var openPeerNickname: String?
    /// 작성 중 상대 키 변경 경고(닉네임).
    @Published var keyChangeWarning: String?
    /// 외부(랭킹/멤버 목록)의 "쪽지 보내기" 진입 시 작성 시트를 미리 채울 닉네임.
    @Published var pendingComposeNickname: String?
    /// 받은 길드 초대 (통합 인박스 카드). 서버 평문 — 쪽지와 달리 암호화 대상 아님.
    @Published var invites: [RankingAPI.GuildReceivedInvite] = []
    /// 수신 정책(anyone/guild/none) · 차단 목록 (dm-settings).
    @Published var allowFrom: String = "anyone"
    @Published var blocked: [RankingAPI.DMBlockedPeer] = []

    private var didPublishThisSession = false
    private var refreshTask: Task<Void, Never>?

    /// 인박스 행 — 복호/echo로 만든 미리보기 포함.
    struct ThreadRow: Identifiable {
        let peerDevice: String
        let nickname: String
        let preview: String
        let at: Date
        let unread: Int
        let keyChanged: Bool
        var id: String { peerDevice }
    }
    struct DisplayMessage: Identifiable {
        let id: String
        let fromMe: Bool
        let text: String
        let at: Date
        let failed: Bool
    }

    private var device: String { Settings.shared.rankingDeviceID }
    private var hmac: String { Keychain.loadRankingHmacKey() ?? "" }
    private var ready: Bool { RankingAPI.isConfigured && Settings.shared.rankingRegistered && !device.isEmpty }

    /// 무소속일 때만 초대 노출 — 소속 중엔 수락 불가라 숨긴다.
    var visibleInvites: [RankingAPI.GuildReceivedInvite] {
        Settings.shared.guildID.isEmpty ? invites : []
    }
    /// ✉️ 배지 = 미확인 쪽지 + 처리 대기 초대.
    var badgeCount: Int { totalUnread + visibleInvites.count }

    private init() {
        startAutoRefresh()
    }

    func startAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                if ready { await refreshInbox(silent: true) }
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// 내 공개키 게시(세션 1회). 기기 변경 시 새 키라 재게시된다(upsert).
    private func publishKeyIfNeeded() async {
        guard !didPublishThisSession else { return }
        do {
            try await RankingAPI.shared.dmPublishKey(
                deviceId: device, x25519Pub: DMCrypto.identityPublicKeyBase64(), hmacKeyBase64: hmac)
            didPublishThisSession = true
        } catch { /* 다음 시도에서 재게시 */ }
    }

    func refreshInbox(silent: Bool = false) async {
        guard ready else { return }
        if !silent { loading = true; error = nil }
        defer { if !silent { loading = false } }
        await publishKeyIfNeeded()
        do {
            let raw = try await RankingAPI.shared.dmInbox(deviceId: device, hmacKeyBase64: hmac)
            var rows: [ThreadRow] = []
            for t in raw {
                var keyChanged = false
                if let pub = t.peerIdPub {
                    switch DMStore.shared.evaluate(device: t.peerDevice, serverPub: pub) {
                    case .firstUse: DMStore.shared.pin(device: t.peerDevice, pub: pub)
                    case .matches: break
                    case .changed: keyChanged = true
                    }
                }
                let preview = previewText(for: t)
                rows.append(ThreadRow(
                    peerDevice: t.peerDevice, nickname: t.peerNickname ?? "(알 수 없음)",
                    preview: preview, at: t.lastAt, unread: t.unreadCount, keyChanged: keyChanged))
            }
            threads = rows
            totalUnread = rows.reduce(0) { $0 + $1.unread }
        } catch {
            if !silent { self.error = mapError(error) }
        }
        // 받은 길드 초대도 함께 적재 (통합 인박스). 실패는 조용히 무시.
        invites = (try? await RankingAPI.shared.listGuildInvites(
            deviceId: device, hmacKeyBase64: hmac)) ?? []
        // 수신 정책·차단 목록도 갱신 (스레드의 차단 상태 표시에 사용).
        await loadSettings()
    }

    private func previewText(for t: RankingAPI.DMThread) -> String {
        if t.lastFromMe {
            return DMStore.shared.sentText(messageId: t.lastId) ?? "(내가 보낸 메시지)"
        }
        let aad = DMCrypto.aad(senderDevice: t.peerDevice, recipientDevice: device)
        if let text = try? DMCrypto.open(t.lastCiphertext, fromSenderPubBase64: t.lastSenderIdPub, aad: aad) {
            return text
        }
        return "🔒 이 기기에서 복호할 수 없어요"
    }

    func openThread(peer: String) async {
        guard ready else { return }
        if openPeer != peer { openMessages = []; openPeerNickname = nil }  // 다른 상대면 잔상 제거
        openPeer = peer
        error = nil
        await refreshOpenThread(silent: false)
        await refreshInbox(silent: true)   // 인박스 미확인 배지 즉시 반영
    }

    /// 열린 스레드 재로드(복호 + 읽음 처리). 최초 오픈·발신·주기 폴링(뷰 `.task`)에서 재사용.
    func refreshOpenThread(silent: Bool = true) async {
        guard ready, let peer = openPeer else { return }
        do {
            let resp = try await RankingAPI.shared.dmThread(
                deviceId: device, peerDevice: peer, hmacKeyBase64: hmac)
            var msgs: [DisplayMessage] = []
            var latestReceived: Date?
            for m in resp.messages {
                if m.fromMe {
                    let text = DMStore.shared.sentText(messageId: m.id) ?? "(내가 보낸 메시지)"
                    msgs.append(.init(id: m.id, fromMe: true, text: text, at: m.createdAt, failed: false))
                } else {
                    let aad = DMCrypto.aad(senderDevice: peer, recipientDevice: device)
                    if let text = try? DMCrypto.open(m.ciphertext, fromSenderPubBase64: m.senderIdPub, aad: aad) {
                        msgs.append(.init(id: m.id, fromMe: false, text: text, at: m.createdAt, failed: false))
                    } else {
                        msgs.append(.init(id: m.id, fromMe: false, text: "🔒 복호 불가", at: m.createdAt, failed: true))
                    }
                    latestReceived = m.createdAt
                }
            }
            guard openPeer == peer else { return }   // 그 사이 닫히거나 바뀌면 무시
            openPeerNickname = resp.peerNickname
            openMessages = msgs
            if let latest = latestReceived {
                try? await RankingAPI.shared.dmRead(
                    deviceId: device, peerDevice: peer,
                    upToTs: Int64(latest.timeIntervalSince1970) + 1, hmacKeyBase64: hmac)
            }
        } catch {
            if !silent { self.error = mapError(error) }
        }
    }

    func closeThread() {
        openPeer = nil; openMessages = []; openPeerNickname = nil
        Task { await refreshInbox(silent: true) }
    }

    /// 현재 열린 대화를 내 쪽에서 삭제(tombstone). 상대 사본은 유지.
    func deleteThread() async {
        guard ready, let peer = openPeer else { return }
        error = nil
        do {
            try await RankingAPI.shared.dmDeleteThread(
                deviceId: device, peerDevice: peer, hmacKeyBase64: hmac)
            DMStore.shared.removeEchoes(peer: peer)
            closeThread()
        } catch {
            self.error = mapError(error)
        }
    }

    /// 특정 닉네임으로 새 쪽지 작성 시작 (전용 창의 작성 시트가 이 값을 소비).
    func startCompose(to nickname: String) { pendingComposeNickname = nickname }

    /// 새 스레드/답장 발신. trustChangedKey=true면 키 변경 경고를 무시하고 새 키로 고정 후 전송.
    func send(toNickname nickname: String, text: String, trustChangedKey: Bool = false) async {
        guard ready else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        error = nil
        keyChangeWarning = nil
        await publishKeyIfNeeded()
        do {
            let key = try await RankingAPI.shared.dmFetchKey(
                deviceId: device, targetNickname: nickname, hmacKeyBase64: hmac)
            switch DMStore.shared.evaluate(device: key.deviceId, serverPub: key.x25519Pub) {
            case .firstUse, .matches:
                DMStore.shared.pin(device: key.deviceId, pub: key.x25519Pub)
            case .changed:
                if trustChangedKey {
                    DMStore.shared.pin(device: key.deviceId, pub: key.x25519Pub)
                } else {
                    keyChangeWarning = nickname
                    return
                }
            }
            let aad = DMCrypto.aad(senderDevice: device, recipientDevice: key.deviceId)
            let blob = try DMCrypto.seal(body, toRecipientPubBase64: key.x25519Pub, aad: aad)
            let resp = try await RankingAPI.shared.dmSend(
                deviceId: device, targetNickname: nickname, ciphertext: blob,
                senderIdPub: DMCrypto.identityPublicKeyBase64(), hmacKeyBase64: hmac)
            DMStore.shared.recordSent(messageId: resp.id, peer: key.deviceId, text: body,
                                      ts: resp.createdAt.timeIntervalSince1970)
            // 열린 스레드면 즉시 반영, 아니면 인박스 갱신.
            if openPeer == key.deviceId { await openThread(peer: key.deviceId) }
            await refreshInbox(silent: true)
        } catch {
            self.error = mapError(error)
        }
    }

    // MARK: - 길드 초대 (통합 인박스 카드)

    /// 초대 수락 → 해당 길드 가입. 가입 상태를 즉시 로컬 반영해 남은 초대/길드 탭을 곧바로 갱신.
    func acceptInvite(_ inv: RankingAPI.GuildReceivedInvite) async {
        guard ready else { return }
        error = nil
        do {
            let resp = try await RankingAPI.shared.acceptGuildInvite(
                deviceId: device, inviteId: inv.inviteId, hmacKeyBase64: hmac)
            Settings.shared.guildID = resp.guildId
            Settings.shared.guildName = resp.name
            Settings.shared.isGuildLeader = false
            DebugLog.log("DM: 길드 초대 수락 → [\(resp.name)] (\(resp.memberCount)명)")
            await refreshInbox(silent: true)
        } catch {
            self.error = mapInviteError(error)
        }
    }

    /// 초대 거절 (그 길드는 24h 재초대 쿨다운). 목록에서 즉시 제거.
    func declineInvite(_ inv: RankingAPI.GuildReceivedInvite) async {
        guard ready else { return }
        error = nil
        do {
            try await RankingAPI.shared.declineGuildInvite(
                deviceId: device, inviteId: inv.inviteId, hmacKeyBase64: hmac)
            invites.removeAll { $0.inviteId == inv.inviteId }
        } catch {
            self.error = mapInviteError(error)
        }
    }

    private func mapInviteError(_ error: Error) -> String {
        if case RankingAPI.RankingError.guildCooldown = error {
            return "재가입 쿨다운 중에는 수락할 수 없어요."
        }
        if case RankingAPI.RankingError.guildConflict = error {
            return "지금은 이 초대를 처리할 수 없어요 (만료되었거나 이미 처리됨)."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - 수신 정책 · 차단 · 지문

    /// 내 안전 지문 (대역외 검증용, 읽기 전용).
    var myFingerprint: String { DMCrypto.myFingerprint }

    /// 상대 지문 — TOFU 핀된 공개키 기준(교신 이력 있는 상대만).
    func peerFingerprint(for peerDevice: String) -> String? {
        guard let pub = DMStore.shared.pinnedKey(for: peerDevice) else { return nil }
        return DMCrypto.fingerprint(ofPubBase64: pub)
    }

    func loadSettings() async {
        guard ready else { return }
        if let s = try? await RankingAPI.shared.dmGetSettings(deviceId: device, hmacKeyBase64: hmac) {
            allowFrom = s.allowFrom
            blocked = s.blocked
        }
    }

    func setAllowFrom(_ value: String) async {
        guard ready else { return }
        error = nil
        do {
            let s = try await RankingAPI.shared.dmSetAllowFrom(
                deviceId: device, allowFrom: value, hmacKeyBase64: hmac)
            allowFrom = s.allowFrom; blocked = s.blocked
        } catch { self.error = mapError(error) }
    }

    /// 닉네임으로 차단. 성공 시 그 상대는 앞으로 나에게 못 보낸다.
    func block(nickname: String) async {
        guard ready else { return }
        error = nil
        do {
            let s = try await RankingAPI.shared.dmBlock(
                deviceId: device, targetNickname: nickname, hmacKeyBase64: hmac)
            allowFrom = s.allowFrom; blocked = s.blocked
        } catch {
            if case RankingAPI.RankingError.guildConflict(let c) = error, c == "cannot_block" {
                self.error = "차단할 수 없는 사용자입니다."
            } else { self.error = mapError(error) }
        }
    }

    func unblock(device dev: String) async {
        guard ready else { return }
        error = nil
        do {
            let s = try await RankingAPI.shared.dmUnblock(
                deviceId: device, targetDevice: dev, hmacKeyBase64: hmac)
            allowFrom = s.allowFrom; blocked = s.blocked
        } catch { self.error = mapError(error) }
    }

    /// 내가 이 상대를 차단했는지 (스레드/인박스 표시용).
    func isBlocked(_ peerDevice: String) -> Bool {
        blocked.contains { $0.device.lowercased() == peerDevice.lowercased() }
    }

    private func mapError(_ error: Error) -> String {
        if case RankingAPI.RankingError.guildConflict(let code) = error {
            switch code {
            case "cannot_send", "cannot_send_self": return "보낼 수 없는 상대입니다."
            case "no_key": return "상대가 아직 쪽지를 시작하지 않았어요. (상대가 v0.15.0으로 업데이트한 뒤 쪽지함을 한 번 열어야 받을 수 있어요)"
            default: break
            }
        }
        // 발신 한도(429)는 게시판과 코드를 공유해 rateLimited로 들어온다 — DM 문구로 덮어씀.
        if case RankingAPI.RankingError.rateLimited = error {
            return "잠시 후 다시 시도해 주세요 (발신 한도)."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - 창

@MainActor
final class DMWindowController: NSWindowController {
    static let shared = DMWindowController()

    private convenience init() {
        let host = NSHostingController(rootView: DMRootView())
        let window = NSWindow(contentViewController: host)
        window.title = "쪽지"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 400, height: 520))
        window.minSize = NSSize(width: 360, height: 420)
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        Task { await DMViewModel.shared.refreshInbox() }
    }

    /// 특정 닉네임에게 바로 쪽지 작성 (랭킹/멤버 목록의 "쪽지 보내기").
    func present(composeTo nickname: String) {
        DMViewModel.shared.startCompose(to: nickname)
        present()
    }
}

// MARK: - 루트 (인박스 ↔ 스레드)

private struct DMRootView: View {
    @ObservedObject var vm = DMViewModel.shared
    @ObservedObject var settings = Settings.shared
    @State private var composing = false
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if !RankingAPI.isConfigured {
                placeholder("쪽지 기능이 이 빌드에 포함되지 않았습니다.")
            } else if !settings.rankingRegistered {
                placeholder("설정 → 랭킹에서 참여를 시작하세요.")
            } else if vm.openPeer != nil {
                DMThreadView(vm: vm)
            } else {
                DMInboxView(vm: vm, composing: $composing, showingSettings: $showingSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $composing) {
            DMComposeView(vm: vm, initialNickname: vm.pendingComposeNickname ?? "") {
                composing = false
                vm.pendingComposeNickname = nil
            }
        }
        .sheet(isPresented: $showingSettings) {
            DMSettingsView(vm: vm) { showingSettings = false }
        }
        .onAppear {
            Task { await vm.refreshInbox() }
            if vm.pendingComposeNickname != nil { composing = true }
        }
        .onChange(of: vm.pendingComposeNickname) { nick in
            if nick != nil { composing = true }
        }
    }

    private func placeholder(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 인박스

private struct DMInboxView: View {
    @ObservedObject var vm: DMViewModel
    @Binding var composing: Bool
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("쪽지").font(.system(size: 14, weight: .semibold))
                Spacer()
                if vm.loading { ProgressView().controlSize(.small) }
                Button { composing = true } label: { Label("새 쪽지", systemImage: "square.and.pencil") }
                    .font(.system(size: 11))
                Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("쪽지 설정 · 차단 · 지문")
            }
            .padding(12)
            Divider()
            if let error = vm.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(10)
            }
            if vm.threads.isEmpty && vm.visibleInvites.isEmpty {
                Spacer()
                Text("아직 쪽지가 없어요").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    if !vm.visibleInvites.isEmpty { invitesSection }
                    LazyVStack(spacing: 0) {
                        ForEach(vm.threads) { row in
                            Button { Task { await vm.openThread(peer: row.peerDevice) } } label: {
                                threadRow(row)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            Text("🔒 종단간 암호화 · 이 기기에서만 읽힘")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    /// 받은 길드 초대 카드 (쪽지 스레드 위). 길드 탭에서 이곳으로 편입.
    private var invitesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("받은 길드 초대 \(vm.visibleInvites.count)건", systemImage: "shield.lefthalf.filled")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.teal)
                .padding(.horizontal, 12).padding(.top, 8)
            ForEach(vm.visibleInvites) { inv in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(inv.guildName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(inv.memberCount)명").font(.system(size: 10)).foregroundStyle(.secondary)
                            if let by = inv.inviterNickname {
                                Text("· \(by) 초대").font(.system(size: 10))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Spacer()
                    Button("수락") { Task { await vm.acceptInvite(inv) } }
                        .font(.system(size: 11)).controlSize(.small).buttonStyle(.borderedProminent)
                    Button("거절") { Task { await vm.declineInvite(inv) } }
                        .font(.system(size: 11)).controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08)))
                .padding(.horizontal, 8)
            }
            Divider().padding(.top, 4)
        }
    }

    private func threadRow(_ row: DMViewModel.ThreadRow) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.teal.opacity(0.15)).frame(width: 30, height: 30)
                Text(String(row.nickname.prefix(1))).font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(row.nickname).font(.system(size: 12, weight: row.unread > 0 ? .semibold : .regular))
                    if row.keyChanged { Text("🔑⚠").font(.system(size: 9)).help("상대 보안 키가 바뀌었어요") }
                }
                Text(row.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(relative(row.at)).font(.system(size: 9)).foregroundStyle(.secondary)
                if row.unread > 0 {
                    Text("\(min(row.unread, 99))")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.red).clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - 스레드

private struct DMThreadView: View {
    @ObservedObject var vm: DMViewModel
    @State private var draft = ""
    @State private var confirmingDelete = false
    private static let bottomAnchor = "dm-bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { vm.closeThread() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                Text(vm.openPeerNickname ?? "쪽지").font(.system(size: 13, weight: .semibold))
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                if let peer = vm.openPeer, vm.isBlocked(peer) {
                    Text("차단됨").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
                }
                Spacer()
                peerMenu
            }
            .padding(10)
            Divider()
            if let error = vm.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).padding(8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.openMessages) { m in bubble(m) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)   // 최하단 앵커
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                // 열 때 + 새 메시지 추가 시 최신(최하단)으로. 그 사이엔 자유롭게 위로 스크롤 가능.
                .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
                .onChange(of: vm.openMessages.count) { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack(spacing: 6) {
                TextField("메시지 입력…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                    .onSubmit { sendDraft() }
                Button("전송") { sendDraft() }
                    .font(.system(size: 11)).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(8)
        }
        // 스레드가 열려 있는 동안 8초마다 새 메시지 폴링 — 뷰가 사라지면 자동 취소.
        .task(id: vm.openPeer) {
            guard vm.openPeer != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                if Task.isCancelled { break }
                await vm.refreshOpenThread()
            }
        }
        .confirmationDialog("이 대화를 삭제할까요?", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("대화 삭제", role: .destructive) { Task { await vm.deleteThread() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("내 쪽에서만 삭제됩니다. 상대에게는 남아 있어요.")
        }
    }

    /// 상대 안전 지문 + 차단/해제.
    @ViewBuilder
    private var peerMenu: some View {
        Menu {
            if let peer = vm.openPeer, let fp = vm.peerFingerprint(for: peer) {
                Text("상대 안전 지문")
                Text(fp).font(.system(.body, design: .monospaced))
                Divider()
            }
            if let peer = vm.openPeer {
                if vm.isBlocked(peer) {
                    Button { Task { await vm.unblock(device: peer) } } label: {
                        Label("차단 해제", systemImage: "hand.raised.slash")
                    }
                } else if let nick = vm.openPeerNickname {
                    Button(role: .destructive) { Task { await vm.block(nickname: nick) } } label: {
                        Label("이 사용자 차단", systemImage: "hand.raised")
                    }
                }
            }
            if vm.openPeer != nil {
                Divider()
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label("대화 삭제", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).frame(width: 28)
    }

    private func sendDraft() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
              let nick = vm.openPeerNickname else { return }
        draft = ""
        Task { await vm.send(toNickname: nick, text: text) }
    }

    @ViewBuilder
    private func bubble(_ m: DMViewModel.DisplayMessage) -> some View {
        HStack {
            if m.fromMe { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 12))
                .foregroundStyle(m.failed ? Color.secondary : (m.fromMe ? Color.white : Color.primary))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(m.fromMe ? Color.accentColor : Color.gray.opacity(0.2)))
            if !m.fromMe { Spacer(minLength: 40) }
        }
    }
}

// MARK: - 작성

private struct DMComposeView: View {
    @ObservedObject var vm: DMViewModel
    let onDone: () -> Void
    @State private var nickname: String
    @State private var body_ = ""
    @State private var sending = false

    init(vm: DMViewModel, initialNickname: String = "", onDone: @escaping () -> Void) {
        self._vm = ObservedObject(wrappedValue: vm)
        self.onDone = onDone
        self._nickname = State(initialValue: initialNickname)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("새 쪽지").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("닫기") { onDone() }.font(.system(size: 11))
            }
            HStack(spacing: 6) {
                Text("받는 사람").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("닉네임", text: $nickname).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            TextField("메시지…", text: $body_, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(3...6).font(.system(size: 12))
            if let warn = vm.keyChangeWarning, warn == nickname {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠ \(warn)님의 보안 키가 바뀌었어요. 기기 변경/재설치일 수 있어요.")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Button("새 키 신뢰하고 보내기") { doSend(trust: true) }
                        .font(.system(size: 11)).controlSize(.small)
                }
            }
            if let error = vm.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack {
                Text("🔒 상대 공개키를 처음 신뢰합니다 (TOFU)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Button("보내기") { doSend(trust: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || nickname.count < 3 || body_.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16).frame(width: 320)
    }

    private func doSend(trust: Bool) {
        sending = true
        Task {
            await vm.send(toNickname: nickname, text: body_, trustChangedKey: trust)
            sending = false
            // 경고가 뜬 게 아니고 에러도 없으면 성공 → 닫고 스레드로.
            if vm.keyChangeWarning == nil && vm.error == nil { onDone() }
        }
    }
}

// MARK: - 설정 (수신 정책 · 차단 · 지문)

private struct DMSettingsView: View {
    @ObservedObject var vm: DMViewModel
    let onDone: () -> Void

    private let options: [(String, String)] = [
        ("anyone", "아무나"), ("guild", "같은 길드만"), ("none", "안 받음"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("쪽지 설정").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("닫기") { onDone() }.font(.system(size: 11))
            }

            // 수신 정책
            Text("쪽지 받기").font(.system(size: 12, weight: .semibold))
            Picker("", selection: Binding(
                get: { vm.allowFrom },
                set: { v in Task { await vm.setAllowFrom(v) } })
            ) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text("‘안 받음’이어도 이미 주고받던 스레드는 유지돼요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)

            Divider()

            // 차단 목록
            Text("차단 목록").font(.system(size: 12, weight: .semibold))
            if vm.blocked.isEmpty {
                Text("차단한 사용자가 없어요").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(vm.blocked) { b in
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10)).foregroundStyle(.orange)
                        Text(b.nickname ?? "(알 수 없음)").font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button("차단 해제") { Task { await vm.unblock(device: b.device) } }
                            .font(.system(size: 10)).controlSize(.small)
                    }
                }
            }

            Divider()

            // 내 안전 지문
            Text("내 안전 지문").font(.system(size: 12, weight: .semibold))
            Text(vm.myFingerprint)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
            Text("상대와 직접 만나 지문을 맞춰보면 중간자 공격을 잡아낼 수 있어요.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = vm.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { Task { await vm.loadSettings() } }
    }
}
