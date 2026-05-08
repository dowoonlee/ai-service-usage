import Foundation

extension Date {
    /// ISO8601 timestamp 문자열 파싱 — fractional seconds 있는/없는 두 포맷 모두 지원.
    ///
    /// 기존엔 `UsageAPI.toSnapshot` / `CursorAPI` startOfMonth 파싱 / `Contributors.aggregate`
    /// 세 곳에 동일한 두 인스턴스 fallback 페어가 있었고, 매 호출마다 `ISO8601DateFormatter`를
    /// 두 개씩 새로 생성했음. `ISO8601DateFormatter`는 Apple이 thread-safe로 명시(=`DateFormatter`
    /// 와 다름)이므로 nonisolated static let으로 캐싱해 재사용해도 안전.
    ///
    /// 호출 측은 `Date.parseISO8601(s)` 한 줄로 정리.
    static func parseISO8601(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        if let d = _isoWithFractional.date(from: s) { return d }
        return _isoBasic.date(from: s)
    }

    private static let _isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let _isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
