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

extension Calendar {
    /// UTC 고정 그레고리력 — Cursor 청구 기간 경계 계산 전용.
    ///
    /// `CursorAPI.parseUsage`가 resetAt을 UTC 기준 `startOfMonth + 1개월`로 만들므로, 이를
    /// 역산(-1개월)하는 모든 곳도 같은 UTC 캘린더를 써야 한다. 로컬 캘린더로 역산하면 DST
    /// 전환이 낀 달에 최대 1시간 어긋나 이벤트 컷오프·기간 길이가 틀어진다. `Calendar`는
    /// 값 타입이라 static let 공유 안전.
    static let utcGregorian: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
