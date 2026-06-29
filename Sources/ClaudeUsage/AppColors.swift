import SwiftUI

/// 앱 전역 색 토큰. 여러 View에 흩어져 중복 정의되던 메달/강조 색을 한 곳에 모은다.
/// (rarity 색 체계 등 자체 의미군을 이루는 색은 각 소비처에 둔다.)
enum AppColors {
    /// 1위·하이라이트용 금색. (메달 1위 자체는 시스템 `.yellow`를 쓰는 곳도 있음)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.2)
    /// 3위용 동색.
    static let bronze = Color(red: 0.8, green: 0.5, blue: 0.2)
}

/// 앱 전역 모서리 둥글기(corner radius) 토큰. 여러 View에 흩어진 값 중
/// 일관된 스케일로 반복되는 4개를 의미 단위로 모은다. 값은 기존 그대로(무손실).
/// (스피치버블 5·14, 칩 3, 레어카드 12 등 특정 컴포넌트 전용 일회성 값은
///  각 소비처에 리터럴로 둔다.)
enum AppRadius {
    /// 작은 배지·막대·셀 (4pt)
    static let sm: CGFloat = 4
    /// 기본 카드·패널 (6pt, 최빈)
    static let md: CGFloat = 6
    /// 큰 카드·버튼·클립 (8pt)
    static let lg: CGFloat = 8
    /// 강조 패널·썸네일 (10pt)
    static let xl: CGFloat = 10
}
