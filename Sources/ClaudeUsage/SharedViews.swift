import SwiftUI

/// 랭킹 미참여·빈 상태 안내용 공용 게이트 뷰. Board/DM/Guild/Ranking이 아이콘만 바꿔
/// 동일 레이아웃(28pt 심볼 + 12pt 회색 중앙정렬 문구)을 각자 정의하던 것을 하나로 모은다.
struct GateMessageView: View {
    let icon: String        // SF Symbol
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(.secondary)
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 알림 배지 (MainView 액션 아이콘 공용)

private struct DotBadge: ViewModifier {
    let show: Bool
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if show {
                Circle().fill(Color.red).frame(width: 5, height: 5).offset(x: 4, y: -2)
            }
        }
    }
}

private struct CountBadge: ViewModifier {
    let count: Int
    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if count > 0 {
                Text("\(min(count, 99))")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.red)
                    .clipShape(Capsule())
                    .offset(x: 6, y: -4)
            }
        }
    }
}

extension View {
    /// 우상단 빨간 점 배지 — 미확인 여부만 표시(퀴즈·운세 등).
    func dotBadge(_ show: Bool) -> some View { modifier(DotBadge(show: show)) }
    /// 우상단 빨간 숫자 배지 — 미확인 개수(99+ clamp, 쪽지·게시판).
    func countBadge(_ count: Int) -> some View { modifier(CountBadge(count: count)) }
}

// MARK: - FlowLayout

/// 줄바꿈 수평 배치 — 칩·셀이 컨테이너 폭을 넘으면 다음 줄로. `LazyVGrid`는 열 폭이 고정이라
/// 폭이 제각각인 칭호 칩에 맞지 않고, 가로 `ScrollView`는 뒤쪽 항목이 묻힌다(리포트 탭 칭호 66개).
/// 제안 폭이 없으면(unbounded) 한 줄로 늘어놓는다.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        return arrange(subviews: subviews, maxWidth: maxWidth).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = proposal.width ?? bounds.width
        let placed = arrange(subviews: subviews, maxWidth: maxWidth)
        for (i, origin) in placed.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                              proposal: .unspecified)
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        origins.reserveCapacity(subviews.count)
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            width = max(width, x - spacing)
        }
        return (CGSize(width: width, height: y + lineHeight), origins)
    }
}
