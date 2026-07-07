import Foundation

/// 쪽지 로컬 저장 — E2EE 특성상 서버가 못 채워주는 두 가지를 기기 로컬에 둔다.
///   1. **TOFU 핀**: 상대 공개키를 device_id 기준 고정. 이후 서버가 준 키가 핀과 다르면 경고.
///   2. **발신 echo**: HPKE는 수신자만 복호 가능 → 내가 보낸 메시지는 서버 암호문으로 못 읽으므로
///      전송 시점의 평문을 messageId 기준으로 로컬 보관해 화면에 표시.
///
/// 백업 없음(옵션 A)과 정합 — 기기 전용이라 재설치 시 함께 사라진다. `~/Library/Application
/// Support/ClaudeUsage/dm-local.json`.
@MainActor
final class DMStore {
    static let shared = DMStore()

    struct SentEcho: Codable { let peer: String; let text: String; let ts: Double }
    private struct Persisted: Codable {
        var pins: [String: String] = [:]          // deviceId → x25519Pub(base64)
        var sent: [String: SentEcho] = [:]         // messageId → 평문 echo
    }

    private var data = Persisted()
    private let url: URL

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("dm-local.json")
        if let raw = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(Persisted.self, from: raw) {
            data = decoded
        }
    }

    private func persist() {
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: url, options: .atomic) }
    }

    // MARK: - TOFU 핀

    /// 저장된 핀. 없으면 nil (최초 교신 = TOFU 자동 신뢰 대상).
    func pinnedKey(for device: String) -> String? { data.pins[device.lowercased()] }

    /// 서버가 준 공개키와 핀 비교 결과.
    enum KeyTrust { case firstUse, matches, changed }
    func evaluate(device: String, serverPub: String) -> KeyTrust {
        guard let pin = pinnedKey(for: device) else { return .firstUse }
        return pin == serverPub ? .matches : .changed
    }

    /// 핀 고정/갱신 (최초 신뢰 또는 "새 키 신뢰").
    func pin(device: String, pub: String) {
        data.pins[device.lowercased()] = pub
        persist()
    }

    // MARK: - 발신 echo

    func recordSent(messageId: String, peer: String, text: String, ts: Double) {
        data.sent[messageId] = SentEcho(peer: peer.lowercased(), text: text, ts: ts)
        persist()
    }
    func sentText(messageId: String) -> String? { data.sent[messageId]?.text }

    /// 특정 상대에게 보낸 echo (로컬만 있는 스레드 조립·미리보기용).
    func sentEchoes(peer: String) -> [(id: String, echo: SentEcho)] {
        let key = peer.lowercased()
        return data.sent.filter { $0.value.peer == key }
            .map { (id: $0.key, echo: $0.value) }
            .sorted { $0.echo.ts < $1.echo.ts }
    }

    /// 대화 삭제 시 그 상대에게 보낸 echo도 로컬에서 제거.
    func removeEchoes(peer: String) {
        let key = peer.lowercased()
        data.sent = data.sent.filter { $0.value.peer != key }
        persist()
    }
}
