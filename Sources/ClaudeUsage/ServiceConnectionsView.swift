import SwiftUI

struct ServiceConnectionsView: View {
    @ObservedObject var vm: ViewModel
    let login: () -> Void

    var body: some View {
        Section("Claude") {
            status(loading: vm.claudeLoading, needsSetup: vm.claudeNeedsLogin, error: vm.claudeError,
                   success: vm.claudeLastSuccess ?? vm.claudeCurrent?.takenAt)
            Button(vm.claudeNeedsLogin || vm.claudeCurrent == nil ? "Claude 로그인" : "Claude 재로그인", action: login)
            if !vm.claudeNeedsLogin { Button("Claude 로그아웃") { vm.claudeLogout() } }
            retry(vm.claudeLoading) { await vm.refreshClaude() }
        }
        Section("Cursor") {
            status(loading: vm.cursorLoading, needsSetup: vm.cursorNeedsSetup, error: vm.cursorError,
                   success: vm.cursorLastSuccess ?? vm.cursorCurrent?.takenAt)
            Text("Cursor 앱에서 로그인한 뒤 연결을 확인하세요.").font(.callout)
            retry(vm.cursorLoading) { await vm.refreshCursor() }
        }
        Section("Codex") {
            status(loading: vm.codexLoading, needsSetup: vm.codexNeedsSetup, error: vm.codexError,
                   success: vm.codexLastSuccess ?? vm.codexCurrent?.takenAt)
            Text("터미널에서 codex login 실행 후 연결을 확인하세요.").font(.callout).textSelection(.enabled)
            retry(vm.codexLoading) { await vm.refreshCodex() }
        }
    }

    @ViewBuilder private func status(loading: Bool, needsSetup: Bool, error: String?, success: Date?) -> some View {
        let state = loading ? "확인 중…" : needsSetup ? "로그인 필요" : error != nil ? "갱신 실패" : success != nil ? "연결됨" : "확인 전"
        Text(state).fontWeight(.semibold)
        if let error { Text(error).font(.caption).textSelection(.enabled) }
        if let success { Text("마지막 수집  \(success.formatted())").font(.caption).foregroundStyle(.secondary) }
    }

    private func retry(_ loading: Bool, action: @escaping () async -> Void) -> some View {
        Button("연결 확인") { Task { await action() } }.disabled(loading)
    }
}
