import SwiftUI

// 차트 라인 아래(=펫이 서 있는 땅) 영역을 채우는 자연 테마.
// 다크모드 고정 톤: 채도 낮추고 brightness 중간 → 두 모드에서 모두 자연스럽게 보임.
enum PetTheme: String, CaseIterable, Identifiable, Codable {
    case grassland   // 잔디밭 (밝은 풀색)
    case field       // 들판 (말린 풀, 황록)
    case wilderness  // 황야 (마른 흙, 황갈)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grassland:  return "잔디밭"
        case .field:      return "들판"
        case .wilderness: return "황야"
        }
    }

    // 위쪽(라인 근처) 색
    var topColor: Color {
        switch self {
        case .grassland:  return Color(hue: 0.30, saturation: 0.40, brightness: 0.55)
        case .field:      return Color(hue: 0.20, saturation: 0.35, brightness: 0.55)
        case .wilderness: return Color(hue: 0.10, saturation: 0.30, brightness: 0.50)
        }
    }
    // 아래쪽(x축 쪽) 색
    var bottomColor: Color {
        switch self {
        case .grassland:  return Color(hue: 0.30, saturation: 0.50, brightness: 0.40)
        case .field:      return Color(hue: 0.13, saturation: 0.45, brightness: 0.45)
        case .wilderness: return Color(hue: 0.07, saturation: 0.45, brightness: 0.40)
        }
    }
    // 라인 색: bottomColor 보다 진하고 채도 높여서 가독성 확보
    var lineColor: Color {
        switch self {
        case .grassland:  return Color(hue: 0.30, saturation: 0.70, brightness: 0.45)
        case .field:      return Color(hue: 0.13, saturation: 0.65, brightness: 0.50)
        case .wilderness: return Color(hue: 0.07, saturation: 0.65, brightness: 0.45)
        }
    }

    // chartBackground 용 그라디언트 (위 옅게, 아래 살짝 진하게).
    // AreaMark는 데이터 0 구간에서 빈 채로 렌더되어 신뢰가 어려워서
    // 라인-x축 사이를 따라가는 fill 대신 plot 전체 backdrop 으로 운영.
    var gradient: LinearGradient {
        LinearGradient(
            colors: [
                topColor.opacity(0.10),
                bottomColor.opacity(0.28),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 펫별 기본 테마 — 자연스러운 서식지 매핑.
    /// 같은 테마가 두 차트에 겹치지 않게, fox는 grassland로 분리.
    static func defaultFor(_ kind: PetKind) -> PetTheme {
        switch kind {
        case .fox:           return .grassland
        case .wolf:          return .wilderness
        case .bear:          return .grassland
        case .boar:          return .field
        case .deer:          return .grassland
        case .rabbit:        return .grassland
        case .maskDude:      return .wilderness
        case .ninjaFrog:     return .grassland
        case .mushroom:      return .field
        case .slime:         return .wilderness
        }
    }
}
