import SwiftUI

// 차트 라인 아래(=펫이 서 있는 땅) 영역을 채우는 자연 테마.
// 다크모드 고정 톤: 채도 낮추고 brightness 중간 → 두 모드에서 모두 자연스럽게 보임.
enum PetTheme: String, CaseIterable, Identifiable, Codable {
    case grassland   // 잔디밭 (밝은 풀색)
    case field       // 들판 (말린 풀, 황록)
    case wilderness  // 황야 (마른 흙, 황갈)
    case sea         // 바다 (파랑)
    case snowMountain // 설산 (눈 덮인 산 — 사용량 임계값 넘으면 정상부부터 하얘짐, 동적)
    case desert      // 사막 (모래언덕, 황토→모래)
    case volcano     // 화산 (아래 용암 적색 → 위 암석)
    case space       // 우주 (밤하늘 남색 → 보라 성운)
    case aurora      // 오로라 (극야 — 사용량↑ 오로라 커튼이 위에서, 동적)
    case sakura      // 벚꽃 (봄 — 사용량↑ 분홍 개화가 위에서, 동적)
    case storm       // 뇌우 (폭풍 — 사용량↑ 먹구름이 위에서, 동적)
    case toxic       // 독성 늪 (toxic — 사용량↑ 형광 녹 독이 아래에서, 동적)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grassland:   return "잔디밭"
        case .field:       return "들판"
        case .wilderness:  return "황야"
        case .sea:         return "바다"
        case .snowMountain: return "설산"
        case .desert:      return "사막"
        case .volcano:     return "화산"
        case .space:       return "우주"
        case .aurora:      return "오로라"
        case .sakura:      return "벚꽃"
        case .storm:       return "뇌우"
        case .toxic:       return "독성 늪"
        }
    }

    // 위쪽(라인 근처) 색
    var topColor: Color {
        switch self {
        case .grassland:    return Color(hue: 0.30, saturation: 0.40, brightness: 0.55)
        case .field:        return Color(hue: 0.20, saturation: 0.35, brightness: 0.55)
        case .wilderness:   return Color(hue: 0.10, saturation: 0.30, brightness: 0.50)
        case .sea:          return Color(hue: 0.58, saturation: 0.40, brightness: 0.60)
        case .snowMountain: return Color(hue: 0.60, saturation: 0.12, brightness: 0.62)
        case .desert:       return Color(hue: 0.11, saturation: 0.35, brightness: 0.62)
        case .volcano:      return Color(hue: 0.02, saturation: 0.30, brightness: 0.40)
        case .space:        return Color(hue: 0.66, saturation: 0.45, brightness: 0.40)
        case .aurora:       return Color(hue: 0.70, saturation: 0.45, brightness: 0.30)
        case .sakura:       return Color(hue: 0.95, saturation: 0.22, brightness: 0.62)
        case .storm:        return Color(hue: 0.62, saturation: 0.15, brightness: 0.42)
        case .toxic:        return Color(hue: 0.25, saturation: 0.30, brightness: 0.35)
        }
    }
    // 아래쪽(x축 쪽) 색
    var bottomColor: Color {
        switch self {
        case .grassland:    return Color(hue: 0.30, saturation: 0.50, brightness: 0.40)
        case .field:        return Color(hue: 0.13, saturation: 0.45, brightness: 0.45)
        case .wilderness:   return Color(hue: 0.07, saturation: 0.45, brightness: 0.40)
        case .sea:          return Color(hue: 0.60, saturation: 0.55, brightness: 0.40)
        case .snowMountain: return Color(hue: 0.62, saturation: 0.30, brightness: 0.38)
        case .desert:       return Color(hue: 0.09, saturation: 0.55, brightness: 0.45)
        case .volcano:      return Color(hue: 0.03, saturation: 0.80, brightness: 0.55)
        case .space:        return Color(hue: 0.75, saturation: 0.55, brightness: 0.35)
        case .aurora:       return Color(hue: 0.66, saturation: 0.50, brightness: 0.22)
        case .sakura:       return Color(hue: 0.96, saturation: 0.38, brightness: 0.50)
        case .storm:        return Color(hue: 0.62, saturation: 0.12, brightness: 0.30)
        case .toxic:        return Color(hue: 0.22, saturation: 0.45, brightness: 0.30)
        }
    }
    // 라인 색: bottomColor 보다 진하고 채도 높여서 가독성 확보
    var lineColor: Color {
        switch self {
        case .grassland:    return Color(hue: 0.30, saturation: 0.70, brightness: 0.45)
        case .field:        return Color(hue: 0.13, saturation: 0.65, brightness: 0.50)
        case .wilderness:   return Color(hue: 0.07, saturation: 0.65, brightness: 0.45)
        case .sea:          return Color(hue: 0.58, saturation: 0.75, brightness: 0.55)
        case .snowMountain: return Color(hue: 0.60, saturation: 0.35, brightness: 0.70)
        case .desert:       return Color(hue: 0.08, saturation: 0.70, brightness: 0.55)
        case .volcano:      return Color(hue: 0.04, saturation: 0.90, brightness: 0.65)
        case .space:        return Color(hue: 0.72, saturation: 0.70, brightness: 0.70)
        case .aurora:       return Color(hue: 0.45, saturation: 0.65, brightness: 0.75)
        case .sakura:       return Color(hue: 0.95, saturation: 0.55, brightness: 0.72)
        case .storm:        return Color(hue: 0.60, saturation: 0.22, brightness: 0.62)
        case .toxic:        return Color(hue: 0.25, saturation: 0.85, brightness: 0.78)
        }
    }

    // fill 그라디언트의 기본(정적/동적 level 0) stop들. location 0 = top/라인 근처, 1 = bottom/x축.
    // opacity는 위 옅게 → 아래 진하게 규칙. 정적 테마는 중간 stop을 더해 멀티컬러로 풍부하게.
    // 동적 테마(isDynamic)는 임계값 미만일 때 이 기본 톤을 쓰고, 넘으면 dynamicStops 가 덧입힌다.
    var baseStops: [Gradient.Stop] {
        switch self {
        // 잔디밭 — 위 햇빛 연두 → 중간 풀색 → 아래 진녹.
        case .grassland:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.32, saturation: 0.45, brightness: 0.48).opacity(0.20), location: 0.5),
                .init(color: bottomColor.opacity(0.32), location: 1),
            ]
        // 들판 — 위 옅은 황록 → 중간 풀빛 → 아래 진한 황록.
        case .field:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.16, saturation: 0.45, brightness: 0.50).opacity(0.20), location: 0.5),
                .init(color: bottomColor.opacity(0.32), location: 1),
            ]
        // 황야 — 위 옅은 흙 → 중간 마른 흙 → 아래 진한 황갈.
        case .wilderness:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.08, saturation: 0.42, brightness: 0.44).opacity(0.20), location: 0.55),
                .init(color: bottomColor.opacity(0.34), location: 1),
            ]
        // 바다(동적) — 기본: 위 옅은 물 → 아래 파랑. 수위↑면 dynamicStops 가 아래에서 심해를 차올린다.
        case .sea:
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: bottomColor.opacity(0.30), location: 1),
            ]
        // 설산(동적) — 기본: 암석 톤. 눈은 dynamicStops 가 위에서 덧입힌다.
        case .snowMountain:
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: bottomColor.opacity(0.30), location: 1),
            ]
        // 사막(동적) — 기본: 위 옅은 모래 → 중간 황토 → 아래 진한 모래. 노을은 dynamicStops 가 위에서 내려온다.
        case .desert:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.10, saturation: 0.50, brightness: 0.52).opacity(0.22), location: 0.55),
                .init(color: bottomColor.opacity(0.30), location: 1),
            ]
        // 화산(동적) — 기본: 위 암석 → 중간 주황 → 아래 적색. 용암은 dynamicStops 가 아래에서 차오른다.
        case .volcano:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.06, saturation: 0.75, brightness: 0.55).opacity(0.26), location: 0.55),
                .init(color: bottomColor.opacity(0.42), location: 1),
            ]
        // 우주 — 위 남색 밤하늘 → 중간 보라 성운 → 아래 진보라.
        case .space:
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: Color(hue: 0.78, saturation: 0.50, brightness: 0.45).opacity(0.24), location: 0.5),
                .init(color: bottomColor.opacity(0.32), location: 1),
            ]
        // 오로라(동적) — 기본: 어두운 밤하늘. 오로라는 dynamicStops 가 위에서 너울거린다.
        case .aurora:
            return [
                .init(color: topColor.opacity(0.16), location: 0),
                .init(color: bottomColor.opacity(0.34), location: 1),
            ]
        // 벚꽃(동적) — 기본: 옅은 분홍. 개화는 dynamicStops 가 위에서 진해진다.
        case .sakura:
            return [
                .init(color: topColor.opacity(0.10), location: 0),
                .init(color: Color(hue: 0.94, saturation: 0.35, brightness: 0.60).opacity(0.18), location: 0.5),
                .init(color: bottomColor.opacity(0.28), location: 1),
            ]
        // 뇌우(동적) — 기본: 흐린 회색 하늘. 먹구름은 dynamicStops 가 위에서 어둡게 깔린다.
        case .storm:
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: bottomColor.opacity(0.28), location: 1),
            ]
        // 독성 늪(동적) — 기본: 탁한 녹. 형광 독은 dynamicStops 가 아래에서 차오른다.
        case .toxic:
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: bottomColor.opacity(0.32), location: 1),
            ]
        }
    }

    // 사용량에 따라 fill 색이 변하는 동적 테마인지. 모두 "임계값 넘으면 강조색이 한쪽 가장자리에서
    // 차오르는" 공통 모델(edgeFillStops)을 쓴다: 설산=눈(위), 화산=용암(아래), 바다=심해(아래), 사막=노을(위).
    var isDynamic: Bool {
        switch self {
        case .snowMountain, .volcano, .sea, .desert,
             .aurora, .sakura, .storm, .toxic: return true
        default: return false
        }
    }

    // 정적 테마는 무료 기본 제공, 동적 테마는 코인 구매로 잠금 해제(= 구매 대상).
    var isFree: Bool { !isDynamic }

    // 코인 구매 가격. 무료(정적) 0, 입문 동적 1200, 프리미엄 동적 2000.
    var price: Int {
        switch self {
        case .grassland, .field, .wilderness, .space: return 0
        case .sea, .snowMountain, .desert, .volcano:  return 1200
        case .aurora, .sakura, .storm, .toxic:        return 2000
        }
    }

    // chartBackground 가 아니라 AreaMark(라인↓ 영역)에 직접 입히는 fill 그라디언트.
    // (v0.10.1에서 데이터 0구간 아티팩트를 해결해 backdrop → AreaMark fill 로 전환됨.)
    // pct/threshold 는 PetMood.from 과 동일하게 0~1 정규화( pct는 0~100, threshold는 0~1 )를 따른다.
    // 동적 테마는 pct 로 stop을 재계산하고, 그 외에는 baseStops 를 그대로 쓴다.
    func gradient(pct: Double? = nil, threshold: Double = 1) -> LinearGradient {
        let stops = isDynamic ? dynamicStops(pct: pct, threshold: threshold) : baseStops
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    // 호환용 — 정적 그라디언트가 필요한 호출부를 위한 무인자 접근자.
    var gradient: LinearGradient { gradient() }

    // 임계값(thr) 이전엔 level 0 → baseStops. 넘으면 level 0→1 로 연속 상승.
    private func dynamicStops(pct: Double?, threshold: Double) -> [Gradient.Stop] {
        let p = max(0, min(1, (pct ?? 0) / 100))
        let thr = max(0, min(0.99, threshold))
        let level = p <= thr ? 0 : (p - thr) / (1 - thr) // 0~1
        guard level > 0 else { return baseStops }
        switch self {
        case .snowMountain: // 눈: 위(정상)에서 흰색이 내려온다.
            return edgeFillStops(level: level, fromTop: true,
                edge: .white.opacity(0.55 + 0.30 * level),
                inner: .white.opacity(0.40 + 0.25 * level))
        case .volcano: // 용암: 아래에서 작열하는 주황이 차오른다.
            return edgeFillStops(level: level, fromTop: false,
                edge: Color(hue: 0.06, saturation: 0.95, brightness: 0.98).opacity(0.45 + 0.40 * level),
                inner: Color(hue: 0.03, saturation: 0.90, brightness: 0.75).opacity(0.38 + 0.30 * level))
        case .sea: // 심해: 아래에서 밝은 청록 수면 → 진청이 차오른다.
            return edgeFillStops(level: level, fromTop: false,
                edge: Color(hue: 0.50, saturation: 0.55, brightness: 0.90).opacity(0.40 + 0.35 * level),
                inner: Color(hue: 0.57, saturation: 0.70, brightness: 0.62).opacity(0.38 + 0.25 * level))
        case .desert: // 노을: 위에서 주황 → 핑크가 내려온다.
            return edgeFillStops(level: level, fromTop: true,
                edge: Color(hue: 0.04, saturation: 0.75, brightness: 0.92).opacity(0.40 + 0.35 * level),
                inner: Color(hue: 0.95, saturation: 0.55, brightness: 0.82).opacity(0.32 + 0.30 * level))
        case .aurora: // 오로라: 위에서 초록 → 청록 빛 커튼이 너울거린다.
            return edgeFillStops(level: level, fromTop: true,
                edge: Color(hue: 0.42, saturation: 0.65, brightness: 0.88).opacity(0.35 + 0.40 * level),
                inner: Color(hue: 0.50, saturation: 0.60, brightness: 0.75).opacity(0.30 + 0.30 * level))
        case .sakura: // 개화: 위에서 밝은 분홍이 진해진다.
            return edgeFillStops(level: level, fromTop: true,
                edge: Color(hue: 0.93, saturation: 0.50, brightness: 0.95).opacity(0.35 + 0.35 * level),
                inner: Color(hue: 0.96, saturation: 0.45, brightness: 0.85).opacity(0.30 + 0.28 * level))
        case .storm: // 먹구름: 위에서 어두운 회청이 깔린다(어두워질수록 위험).
            return edgeFillStops(level: level, fromTop: true,
                edge: Color(hue: 0.62, saturation: 0.28, brightness: 0.18).opacity(0.42 + 0.40 * level),
                inner: Color(hue: 0.62, saturation: 0.18, brightness: 0.32).opacity(0.34 + 0.28 * level))
        case .toxic: // 독: 아래에서 형광 녹이 차오른다.
            return edgeFillStops(level: level, fromTop: false,
                edge: Color(hue: 0.25, saturation: 0.90, brightness: 0.92).opacity(0.40 + 0.38 * level),
                inner: Color(hue: 0.28, saturation: 0.78, brightness: 0.70).opacity(0.34 + 0.28 * level))
        default:
            return baseStops
        }
    }

    // 강조색(edge=가장자리, inner=안쪽)이 한쪽 끝에서 level(0~1)에 비례해 차오르는 4-stop.
    // fromTop=true → 위(location 0)에서 아래로 / false → 아래(location 1)에서 위로.
    private func edgeFillStops(level: Double, fromTop: Bool, edge: Color, inner: Color) -> [Gradient.Stop] {
        let cov = min(0.92, max(0, level) * 0.85 + 0.06) // 덮는 비율 (최소 가시성 0.06)
        if fromTop {
            return [
                .init(color: edge, location: 0),
                .init(color: inner, location: cov * 0.65),
                .init(color: topColor.opacity(0.14), location: min(0.985, cov)),
                .init(color: bottomColor.opacity(0.30), location: 1),
            ]
        } else {
            return [
                .init(color: topColor.opacity(0.12), location: 0),
                .init(color: bottomColor.opacity(0.22), location: max(0.015, 1 - cov)),
                .init(color: inner, location: 1 - cov * 0.65),
                .init(color: edge, location: 1),
            ]
        }
    }

    /// 펫별 기본 테마 — `PetKind.def.defaultTheme` 으로 직접 접근. 호환용 wrapper.
    static func defaultFor(_ kind: PetKind) -> PetTheme {
        kind.def.defaultTheme
    }
}
