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
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }

            switch step {
            case .email: emailStep
            case .code:  codeStep
            }

            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: loadDomains)
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
        Text("\(fullEmail)로 6자리 코드를 보냈습니다. 메일함(스팸함 포함)을 확인하세요.")
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
                self.error = error.localizedDescription
            }
        }
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
                _ = try await RankingAPI.shared.confirmTenantVerification(
                    deviceId: deviceId, code: code, hmacKeyBase64: hmacKey)
                onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
