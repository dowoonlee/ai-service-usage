import Foundation

extension Error {
    /// 사용자에게 보여줄 에러 문구. Swift 기본 `localizedDescription`은 커스텀
    /// `LocalizedError.errorDescription`을 태우지 못하는 경우가 있어(NSError 브리징 함정),
    /// LocalizedError면 그 설명을 우선 쓰고 아니면 기본 설명으로 폴백한다.
    /// 뷰/뷰모델의 에러 표시 지점들이 각자 반복하던 `(self as? LocalizedError)?.errorDescription
    /// ?? localizedDescription` 표현식을 한 곳으로 모은 것.
    var friendlyDescription: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
