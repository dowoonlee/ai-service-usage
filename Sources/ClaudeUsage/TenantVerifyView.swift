import AppKit
import SwiftUI

/// 사내 전용 테넌트(예: SKAX) 편입 인증 시트 — docs/plans/tenant.md §5.
///
/// 2단계: ① 로컬파트 입력 + 도메인 드롭다운 → 코드 요청, ② 6자리 코드 입력 → 확인.
/// 성공 시 서버가 `users.tenant_id`를 게이트 테넌트로 고정(one-way)하고 `onDone`으로 보드를 갱신한다.
/// HMAC 서명은 RankingAPI가 처리(deviceId + Keychain hmacKey).
@MainActor
struct TenantVerifyView: View {
    let deviceId: String
    let onDone: () -> Void
    /// 자동 유도 팝업은 전용 NSWindow에 호스팅되어 SwiftUI `dismiss`가 동작하지 않는다.
    /// 그 경로에선 닫기 콜백을 주입하고, 시트 컨텍스트(nil)에선 `dismiss()`를 쓴다.
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private enum Step { case email, code }
    @State private var step: Step = .email
    @State private var domains: [RankingAPI.TenantDomain] = []
    @State private var selectedDomain: String = ""     // TenantDomain.domain
    @State private var localPart: String = ""
    @State private var code: String = ""
    @State private var targetTenantName: String = ""
    @State private var loadingDomains = true
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "lock.shield.fill").foregroundStyle(.teal)
                Text("사내 보드 인증").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { closeSelf() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }

            rewardBanner

            switch step {
            case .email: emailStep
            case .code:  codeStep
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 자동 유도 팝업 전용 opt-out — 시트(사용자가 헤더 버튼으로 직접 연 경우)엔 표시하지 않는다.
            if onClose != nil {
                HStack {
                    Spacer()
                    Button("다시 보지 않기") {
                        Settings.shared.tenantPromptOptedOut = true
                        closeSelf()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help("이후 자동 안내를 끕니다. 랭킹 헤더의 '사내 인증' 버튼으로 언제든 인증할 수 있어요.")
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: loadDomains)
    }

    /// 인증 유도 보상 CTA — 지금 인증하면 coin·RP를 준다는 배너(v0.16.2 캠페인).
    private var rewardBanner: some View {
        HStack(spacing: 6) {
            Text("🎁").font(.system(size: 14))
            (Text("지금 인증하면 ")
                + Text("+3,000 coin · +3,000 RP").fontWeight(.bold).foregroundColor(.teal))
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.12)))
    }

    /// 시트/윈도우 어느 쪽에서든 자신을 닫는다.
    private func closeSelf() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: - Step 1: 이메일

    @ViewBuilder
    private var emailStep: some View {
        Text("회사 이메일로 인증하면 사내 전용 랭킹·게시판·쪽지에 참여합니다.\n인증 후에는 외부 보드로 다시 돌아갈 수 없습니다.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if loadingDomains {
            ProgressView().controlSize(.small)
        } else if domains.isEmpty {
            Text("현재 인증 가능한 도메인이 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                TextField("아이디", text: $localPart)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Text("@").foregroundStyle(.secondary)
                Picker("", selection: $selectedDomain) {
                    ForEach(domains) { d in
                        Text(d.label).tag(d.domain)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            if let d = domains.first(where: { $0.domain == selectedDomain }) {
                Text("→ \(d.tenantName) 보드에 편입됩니다.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button(action: requestCode) {
                if busy { ProgressView().controlSize(.small) }
                else { Text("인증 코드 받기") }
            }
            .disabled(busy || localPart.trimmingCharacters(in: .whitespaces).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Step 2: 코드

    @ViewBuilder
    private var codeStep: some View {
        Text("\(targetTenantName.isEmpty ? "" : "\(targetTenantName) 보드 · ")\(fullEmail)로 6자리 코드를 보냈습니다. 메일함(스팸함 포함)을 확인하세요.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        TextField("6자리 코드", text: $code)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .onChange(of: code) { v in
                let digits = v.filter(\.isNumber)
                code = String(digits.prefix(6))
            }
        HStack {
            Button("코드 다시 받기") { step = .email; code = ""; error = nil }
                .buttonStyle(.borderless).font(.system(size: 11))
            Spacer()
            Button(action: confirmCode) {
                if busy { ProgressView().controlSize(.small) }
                else { Text("확인") }
            }
            .disabled(busy || code.count != 6)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var fullEmail: String {
        "\(localPart.trimmingCharacters(in: .whitespaces))@\(selectedDomain)"
    }

    // MARK: - Actions

    private func loadDomains() {
        Task {
            defer { loadingDomains = false }
            do {
                let resp = try await RankingAPI.shared.fetchTenantDomains()
                domains = resp.domains
                if let first = domains.first { selectedDomain = first.domain }
            } catch {
                self.error = "도메인 목록을 불러오지 못했습니다."
            }
        }
    }

    private func requestCode() {
        guard !deviceId.isEmpty, let hmacKey = Keychain.loadRankingHmacKey() else {
            error = "먼저 랭킹에 참여(등록)해야 합니다."
            return
        }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let resp = try await RankingAPI.shared.requestTenantVerification(
                    deviceId: deviceId, email: fullEmail, hmacKeyBase64: hmacKey)
                targetTenantName = resp.tenant.uppercased()
                step = .code
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }

    /// verify 전용 에러 메시지 — 429 rate_limited는 게시판 문구("다음 글 작성까지 …")로 새지 않게 override.
    private static func message(for error: Error) -> String {
        if let re = error as? RankingAPI.RankingError, case .rateLimited = re {
            return "인증 코드 요청이 너무 잦습니다. 잠시 후 다시 시도하세요."
        }
        return error.localizedDescription
    }

    private func confirmCode() {
        guard let hmacKey = Keychain.loadRankingHmacKey() else {
            error = "인증 키를 찾을 수 없습니다."
            return
        }
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do {
                let resp = try await RankingAPI.shared.confirmTenantVerification(
                    deviceId: deviceId, code: code, hmacKeyBase64: hmacKey)
                let s = Settings.shared
                // 새 소속을 캐시에 즉시 반영 — 자동 팝업/시트 어느 경로든 랭킹 헤더 배지와 팝업
                // 재표시 판정이 곧바로 정확해진다(폴링 왕복을 기다리는 stale UI 방지).
                s.currentTenant = resp.tenant
                // 인증 성공 보상 — coin은 클라 로컬 원장에 즉시 지급(RP 3,000은 서버 rp_rewards가
                // 다음 폴링 때 전달). one-way 인증이라 성공은 1회뿐이지만 방어적으로 플래그 dedup.
                if !s.hasReceivedTenantVerifyBonus {
                    CoinLedger.shared.creditBonus(3000, reason: "tenant.verify")
                    s.hasReceivedTenantVerifyBonus = true
                }
                onDone()
                closeSelf()
            } catch {
                self.error = Self.message(for: error)
            }
        }
    }
}

// MARK: - 사내 인증 유도 (자동 팝업)

/// 미인증 사용자에게 사내 보드 인증을 유도하는 자동 팝업 매니저(v0.16.2 캠페인).
///
/// 정책:
///   * 랭킹 미등록자는 인증 자체가 불가(hmacKey 필요) → skip.
///   * 이미 보너스를 받았으면(= 인증 완료) skip.
///   * **하루 1회** 억제 — 마지막 표시 후 24h 경과해야 재표시.
///   * 미인증 판단은 `Settings.currentTenant` 캐시 우선(재실행 대부분), 첫 실행 등 캐시가 nil이면
///     서버 leaderboard로 1회 확인(실패 시 다음 실행 재시도, `AnnouncementManager` 패턴과 동일).
@MainActor
final class TenantVerifyPromptManager {
    static let shared = TenantVerifyPromptManager()
    private init() {}

    /// 표시 억제 간격(초). 하루 1회.
    private static let suppressInterval: TimeInterval = 24 * 3600

    /// 앱 시작 시 1회. `App.applicationDidFinishLaunching`에서 호출.
    func checkOnLaunch() {
        guard RankingAPI.isConfigured else { return }
        let s = Settings.shared
        // 인증엔 랭킹 등록이 선행돼야 하고, 이미 보너스를 받았으면(인증 완료) 대상 아님.
        // '다시 보지 않기'로 끈 사용자는 자동 안내를 영구 중단(헤더 버튼 진입은 여전히 가능).
        guard s.rankingRegistered, !s.hasReceivedTenantVerifyBonus, !s.tenantPromptOptedOut else { return }
        // 하루 1회 억제.
        if let last = s.lastTenantPromptAt,
           Date().timeIntervalSince(last) < Self.suppressInterval { return }

        // 캐시된 테넌트로 즉시 판단(재실행 대부분). 캐시가 확실한 인증 상태면 서버 왕복 없이 종료.
        if let cached = s.currentTenant {
            if cached == "public" { present() }
            return
        }
        // 첫 실행 등 캐시 미상 — 서버로 1회 확인. 실패 시 다음 실행 재시도.
        let deviceId = s.rankingDeviceID
        guard !deviceId.isEmpty else { return }
        Task {
            do {
                let resp = try await RankingAPI.shared.fetchLeaderboard(deviceId: deviceId)
                s.currentTenant = resp.tenant
                if (resp.tenant ?? "public") == "public" { present() }
            } catch {
                DebugLog.log("TenantVerifyPrompt: tenant 확인 실패 — 다음 실행 재시도: \(error)")
            }
        }
    }

    private func present() {
        Settings.shared.lastTenantPromptAt = Date()
        TenantVerifyWindowController.shared.present()
    }
}

/// 사내 인증 시트를 전용 NSWindow로 띄우는 단일 인스턴스 컨트롤러(`GuideWindowController` 패턴).
/// LSUIElement 앱이라 표시 직전 `NSApp.activate`로 앞으로 가져온다.
@MainActor
final class TenantVerifyWindowController: NSWindowController, SingleWindowPresenting {
    static let shared = TenantVerifyWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "사내 보드 인증"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        let root = TenantVerifyView(
            deviceId: Settings.shared.rankingDeviceID,
            onDone: {},                                        // 성공 시 창은 onClose로 닫힘
            onClose: { [weak self] in self?.window?.close() }
        )
        window?.contentViewController = NSHostingController(rootView: root)
        // 패치 공지 창도 정중앙에 뜨므로, 같은 실행에서 둘 다 표시되면 정확히 겹친다. 인증 창을
        // 중앙에서 살짝 어긋나게 배치해 공지 창이 뒤에 숨지 않도록 한다.
        window?.center()
        if let frame = window?.frame {
            window?.setFrameOrigin(NSPoint(x: frame.origin.x + 60, y: frame.origin.y - 60))
        }
        bringToFront()
    }
}
