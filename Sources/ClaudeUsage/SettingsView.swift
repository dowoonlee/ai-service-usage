import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("표시") {
                HStack {
                    Text("창 투명도")
                    Slider(value: $settings.panelOpacity, in: 0.4...1.0)
                    Text("\(Int(settings.panelOpacity * 100))%")
                        .font(.system(size: 11)).monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("사용 페이스 예측 표시", isOn: $settings.showPace)
                Toggle("메뉴바 모드 활성화", isOn: $settings.showMenuBar)
                Text("메뉴바 모드를 설정하면 패널 close 시 메뉴바에 펫이 표시됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                if settings.showMenuBar {
                    Picker("메뉴바에 표시할 펫", selection: $settings.menuBarPetSource) {
                        ForEach(MenuBarPetSource.allCases) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                }
            }
            Section("펫") {
                Toggle("Claude 차트에 펫 표시", isOn: $settings.petClaudeEnabled)
                if settings.ownedPets.isEmpty {
                    emptyPetsRow
                } else {
                    Picker("Claude 펫", selection: claudeSelectionBinding) {
                        ForEach(allOwnedSelections, id: \.self) { sel in
                            Text(selectionLabel(sel)).tag(sel)
                        }
                    }
                    .disabled(!settings.petClaudeEnabled)
                }
                Picker("Claude 테마", selection: $settings.themeClaudeOverride) {
                    Text("기본 (\(PetTheme.defaultFor(settings.petClaudeKind).displayName))")
                        .tag(PetTheme?.none)
                    ForEach(PetTheme.allCases) { t in
                        Text(t.displayName).tag(PetTheme?.some(t))
                    }
                }
                Toggle("Cursor 차트에 펫 표시", isOn: $settings.petCursorEnabled)
                if !settings.ownedPets.isEmpty {
                    Picker("Cursor 펫", selection: cursorSelectionBinding) {
                        ForEach(allOwnedSelections, id: \.self) { sel in
                            Text(selectionLabel(sel)).tag(sel)
                        }
                    }
                    .disabled(!settings.petCursorEnabled)
                }
                Picker("Cursor 테마", selection: $settings.themeCursorOverride) {
                    Text("기본 (\(PetTheme.defaultFor(settings.petCursorKind).displayName))")
                        .tag(PetTheme?.none)
                    ForEach(PetTheme.allCases) { t in
                        Text(t.displayName).tag(PetTheme?.some(t))
                    }
                }
                Text("사용량이 많아지면 펫이 신나고, 임계치에 가까워지면 불안해합니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack {
                    Text("펫 반응")
                    Slider(value: $settings.bigDropThreshold, in: 0.10...0.80, step: 0.05)
                }
                Text("차트가 크게 움직일 때 펫이 얼마나 자주 반응할지.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("수집") {
                HStack(spacing: 10) {
                    CoinIcon(size: 16)
                    Text("\(settings.coins)").monospacedDigit()
                    Image(systemName: "ticket.fill")
                        .foregroundStyle(.blue)
                    Text("\(settings.gachaTickets)").monospacedDigit()
                    Spacer()
                    Button("열기") {
                        GachaWindowController.shared.present()
                    }
                }
                Text("뽑기를 돌려 펫을 모으세요. 사용량이 코인으로 적립됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("시작") {
                Toggle("로그인 시 자동 시작", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }
            Section("알림") {
                Toggle("임계치 알림 사용", isOn: $settings.notifyEnabled)
                ThresholdEditor(settings: settings)
                    .disabled(!settings.notifyEnabled)
                Text("같은 주기 내에서는 임계치별로 한 번만 알림이 옵니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("GitHub 연동") {
                GitHubLinkView(settings: settings)
            }
            Section("랭킹") {
                RankingSectionView(settings: settings)
            }
            Section("정보") {
                CreditsView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
    }

    // MARK: - 펫 picker helpers (보유 펫 + variant 페어 단위 선택)

    private var allOwnedSelections: [PetSelection] {
        PetKind.allCases.flatMap { k -> [PetSelection] in
            guard let o = settings.ownedPets[k] else { return [] }
            return o.unlockedVariants.sorted().map { v in PetSelection(kind: k, variant: v) }
        }
    }

    private var claudeSelectionBinding: Binding<PetSelection> {
        Binding(
            get: { PetSelection(kind: self.settings.petClaudeKind, variant: self.settings.petClaudeVariant) },
            set: { sel in
                self.settings.petClaudeKind = sel.kind
                self.settings.petClaudeVariant = sel.variant
            }
        )
    }

    private var cursorSelectionBinding: Binding<PetSelection> {
        Binding(
            get: { PetSelection(kind: self.settings.petCursorKind, variant: self.settings.petCursorVariant) },
            set: { sel in
                self.settings.petCursorKind = sel.kind
                self.settings.petCursorVariant = sel.variant
            }
        )
    }

    private func selectionLabel(_ sel: PetSelection) -> String {
        if sel.variant == 0 { return sel.kind.displayName }
        return "\(sel.kind.displayName) \(String(repeating: "✨", count: sel.variant))"
    }

    private var emptyPetsRow: some View {
        HStack {
            Text("보유 펫 없음 — 가챠를 돌려 시작하세요")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("가챠 열기") {
                GachaWindowController.shared.present()
            }
        }
    }
}

private struct ThresholdEditor: View {
    @ObservedObject var settings: Settings
    @State private var newValue: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(settings.notifyThresholds, id: \.self) { t in
                HStack {
                    Text("\(t)%")
                        .font(.system(size: 12)).monospacedDigit()
                    Spacer()
                    Button {
                        settings.removeThreshold(t)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("새 임계치", text: $newValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("%").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("추가") {
                    if let v = Int(newValue), v > 0 {
                        settings.addThreshold(v)
                        newValue = ""
                    }
                }
                .disabled((Int(newValue) ?? 0) <= 0)
            }
            .padding(.top, 4)
        }
    }
}

// GitHub Device Flow UI — 빌드 시 GITHUB_CLIENT_ID 미설정이면 자동으로 비활성 안내만 표시.
private struct GitHubLinkView: View {
    @ObservedObject var settings: Settings

    enum FlowState {
        case idle
        case requesting
        case waiting(userCode: String, verificationURL: String)
        case authenticating
        case error(String)
    }
    @State private var state: FlowState = .idle
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        if !GitHubAuth.isConfigured {
            Text("GitHub 연동이 이 빌드에 포함되지 않았습니다. (GITHUB_CLIENT_ID 미설정)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if let login = settings.githubLogin {
            connectedView(login: login)
        } else {
            disconnectedView
        }
    }

    private func connectedView(login: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("연결됨: @\(login)").font(.system(size: 12))
                Spacer()
                Button("연결 해제") {
                    settings.disconnectGitHub()
                    state = .idle
                }
            }
            Text("머지된 기여 PR마다 \(CoinLedger.coinPerContributorPR) 코인 자동 적립.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Button("지금 동기화") {
                Task { await ContributorBonus.shared.sync() }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
    }

    private var disconnectedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch state {
            case .idle:
                Button("GitHub 연결하기") { startFlow() }
                Text("기여한 PR이 머지되면 \(CoinLedger.coinPerContributorPR) 코인이 자동 적립됩니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .requesting:
                HStack { ProgressView().controlSize(.small); Text("코드 요청 중...").font(.system(size: 11)) }
            case .waiting(let userCode, let verificationURL):
                waitingView(userCode: userCode, verificationURL: verificationURL)
            case .authenticating:
                HStack { ProgressView().controlSize(.small); Text("인증 처리 중...").font(.system(size: 11)) }
            case .error(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Text("실패: \(msg)").font(.system(size: 11)).foregroundStyle(.red)
                    Button("다시 시도") { startFlow() }
                }
            }
        }
    }

    private func waitingView(userCode: String, verificationURL: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("아래 코드를 GitHub에서 입력하세요")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(userCode)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(userCode, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("코드 복사")
            }
            HStack(spacing: 8) {
                Button("GitHub 열기") {
                    if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
                }
                Button("취소") {
                    pollTask?.cancel()
                    state = .idle
                }
            }
            Text("브라우저에서 인증을 마치면 자동으로 연결됩니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func startFlow() {
        state = .requesting
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            do {
                let code = try await GitHubAuth.shared.requestDeviceCode()
                // user_code를 자동으로 클립보드에 복사 (GitHub에선 수동 입력 필요).
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.user_code, forType: .string)
                state = .waiting(userCode: code.user_code, verificationURL: code.verification_uri)
                let token = try await GitHubAuth.shared.pollForToken(
                    deviceCode: code.device_code,
                    interval: code.interval,
                    expiresIn: code.expires_in
                )
                state = .authenticating
                let user = try await GitHubAuth.shared.fetchUser(token: token)
                Keychain.saveGitHubToken(token)
                ContributorBonus.shared.updateToken(token)
                // 사용자 식별 3개 필드 + 사주 "생년월일" 한 번에 반영. SSOT 헬퍼 경유.
                settings.persistGitHubUser(user)
                state = .idle
                // 연결 직후 첫 sync — 과거 PR 일괄 보너스 트리거.
                await ContributorBonus.shared.sync()
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }
}

// 랭킹 옵트인/관리 UI. 옵트인 시점에 처리방침 동의 + 닉네임 확정 + 서버 register.
// 등록 후엔 닉네임 변경/계정 삭제/복구 코드 재표시/보드 열기 액션을 노출.
private struct RankingSectionView: View {
    @ObservedObject var settings: Settings

    enum FlowState: Equatable {
        case idle
        case registering
        case error(String)
        /// GitHub 복구 — device flow의 user_code 입력 대기 단계. URL은 항상 https://github.com/login/device.
        case githubAuthWaiting(userCode: String, verificationURL: String)
        /// 토큰 발급 후 peek-by-github 호출 중 (메타데이터 조회).
        case githubPeeking
        /// peek 응답 받음 — 사용자 컨펌 대기. token은 컨펌 시 recover 호출에 재사용.
        case githubAuthConfirming(peek: RankingAPI.GitHubAccountPeek, token: String)
        /// 컨펌 후 hmac_key rotation + 복원 진행 중.
        case githubRecovering
    }
    @State private var state: FlowState = .idle
    @State private var nicknameInput: String = ""
    @State private var editingNickname: Bool = false
    @State private var showRecoveryCode: Bool = false
    @State private var recoveryInput: String = ""
    @State private var showRecoveryEntry: Bool = false
    @State private var confirmDelete: Bool = false
    /// GitHub device flow 폴링 task — 사용자가 시트 닫거나 취소하면 cancel.
    @State private var githubPollTask: Task<Void, Never>? = nil

    var body: some View {
        if !RankingAPI.isConfigured {
            Text("랭킹 기능이 이 빌드에 포함되지 않았습니다. (SupabaseURL 미설정)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if settings.rankingRegistered {
            registeredView
        } else {
            optInView
        }
    }

    // MARK: - Opt-in (등록 전)

    private var optInView: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case .registering:
                HStack { ProgressView().controlSize(.small); Text("등록 중...").font(.system(size: 11)) }
            case .error(let msg):
                VStack(alignment: .leading, spacing: 4) {
                    Text("실패: \(msg)").font(.system(size: 11)).foregroundStyle(.red)
                    Button("다시 시도") { state = .idle }
                }
            default:
                // .idle + githubAuth* (sheet 안에서 처리되는 상태들).
                idleOptInView
            }
        }
    }

    private var idleOptInView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("코인 누적량을 글로벌 보드에 공개합니다. 닉네임은 사용자 식별에만 사용.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Toggle(isOn: $settings.rankingPrivacyAccepted) {
                    Text("처리방침에 동의합니다").font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
                if let url = RankingAPI.privacyPolicyURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .help("처리방침 보기")
                }
            }

            HStack {
                Text("닉네임").font(.system(size: 11)).frame(width: 56, alignment: .leading)
                TextField("자동 생성", text: $nicknameInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }
            HStack(spacing: 6) {
                Button("자동 생성") { nicknameInput = NicknameGenerator.generate() }
                    .buttonStyle(.borderless).font(.system(size: 11))
                if let login = settings.githubLogin {
                    Button("GitHub(@\(login)) 사용") { nicknameInput = login }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                Spacer()
            }

            HStack {
                Button("참여 시작") { startRegistration() }
                    .disabled(!settings.rankingPrivacyAccepted || !NicknameGenerator.isValid(nicknameInput))
                Spacer()
                Button("복구 코드로 이전 계정 불러오기") { showRecoveryEntry = true }
                    .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .onAppear {
            if nicknameInput.isEmpty {
                nicknameInput = settings.githubLogin ?? NicknameGenerator.generate()
            }
        }
        .sheet(isPresented: $showRecoveryEntry) {
            recoveryEntrySheet
        }
    }

    // MARK: - Registered (등록 후)

    private var registeredView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: settings.rankingEnabled ? "checkmark.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(settings.rankingEnabled ? .green : .secondary)
                Text(settings.rankingEnabled ? "참여 중" : "일시 중지")
                    .font(.system(size: 12))
                Spacer()
                Toggle("", isOn: pauseBinding).labelsHidden().toggleStyle(.switch)
            }

            HStack {
                Text("닉네임").font(.system(size: 11)).frame(width: 56, alignment: .leading)
                if editingNickname {
                    TextField("", text: $nicknameInput)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("저장") {
                        let trimmed = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if NicknameGenerator.isValid(trimmed) {
                            settings.rankingNickname = trimmed
                        }
                        editingNickname = false
                    }
                    .font(.system(size: 11))
                    Button("취소") { editingNickname = false; nicknameInput = settings.rankingNickname }
                        .buttonStyle(.borderless).font(.system(size: 11))
                } else {
                    Text(settings.rankingNickname).font(.system(size: 12, weight: .medium))
                    Button {
                        nicknameInput = settings.rankingNickname
                        editingNickname = true
                    } label: { Image(systemName: "pencil").font(.system(size: 11)) }
                        .buttonStyle(.borderless)
                    Spacer()
                }
            }

            if let lastAt = settings.rankingLastSubmittedAt {
                Text("마지막 동기화 \(lastAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("보드 열기") { GachaWindowController.shared.present(tab: .ranking) }
                Button("복구 코드") { showRecoveryCode = true }
                    .buttonStyle(.borderless).font(.system(size: 11))
                Spacer()
                Button {
                    confirmDelete = true
                } label: {
                    Text("계정 삭제").foregroundStyle(.red)
                }
                .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .alert("복구 코드", isPresented: $showRecoveryCode) {
            Button("복사") {
                if let code = settings.rankingRecoveryCode {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
            }
            Button("닫기", role: .cancel) { }
        } message: {
            Text(settings.rankingRecoveryCode ?? "없음")
        }
        .alert("계정을 삭제하시겠습니까?", isPresented: $confirmDelete) {
            Button("삭제", role: .destructive) { deleteAccount() }
            Button("취소", role: .cancel) { }
        } message: {
            Text("서버의 모든 데이터가 영구 삭제됩니다. 누적 코인은 복구되지 않습니다.")
        }
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { settings.rankingEnabled },
            set: { newValue in
                if newValue {
                    // OFF→ON: 일시 중지 동안 누적된 delta를 rebase. 한 번에 큰 값 제출 회피.
                    settings.rankingLastSubmittedTotal = settings.rankingScoreEarnedVP
                }
                settings.rankingEnabled = newValue
            }
        )
    }

    // MARK: - Recovery entry sheet

    private var recoveryEntrySheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("이전 계정 불러오기").font(.system(size: 13, weight: .semibold))

            switch state {
            case .githubAuthWaiting(let userCode, let verificationURL):
                githubWaitingBody(userCode: userCode, verificationURL: verificationURL)
            case .githubPeeking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("계정 정보 확인 중…").font(.system(size: 11))
                }
                .padding(.vertical, 8)
            case .githubAuthConfirming(let peek, let token):
                githubConfirmBody(peek: peek, token: token)
            case .githubRecovering:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("계정 복구 중…").font(.system(size: 11))
                }
                .padding(.vertical, 8)
            default:
                Text("등록 시 발급된 복구 코드를 입력하거나 같은 GitHub 계정으로 인증하세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("XXXX-XXXX-XXXX", text: $recoveryInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if case .error(let msg) = state {
                    Text(msg).font(.system(size: 10)).foregroundStyle(.red)
                }
                HStack {
                    Button("코드로 복구") { recoverWithCode() }
                        .disabled(recoveryInput.count < 8)
                    if GitHubAuth.isConfigured {
                        Button("GitHub으로 복구") { recoverWithGitHub() }
                    }
                    Spacer()
                    Button("닫기") {
                        githubPollTask?.cancel()
                        state = .idle
                        showRecoveryEntry = false
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    private func githubConfirmBody(peek: RankingAPI.GitHubAccountPeek, token: String) -> some View {
        let fmt: DateFormatter = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "ko_KR")
            f.dateFormat = "yyyy년 M월 d일 HH:mm"
            return f
        }()
        Text("\(fmt.string(from: peek.backupAt)) 시점으로 유저 정보를 복원합니다.")
            .font(.system(size: 12))
        VStack(alignment: .leading, spacing: 2) {
            Text("닉네임: \(peek.nickname)").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("GitHub: @\(peek.githubLogin)").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("누적 점수: \(peek.totalCoins.formatted())").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("코인·펫 인벤토리·뱃지는 양쪽을 합쳐 더 많은 쪽이 보존됩니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            // applyBackup이 backup 값으로 overwrite하는 항목 — 현재 디바이스에서 사용자가
            // 의식적으로 바꿔둔 설정이 사라질 수 있다는 점을 명시 (Settings.swift:702-762 머지 정책).
            Text("단, 다음 설정은 백업 시점 값으로 덮어쓰여집니다:")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Text("• 펫 선택, 메뉴바 표시, 알림 토글·임계값, 운세 표시 기록")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        HStack {
            Button("복원 진행") { performGitHubRestore(token: token) }
                .keyboardShortcut(.defaultAction)
            Button("취소") {
                githubPollTask?.cancel()
                state = .idle
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func githubWaitingBody(userCode: String, verificationURL: String) -> some View {
        Text("GitHub에서 아래 코드를 입력하세요.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        HStack {
            Text(userCode)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(userCode, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .help("코드 복사")
        }
        HStack(spacing: 8) {
            Button("GitHub 열기") {
                if let url = URL(string: verificationURL) { NSWorkspace.shared.open(url) }
            }
            Button("취소") {
                githubPollTask?.cancel()
                state = .idle
            }
            Spacer()
        }
        Text("브라우저에서 인증을 마치면 자동으로 복구가 시작됩니다.")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func startRegistration() {
        let nickname = nicknameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NicknameGenerator.isValid(nickname) else {
            state = .error("닉네임 형식이 올바르지 않습니다.")
            return
        }
        let deviceId = settings.rankingDeviceID.isEmpty ? UUID().uuidString : settings.rankingDeviceID
        state = .registering
        Task { @MainActor in
            do {
                // 누적값 인정 — register 시 현재 rankingScoreEarnedVP를 initialCoins로 전달
                // (서버는 점수 의미 무관 opaque 정수). baseline 동일값으로 잡아 다음 delta=0부터 시작.
                let currentTotal = settings.rankingScoreEarnedVP
                let profile = ProfileState.current(from: settings)
                let resp = try await RankingAPI.shared.register(
                    deviceId: deviceId,
                    nickname: nickname,
                    githubLogin: settings.githubLogin,
                    githubUserId: settings.githubUserID,
                    initialCoins: currentTotal,
                    profileJson: profile
                )
                Keychain.saveRankingHmacKey(resp.hmacKey)
                settings.rankingDeviceID = deviceId
                settings.rankingNickname = resp.nickname
                settings.rankingRecoveryCode = resp.recoveryCode
                settings.rankingBaselineCoins = currentTotal
                settings.rankingLastSubmittedTotal = currentTotal
                settings.rankingRegistered = true
                settings.rankingEnabled = true
                state = .idle
                showRecoveryCode = true
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func recoverWithCode() {
        let newDeviceId = settings.rankingDeviceID.isEmpty ? UUID().uuidString : settings.rankingDeviceID
        Task { @MainActor in
            do {
                let resp = try await RankingAPI.shared.recoverWithRecoveryCode(recoveryInput, newDeviceId: newDeviceId)
                Keychain.saveRankingHmacKey(resp.hmacKey)
                settings.rankingDeviceID = resp.deviceId
                settings.rankingNickname = resp.nickname
                settings.rankingRecoveryCode = recoveryInput
                settings.rankingLastSubmittedTotal = resp.totalCoins
                settings.rankingBaselineCoins = settings.rankingScoreEarnedVP
                settings.rankingRegistered = true
                settings.rankingEnabled = true
                settings.rankingPrivacyAccepted = true
                if let backup = resp.profileJson?.backup {
                    settings.applyBackup(backup)
                }
                showRecoveryEntry = false
            } catch {
                state = .error(error.localizedDescription)
                showRecoveryEntry = false
            }
        }
    }

    /// GitHub 계정으로 이전 계정 복구 — 1단계: 토큰 확보 + peek로 메타 조회 → 컨펌 대기.
    /// 실제 hmac_key rotation은 사용자 컨펌 후 `performGitHubRestore`에서.
    private func recoverWithGitHub() {
        guard GitHubAuth.isConfigured else {
            state = .error("GitHub Client ID가 설정되지 않은 빌드입니다.")
            return
        }
        githubPollTask?.cancel()
        githubPollTask = Task { @MainActor in
            do {
                let token: String
                if let existing = Keychain.loadGitHubToken() {
                    token = existing
                } else {
                    let code = try await GitHubAuth.shared.requestDeviceCode()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.user_code, forType: .string)
                    state = .githubAuthWaiting(userCode: code.user_code,
                                               verificationURL: code.verification_uri)
                    token = try await GitHubAuth.shared.pollForToken(
                        deviceCode: code.device_code,
                        interval: code.interval,
                        expiresIn: code.expires_in
                    )
                    Keychain.saveGitHubToken(token)
                    ContributorBonus.shared.updateToken(token)
                    // 토큰 확보 직후 user 식별 정보까지 받아둠 — 실패하면 outer catch 로 흐름이
                    // 전환되어 사용자에게 정확한 에러가 노출된다 (이전엔 `try?` 로 silent fail
                    // 후 nil 상태로 peek 단계로 넘어가 UI/실제 상태가 어긋났음).
                    let user = try await GitHubAuth.shared.fetchUser(token: token)
                    settings.persistGitHubUser(user)
                }

                // peek — 변경 없이 메타만 조회. 사용자 컨펌 후 실제 복원.
                state = .githubPeeking
                let peek = try await RankingAPI.shared.peekGitHubAccount(token: token)
                state = .githubAuthConfirming(peek: peek, token: token)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// GitHub 복구 2단계: 사용자 컨펌 후 실제 hmac_key rotation + 백업 적용.
    private func performGitHubRestore(token: String) {
        githubPollTask?.cancel()
        githubPollTask = Task { @MainActor in
            do {
                state = .githubRecovering
                let newDeviceId = settings.rankingDeviceID.isEmpty ? UUID().uuidString : settings.rankingDeviceID
                let resp = try await RankingAPI.shared.recoverWithGitHub(token: token, newDeviceId: newDeviceId)
                Keychain.saveRankingHmacKey(resp.hmacKey)
                settings.rankingDeviceID = resp.deviceId
                settings.rankingNickname = resp.nickname
                settings.rankingLastSubmittedTotal = resp.totalCoins
                settings.rankingBaselineCoins = settings.rankingScoreEarnedVP
                settings.rankingRegistered = true
                settings.rankingEnabled = true
                settings.rankingPrivacyAccepted = true
                if let backup = resp.profileJson?.backup {
                    settings.applyBackup(backup)
                }
                state = .idle
                showRecoveryEntry = false
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func deleteAccount() {
        guard let hmacKey = Keychain.loadRankingHmacKey() else {
            settings.clearRankingLocalState()
            return
        }
        let deviceId = settings.rankingDeviceID
        Task { @MainActor in
            do {
                try await RankingAPI.shared.deleteAccount(deviceId: deviceId, hmacKeyBase64: hmacKey)
            } catch {
                DebugLog.log("Ranking delete failed (clearing local anyway): \(error.localizedDescription)")
            }
            settings.clearRankingLocalState()
        }
    }
}

// CC-BY 4.0 attribution은 라이선스 의무 — UI에 노출 필수.
private struct CreditsView: View {
    private struct Pack: Identifiable {
        let id = UUID()
        let name: String
        let author: String
        let license: String
        let url: String
    }

    private let packs: [Pack] = [
        .init(name: "Animated Wild Animals", author: "ScratchIO",
              license: "CC0",
              url: "https://opengameart.org/content/animated-wild-animals"),
        .init(name: "Pixel Adventure 1", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pixel-adventure-1"),
        .init(name: "Pixel Adventure 2", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pixel-adventure-2"),
        .init(name: "Kings and Pigs", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/kings-and-pigs"),
        .init(name: "Pirate Bomb", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/pirate-bomb"),
        .init(name: "Treasure Hunters", author: "Pixel Frog",
              license: "CC-BY 4.0",
              url: "https://pixelfrog-assets.itch.io/treasure-hunters"),
        .init(name: "0x72 DungeonTileset II", author: "0x72",
              license: "CC0",
              url: "https://0x72.itch.io/dungeontileset-ii"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("에셋 크레딧")
                .font(.system(size: 11, weight: .semibold))
            ForEach(packs) { p in
                HStack(spacing: 6) {
                    Text(p.name)
                        .font(.system(size: 11))
                    Text("· \(p.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(p.license)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        if let u = URL(string: p.url) { NSWorkspace.shared.open(u) }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                    .help(p.url)
                }
            }
            Divider().padding(.vertical, 2)
            Text("자동 업데이트는 Sparkle (MIT 라이선스)을 사용합니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("Pixel Frog 팩은 CC-BY 4.0 — 출처/저작자 표기 의무를 지킵니다.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "설정"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
