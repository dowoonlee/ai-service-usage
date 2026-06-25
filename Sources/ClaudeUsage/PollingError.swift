import Foundation

/// 폴링 에러를 "endpoint 스키마 의심" 신호로 분류하기 위한 공통 인터페이스.
/// 새 API 소스를 추가할 때 그 에러 타입이 이 protocol만 채택하면
/// `ViewModel.isSchemaSuspect`가 별도 분기 추가 없이 자동으로 처리한다.
protocol PollingErrorClassifiable {
    /// 응답 디코딩 실패 여부 (스키마/경로 변경의 강한 신호).
    var isDecodingFailure: Bool { get }
    /// HTTP 상태 코드 (transport/도메인 에러면 nil).
    var httpStatusCode: Int? { get }
}

extension UsageError: PollingErrorClassifiable {
    var isDecodingFailure: Bool { if case .decoding = self { return true }; return false }
    var httpStatusCode: Int? { if case .http(let c) = self { return c }; return nil }
}

extension CursorError: PollingErrorClassifiable {
    var isDecodingFailure: Bool { if case .decoding = self { return true }; return false }
    var httpStatusCode: Int? { if case .http(let c) = self { return c }; return nil }
}

extension CodexError: PollingErrorClassifiable {
    // .unrecognizedSchema(전면 드리프트)도 디코딩 실패와 동급으로 취급 → apiSchemaSuspect 경로로 보냄.
    var isDecodingFailure: Bool {
        switch self { case .decoding, .unrecognizedSchema: return true; default: return false }
    }
    var httpStatusCode: Int? { if case .http(let c) = self { return c }; return nil }
}
