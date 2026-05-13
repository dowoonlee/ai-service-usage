import Foundation

/// 랭킹 옵트인 시 기본 닉네임 자동 생성. `Trainer-A3F2-7K9X` 패턴 — prefix + 4자리 두 그룹.
///
/// 알파벳에서 0/O, 1/I/L 등 시각적으로 헷갈리는 글자는 제외 — 사용자가 화면에서 보고
/// 다른 기기로 입력할 가능성을 고려. 조합 ≈ 30^8 ≈ 6.5e11 → 50명 규모에서 충돌 무시 가능,
/// 서버측 case-insensitive unique 제약이 최후 방어선.
enum NicknameGenerator {
    private static let alphabet = Array("ABCDEFGHJKMNPQRTUVWXY23456789")

    static func generate() -> String {
        func chunk(_ n: Int) -> String {
            String((0..<n).map { _ in alphabet.randomElement() ?? "X" })
        }
        return "Trainer-\(chunk(4))-\(chunk(4))"
    }

    /// 입력 닉네임이 서버에 보낼 만한 형식인지 가벼운 검증. 서버측이 권위 있는 검증을 수행.
    /// - 3~24자 유니코드 스칼라
    /// - 공백/제어문자 없음
    /// - 욕설 필터는 서버에서 (locale별 word list 유지보수가 클라엔 부담)
    static func isValid(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == s else { return false }
        guard (3...24).contains(s.count) else { return false }
        return !s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }
    }
}
