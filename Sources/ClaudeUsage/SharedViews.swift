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
