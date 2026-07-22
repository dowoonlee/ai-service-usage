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
                Toggle("업데이트 후 패치 공지 표시", isOn: $settings.patchNotesEnabled)
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
            Section("날씨") {
                Toggle("실제 날씨 효과(비·눈)", isOn: $settings.weatherEffectEnabled)
                if settings.weatherEffectEnabled {
                    Picker("위치", selection: $settings.weatherLocation) {
                        ForEach(WeatherLocation.allCases) { loc in
                            Text(loc.displayName).tag(loc)
                        }
                    }
                }
                Text("선택한 위치의 현재 날씨가 비·눈·뇌우면 패널에 파티클이 내립니다.")
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
            Section("실험") {
                Toggle("펫 이름·대사·설명을 서버에서 받기", isOn: $settings.experimentalRemotePetMeta)
                Text("켜면 앱 업데이트 없이 펫 텍스트가 갱신됩니다. 네트워크 실패·미설정 시 기본값으로 표시.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("정보") {
                CreditsView()
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 700)
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
            Text("머지된 기여 PR마다 \(RankPointLedger.rpPerContributorPR) RP 자동 적립.")
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
                Text("기여한 PR이 머지되면 \(RankPointLedger.rpPerContributorPR) RP가 자동 적립됩니다.")
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

            // 등록 상태인데 이 기기의 HMAC 인증 키에 접근할 수 없는 경우. **두 상황을 구분한다(#169)**:
            //  · .absent      = 키가 정말 없음(재설치/유실) → GitHub 재인증으로 재발급
            //  · .accessFailed = keychain을 지금 못 읽음(잠김·ad-hoc ACL 재승인 거부) → 재승인/재시도 유도.
            //    이때 GitHub 복구를 돌리면 빈 vault를 덮어써 다른 값까지 날아가므로 복구 버튼을 노출하지 않는다.
            // 정상 등록 사용자에겐 (.value) 이 배너가 뜨지 않는다.
            switch Keychain.rankingHmacKeyLookup() {
            case .value:
                EmptyView()
            case .absent:
                VStack(alignment: .leading, spacing: 4) {
                    Label("인증 키 유실 — 서버 동기화가 중단됐습니다.", systemImage: "key.slash")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    Text("이 기기의 랭킹 인증 키가 유실됐습니다. 아래로 복구하면 레이팅·강화 기록을 그대로 이어받습니다(계정 삭제 아님).")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("GitHub으로 계정 복구…") { showRecoveryEntry = true }
                        .controlSize(.small).padding(.top, 2)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
            case .accessFailed:
                VStack(alignment: .leading, spacing: 4) {
                    Label("키체인 접근이 거부됐습니다.", systemImage: "lock.trianglebadge.exclamationmark")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    Text("업데이트 후 macOS가 키체인 재승인을 요청했을 수 있습니다. 앱을 다시 실행하고 나타나는 키체인 대화상자에서 ‘항상 허용’을 눌러주세요. 인증 키는 삭제되지 않았습니다.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
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
        // 키 유실 복구 배너의 진입점 — 등록 상태에서도 복구 시트를 띄울 수 있게 붙인다.
        .sheet(isPresented: $showRecoveryEntry) { recoveryEntrySheet }
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { settings.rankingEnabled },
            set: { newValue in
                if newValue {
                    // OFF→ON: 일시 중지 동안 누적된 delta를 rebase. 한 번에 큰 값 제출 회피.
                    // 제출 단위 단일 소스로 맞춘다 — 절대 VP로 잡으면 zeroBaseline 계정은 delta가
                    // 음수가 돼 baseline 차액만큼 점수가 누락된다.
                    settings.rankingLastSubmittedTotal = settings.rankingSubmittableTotal
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

    private static let backupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 HH:mm"
        return f
    }()

    @ViewBuilder
    private func githubConfirmBody(peek: RankingAPI.GitHubAccountPeek, token: String) -> some View {
        Text("\(Self.backupDateFormatter.string(from: peek.backupAt)) 시점으로 유저 정보를 복원합니다.")
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
                // 신규 등록은 서버 total_coins=0부터 시작(과거 initialCoins 누적 인정 폐기).
                // baseline = 옵트인 시점 VP 스냅샷 → 이후 submit은 (현재 VP - baseline) 증가분만
                // 보낸다(zeroBaseline 모드). lastSubmitted=0으로 서버 total과 동기.
                let currentTotal = settings.rankingScoreEarnedVP
                let profile = ProfileState.current(from: settings)
                let resp = try await RankingAPI.shared.register(
                    deviceId: deviceId,
                    nickname: nickname,
                    githubLogin: settings.githubLogin,
                    githubUserId: settings.githubUserID,
                    profileJson: profile
                )
                guard Keychain.saveRankingHmacKey(resp.hmacKey) else {
                    state = .error("인증 키를 키체인에 저장하지 못했습니다. 키체인 접근을 ‘항상 허용’으로 승인한 뒤 다시 시도해주세요.")
                    return
                }
                settings.rankingDeviceID = deviceId
                settings.rankingNickname = resp.nickname
                settings.rankingRecoveryCode = resp.recoveryCode
                settings.rankingBaselineCoins = currentTotal
                settings.rankingLastSubmittedTotal = 0
                settings.rankingUsesZeroBaseline = true
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
                guard Keychain.saveRankingHmacKey(resp.hmacKey) else {
                    state = .error("인증 키를 키체인에 저장하지 못했습니다. 앱을 다시 실행하고 키체인 접근을 ‘항상 허용’으로 승인한 뒤 다시 시도해주세요.")
                    return
                }
                settings.rankingDeviceID = resp.deviceId
                settings.rankingNickname = resp.nickname
                settings.rankingRecoveryCode = recoveryInput
                // 서버가 알려준 계정 모드에 맞춰 baseline을 복원해 단위 불일치를 막는다.
                //  · zeroBaseline 계정: baseline = VP - 서버 totalCoins 로 역산 → 복구 직후
                //    rankingSubmittableTotal(= VP - baseline) == totalCoins == lastSubmittedTotal
                //    이 되어 delta=0에서 재개, 이후 증가분만 제출(중복/누락 없음). VP가 totalCoins
                //    보다 작으면 baseline 음수 → 새 디바이스에서도 서버 누적분 위에 정확히 쌓인다.
                //  · 레거시(또는 구버전 서버 nil): 절대 누적 모드 유지. baseline 미사용이라 관례상 VP.
                let zeroBaseline = resp.usesZeroBaseline ?? false
                settings.rankingUsesZeroBaseline = zeroBaseline
                settings.rankingBaselineCoins = zeroBaseline
                    ? settings.rankingScoreEarnedVP - resp.totalCoins
                    : settings.rankingScoreEarnedVP
                settings.rankingLastSubmittedTotal = resp.totalCoins
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
            // device flow로 새 토큰 확보(재인증 창 표시) + 저장. 기존 토큰이 무효일 때 폴백 경로로도 쓴다.
            @MainActor func freshDeviceFlow() async throws -> String {
                let code = try await GitHubAuth.shared.requestDeviceCode()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.user_code, forType: .string)
                state = .githubAuthWaiting(userCode: code.user_code, verificationURL: code.verification_uri)
                let t = try await GitHubAuth.shared.pollForToken(
                    deviceCode: code.device_code, interval: code.interval, expiresIn: code.expires_in)
                // 토큰 확보 직후 user 식별 정보까지 받아둠 — 실패하면 outer catch 로 정확한 에러 노출.
                let user = try await GitHubAuth.shared.fetchUser(token: t)
                Keychain.saveGitHubToken(t)
                ContributorBonus.shared.updateToken(t)
                settings.persistGitHubUser(user)
                return t
            }
            do {
                let token: String
                if let existing = Keychain.loadGitHubToken() {
                    // 기존 토큰 유효성 검증 — 무효(만료·권한 상실)면 토큰을 지우고 재인증 창으로 폴백한다.
                    // (이전엔 무효 토큰이어도 창을 띄우지 않아 "복구 버튼을 눌러도 창이 안 뜬다"였다 — #169.)
                    do {
                        let user = try await GitHubAuth.shared.fetchUser(token: existing)
                        settings.persistGitHubUser(user)
                        token = existing
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Keychain.clearGitHubToken()
                        token = try await freshDeviceFlow()
                    }
                } else {
                    token = try await freshDeviceFlow()
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
                // ⚠️ keychain 저장 실패를 "복구 성공"으로 오인하지 않는다(#169). 저장이 실패하면
                // 서버는 이미 키를 rotation 했는데 로컬엔 없어 배너가 계속 뜬다 — 에러로 명확히 알린다.
                guard Keychain.saveRankingHmacKey(resp.hmacKey) else {
                    state = .error("인증 키를 키체인에 저장하지 못했습니다. 앱을 다시 실행하고 키체인 접근을 ‘항상 허용’으로 승인한 뒤 다시 시도해주세요.")
                    return
                }
                settings.rankingDeviceID = resp.deviceId
                settings.rankingNickname = resp.nickname
                // 서버가 알려준 계정 모드에 맞춰 baseline을 복원해 단위 불일치를 막는다.
                //  · zeroBaseline 계정: baseline = VP - 서버 totalCoins 로 역산 → 복구 직후
                //    rankingSubmittableTotal(= VP - baseline) == totalCoins == lastSubmittedTotal
                //    이 되어 delta=0에서 재개, 이후 증가분만 제출(중복/누락 없음). VP가 totalCoins
                //    보다 작으면 baseline 음수 → 새 디바이스에서도 서버 누적분 위에 정확히 쌓인다.
                //  · 레거시(또는 구버전 서버 nil): 절대 누적 모드 유지. baseline 미사용이라 관례상 VP.
                let zeroBaseline = resp.usesZeroBaseline ?? false
                settings.rankingUsesZeroBaseline = zeroBaseline
                settings.rankingBaselineCoins = zeroBaseline
                    ? settings.rankingScoreEarnedVP - resp.totalCoins
                    : settings.rankingScoreEarnedVP
                settings.rankingLastSubmittedTotal = resp.totalCoins
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
    @ObservedObject var settings = Settings.shared
    @State private var showCoffeeAlert = false
    @State private var coffeeJustGranted = false
    @State private var creditsExpanded = false

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
        .init(name: "Animated Slime", author: "Calciumtrice",
              license: "CC-BY 3.0",
              url: "https://opengameart.org/content/animated-slime"),
        .init(name: "Sunny Land", author: "Ansimuz",
              license: "CC0",
              url: "https://ansimuz.itch.io/sunny-land-pixel-game-art"),
        .init(name: "Tiny Swords", author: "Pixel Frog",
              license: "CC0",
              url: "https://pixelfrog-assets.itch.io/tiny-swords"),
        .init(name: "Intersect Asset Pack", author: "AscensionGameDev",
              license: "CC-BY-SA 3.0",
              url: "https://github.com/AscensionGameDev/Intersect-Assets"),
        .init(name: "Pixel Art Icons", author: "Gerrit Halfmann",
              license: "MIT",
              url: "https://github.com/halfmage/pixelarticons"),
        .init(name: "Egg Item Sprite", author: "GoopyBus",
              license: "CC0",
              url: "https://opengameart.org/content/egg-item-sprite"),
        .init(name: "Pixel Coins", author: "truezipp",
              license: "CC0",
              url: "https://opengameart.org/content/pixel-coins-asset"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { creditsExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("에셋 크레딧")
                        .font(.system(size: 11, weight: .semibold))
                    Text("(\(packs.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: creditsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if creditsExpanded {
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
                Text("자동 업데이트는 Sparkle (MIT 라이선스)을 사용합니다.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("CC-BY / CC-BY-SA 에셋은 출처·저작자 표기 의무를 지킵니다. (Pixel Frog·Intersect 등)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)
            // Buy me a coffee — 후원 대신 "마음만 받을게요" 답례로 1회 보상을 드린다.
            Button(action: tapCoffee) {
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill")
                    Text("Buy me a coffee")
                    Spacer()
                    if settings.hasReceivedCoffeeReward {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.brown)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: AppRadius.lg).fill(AppColors.gold.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: AppRadius.lg)
                    .strokeBorder(AppColors.gold.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .alert("☕️ 마음만 받을게요", isPresented: $showCoffeeAlert) {
            Button("고마워요 🙏") {}
        } message: {
            Text(coffeeJustGranted
                 ? "마음만 받을게요. 정말 감사합니다!\n대신 응원의 의미로 5,000 coin · 2,000 RP를 드릴게요. ☕️"
                 : "마음만 받을게요. 늘 감사합니다 🙏")
        }
    }

    /// 커피 버튼 탭 — 처음이면 1회 보상(5,000 coin · 2,000 RP) 지급 후 답례 문구, 이후엔 인사만.
    private func tapCoffee() {
        coffeeJustGranted = !settings.hasReceivedCoffeeReward
        if coffeeJustGranted {
            settings.hasReceivedCoffeeReward = true
            CoinLedger.shared.creditBonus(5000, reason: "coffee")
            RankPointLedger.shared.creditReward(2000, reason: "coffee")
        }
        showCoffeeAlert = true
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, SingleWindowPresenting {
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
        bringToFront()
    }
}
