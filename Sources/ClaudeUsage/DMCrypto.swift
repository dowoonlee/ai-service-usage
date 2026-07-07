import Foundation
import CryptoKit

/// 1:1 쪽지 E2EE — 시스템 CryptoKit **HPKE Auth 모드** (docs/plans/direct-messages.md §3-4).
///
/// 신원 키쌍은 X25519. **개인키는 Keychain(`dmIdentityKey`)에만**, 공개키만 서버 게시.
/// 백업 없음(옵션 A) — 기기 변경 시 새 키 생성, 이전 암호문은 복호 불가.
/// HPKE는 수신자만 복호 가능하므로 **내가 보낸 메시지는 복호 불가** → 발신분은 로컬 echo로 표시.
enum DMCrypto {
    /// KEM=DHKEM(X25519,HKDF-SHA256) / KDF=HKDF-SHA256 / AEAD=ChaChaPoly.
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let info = Data("aiusage-dm-v1".utf8)
    static let version: UInt8 = 1
    /// X25519 KEM 캡슐(=임시 공개키) 길이. 와이어 blob 파싱 오프셋.
    private static let encLen = 32

    enum DMCryptoError: Error { case badKey, badBlob, decryptFailed }

    // MARK: - 신원 키

    /// 없으면 생성·저장(1회). 개인키 raw 32B를 base64로 Keychain에 둔다.
    static func identityPrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let b64 = Keychain.loadDMIdentityKey(),
           let data = Data(base64Encoded: b64),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        Keychain.saveDMIdentityKey(key.rawRepresentation.base64EncodedString())
        return key
    }

    /// 서버 게시용 내 공개키 (base64 raw 32B = 44자).
    static func identityPublicKeyBase64() -> String {
        identityPrivateKey().publicKey.rawRepresentation.base64EncodedString()
    }

    /// 이미 키쌍이 있는지 (최초 진입 안내용).
    static var hasIdentity: Bool { Keychain.loadDMIdentityKey() != nil }

    /// 안전 지문 — 내 공개키의 SHA-256 앞부분을 그룹 표기. (대역외 검증용, 표시 전용)
    static func fingerprint(ofPubBase64 pub: String) -> String {
        guard let data = Data(base64Encoded: pub) else { return "?" }
        let hash = SHA256.hash(data: data)
        let hex = hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map {
            let s = hex.index(hex.startIndex, offsetBy: $0)
            let e = hex.index(s, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[s..<e])
        }.joined(separator: "·")
    }
    static var myFingerprint: String { fingerprint(ofPubBase64: identityPublicKeyBase64()) }

    // MARK: - 봉인 / 복호

    /// 상대 공개키(base64)로 봉인 + 내 개인키로 발신자 인증. 반환 = base64(version‖enc‖ct).
    static func seal(_ plaintext: String, toRecipientPubBase64 pub: String, aad: Data) throws -> String {
        guard let pubData = Data(base64Encoded: pub) else { throw DMCryptoError.badKey }
        let recipientPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubData)
        var sender = try HPKE.Sender(recipientKey: recipientPub, ciphersuite: ciphersuite,
                                     info: info, authenticatedBy: identityPrivateKey())
        let ct = try sender.seal(Data(plaintext.utf8), authenticating: aad)
        var blob = Data([version])
        blob.append(sender.encapsulatedKey)   // X25519 → 32B
        blob.append(ct)
        return blob.base64EncodedString()
    }

    /// 발신자 공개키(base64)로 복호 + 발신자 인증 검증. blob = base64(version‖enc‖ct).
    static func open(_ blobBase64: String, fromSenderPubBase64 pub: String, aad: Data) throws -> String {
        guard let blob = Data(base64Encoded: blobBase64), blob.count > 1 + encLen,
              blob.first == version,
              let senderPubData = Data(base64Encoded: pub) else { throw DMCryptoError.badBlob }
        let enc = blob.subdata(in: 1..<(1 + encLen))
        let ct = blob.subdata(in: (1 + encLen)..<blob.count)
        let senderPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPubData)
        var recipient = try HPKE.Recipient(privateKey: identityPrivateKey(), ciphersuite: ciphersuite,
                                           info: info, encapsulatedKey: enc, authenticatedBy: senderPub)
        let pt = try recipient.open(ct, authenticating: aad)
        return String(decoding: pt, as: UTF8.self)
    }

    /// aad — 발신·수신 device + 버전 바인딩(리플레이/오배송 방지).
    static func aad(senderDevice: String, recipientDevice: String) -> Data {
        Data("\(senderDevice.lowercased())|\(recipientDevice.lowercased())|\(version)".utf8)
    }
}
