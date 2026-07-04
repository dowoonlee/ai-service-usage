import Foundation
import CryptoKit

/// 로컬 상태(coins·펫·티켓·VP) 무결성 체크섬 — **탐지 전용**. 데이터는 절대 수정/리셋하지 않는다.
///
/// Keychain의 per-install 키로 핵심 값의 canonical 직렬화를 HMAC-SHA256한다. 앱 내 정상 변경은
/// 항상 Settings의 didSet을 거쳐 체크섬을 즉시 갱신하므로, `defaults write` 같은 앱 외부 조작만
/// 저장된 체크섬과 어긋나 시작 시 verify에서 탐지된다. 키가 plist 외부(Keychain)에 있어 조작자는
/// 올바른 체크섬을 재생성할 수 없다.
///
/// 한계(의도된 트레이드오프):
///   - 바이너리 분석으로 Keychain 키를 추출하는 결정적 공격은 막지 못한다(casual deterrent).
///   - 로컬 coins/펫은 단일 사용자 경험이라 조작해도 타인 피해가 없다. 본 가드의 실질 가치는
///     랭킹 제출 시 `integrityViolation`을 서버 abuse_flags로 보고해 운영자 수동 큐레이션을
///     보조하는 데 있다. variant 단위 위조까지는 추적하지 않는다(보유 종류 집합만).
enum IntegrityGuard {
    /// 보호 대상 핵심 값을 canonical 문자열로 직렬화 후 HMAC-SHA256 hex. 키가 비었거나 base64
    /// 디코딩 실패면 nil(호출 측은 체크섬 단계를 건너뛴다).
    /// canonical 포맷 버전 — 필드 추가 시 +1 하고 Settings.verifyIntegrity의 버전 마이그레이션이
    /// 구 포맷 체크섬을 비교 없이 재기록하게 한다 (v2: guildPermits 추가).
    static let formatVersion = 2

    static func checksum(coins: Int,
                         coinsTotalEarned: Int,
                         gachaTickets: Int,
                         premiumTickets: Int,
                         guildPermits: Int,
                         rankingScoreEarnedVP: Int,
                         ownedPetsSerialized: String,
                         keyBase64: String) -> String? {
        guard !keyBase64.isEmpty, let keyData = Data(base64Encoded: keyBase64) else { return nil }
        let canonical = "\(coins)|\(coinsTotalEarned)|\(gachaTickets)|\(premiumTickets)|\(guildPermits)|\(rankingScoreEarnedVP)|\(ownedPetsSerialized)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8),
                                                  using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
