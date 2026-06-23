import SwiftUI

/// 앱 전역 색 토큰. 여러 View에 흩어져 중복 정의되던 메달/강조 색을 한 곳에 모은다.
/// (rarity 색 체계 등 자체 의미군을 이루는 색은 각 소비처에 둔다.)
enum AppColors {
    /// 1위·하이라이트용 금색. (메달 1위 자체는 시스템 `.yellow`를 쓰는 곳도 있음)
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.2)
    /// 3위용 동색.
    static let bronze = Color(red: 0.8, green: 0.5, blue: 0.2)
}
