import Foundation

/// 프로세스 실행 컨텍스트 — "실사용"과 "샌드박스(테스트·데모)"를 가르고, 그에 맞는 저장 백엔드를 넘긴다.
///
/// 배경: 이 앱의 영속 상태는 `UserDefaults.standard` + macOS Keychain + Application Support의 JSONL
/// 세 곳에 있고, 셋 다 **설치된 앱과 공유된다**. 그래서 테스트가 `Settings.shared`나 `Keychain`을
/// 건드리면 실제 사용자의 코인·펫·세션키를 오염시킨다. 그 위험 때문에 가챠·코인 적립·런치
/// 마이그레이션처럼 정작 중요한 로직이 테스트 없이 남아 있었다 — 안전해서가 아니라 만질 수 없어서.
///
/// 여기서 세 저장소의 진입점을 하나로 모으고, 샌드박스면 전부 임시 저장소로 돌린다.
/// XCTest는 **자동 감지**한다. 테스트 작성자가 깜빡해도 실데이터 경로로는 갈 수 없다.
///
/// 수동 사용: `AIUSAGE_SANDBOX=1 swift run` — 실사용 데이터를 전혀 건드리지 않는 빈 상태로 GUI가 뜬다.
/// (기존 `AIUSAGE_DATA_DIR`은 JSONL만 옮겼고 UserDefaults·Keychain은 그대로 공유됐다. 이제 셋 다 격리된다.)
enum AppEnv {

    /// 샌드박스 모드 여부. 프로세스 수명 동안 불변.
    ///
    /// XCTest 감지를 두 경로로 하는 이유: `XCTestConfigurationFilePath`는 Xcode 실행에서만 확실하고,
    /// SwiftPM의 `swift test`는 xctest 하네스 구성에 따라 없을 수 있다. 테스트 번들이 로드되면
    /// `XCTestCase` 심볼은 항상 존재하므로 그쪽이 더 확실한 신호다. 둘 중 하나라도 걸리면 샌드박스.
    static let isSandboxed: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return env["AIUSAGE_SANDBOX"] == "1"
    }()

    // MARK: - UserDefaults

    /// 샌드박스 suite 이름. 고정 이름이라 테스트 후 `defaults read`로 들여다볼 수 있고,
    /// 프로세스 시작 시 한 번 비우므로 이전 실행의 잔재가 새 실행에 새지 않는다.
    static let sandboxSuiteName = "com.dwlee.AIUsage.sandbox"

    /// 설정 저장소. 실사용은 `.standard`, 샌드박스는 전용 suite(시작 시 비움).
    ///
    /// `UserDefaults.standard` 직접 참조는 이 프로퍼티로 모두 대체됐다 — 새 코드에서도 `.standard`를
    /// 직접 쓰지 말 것. 하나라도 남으면 그 값만 실사용 도메인에 새어 격리가 조용히 깨진다.
    private(set) static var defaults: UserDefaults = makeDefaults(wipe: true)

    private static func makeDefaults(wipe: Bool) -> UserDefaults {
        guard isSandboxed else { return .standard }
        let d = UserDefaults(suiteName: sandboxSuiteName) ?? .standard
        if wipe { d.removePersistentDomain(forName: sandboxSuiteName) }
        return d
    }

    // MARK: - Keychain

    /// Keychain 백엔드. 실사용은 시스템 keychain, 샌드박스는 in-memory.
    ///
    /// 샌드박스에서 시스템 keychain을 쓰지 않는 이유는 오염 방지만이 아니다 — ad-hoc 서명 환경에선
    /// 테스트 실행이 ACL 재승인 다이얼로그를 띄워 CI/로컬 실행을 멈춰 세운다.
    private(set) static var keychain: KeychainBackend =
        isSandboxed ? InMemoryKeychainBackend() : SystemKeychainBackend()

    /// 샌드박스에서 백엔드를 갈아끼운다(예: 접근 실패를 흉내내는 백엔드로 #169 회귀 재현).
    /// 실사용 프로세스에서는 무시된다 — 실 keychain이 테스트 더블로 대체되는 경로를 만들지 않는다.
    static func setKeychainBackend(_ backend: KeychainBackend) {
        guard isSandboxed else { return }
        keychain = backend
    }

    // MARK: - 데이터 디렉토리 (JSONL)

    /// JSONL 저장 위치 오버라이드. `nil`이면 Application Support 기본 경로.
    ///
    /// 우선순위: `AIUSAGE_DATA_DIR`(명시 지정) > 샌드박스 임시 디렉토리 > 기본 경로.
    /// 샌드박스 디렉토리는 프로세스마다 고유(pid 포함)해서, 병렬 실행이 같은 파일을 두고 다투지 않는다.
    static let dataDirectory: URL? = {
        if let path = ProcessInfo.processInfo.environment["AIUSAGE_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard isSandboxed else { return nil }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aiusage-sandbox-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - 테스트 리셋

    /// 샌드박스 상태를 초기 상태로 되돌린다 — suite 전체 삭제 + keychain 백엔드 새로 발급.
    /// 테스트 간 상태 누수를 막는 용도라 **샌드박스에서만** 동작한다(실사용 호출은 no-op).
    ///
    /// `Settings.shared`까지 새로 만들려면 이 함수 대신 `Settings.resetForTesting()`을 쓸 것 —
    /// 그쪽이 이 함수를 부른 뒤 인스턴스를 재생성한다.
    static func resetSandbox() {
        guard isSandboxed else { return }
        defaults.removePersistentDomain(forName: sandboxSuiteName)
        defaults = makeDefaults(wipe: true)
        keychain = InMemoryKeychainBackend()
    }
}
