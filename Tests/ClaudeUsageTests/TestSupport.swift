import XCTest
@testable import ClaudeUsage

/// `Settings.shared` / `Keychain` / JSONL을 건드리는 테스트의 공통 베이스.
///
/// 이 앱의 상태는 UserDefaults·Keychain·Application Support 세 곳에 있고 셋 다 설치된 앱과
/// 공유된다. 그래서 예전에는 상태를 만지는 로직(가챠·코인 적립·런치 마이그레이션)을 아예
/// 테스트하지 못했다 — 실행하면 사용자의 실제 코인과 세션키가 오염되기 때문이다.
/// `AppEnv`가 XCTest를 감지해 세 저장소를 전부 임시본으로 돌리므로, 이제 상태를 마음껏 만져도 된다.
///
/// 상속하면 매 테스트 시작 시 상태가 초기화된다(`setUp` → `Settings.resetForTesting()`).
class SandboxedTestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        // 격리가 깨진 채로 테스트가 돌면 실제 사용자 데이터를 지운다. 진행하지 않고 즉시 실패시킨다.
        guard AppEnv.isSandboxed else {
            XCTFail("샌드박스가 아님 — 실제 UserDefaults/Keychain을 건드릴 위험이 있어 중단한다")
            return
        }
        await MainActor.run { Settings.resetForTesting() }
    }
}

// MARK: - 픽스처

extension UsageSnapshot {
    /// Claude 스냅샷 — ingest 테스트에서 쓰는 최소 형태(5h 창만, 또는 5h+7d).
    static func claude(fiveHourPct: Double? = nil,
                       fiveHourResetAt: Date? = nil,
                       sevenDayPct: Double? = nil,
                       sevenDayResetAt: Date? = nil,
                       plan: String? = "Pro",
                       takenAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(takenAt: takenAt,
                      fiveHourPct: fiveHourPct,
                      fiveHourResetAt: fiveHourResetAt,
                      sevenDayPct: sevenDayPct,
                      sevenDayResetAt: sevenDayResetAt,
                      planName: plan)
    }
}

extension SandboxedTestCase {
    /// 사용량 이벤트 소비자를 버스에 물린다. 실사용에서는 `ViewModel.init`이 하는 일 —
    /// ViewModel을 띄우지 않는 테스트는 직접 불러야 코인/VP가 실제로 적립된다.
    @MainActor
    func registerLedgers() {
        UsageEventBus.shared.register(CoinLedger.shared)
        UsageEventBus.shared.register(VPLedger.shared)
    }
}
