import AppKit
import SwiftUI

/// 트레이너(레포트) 카드 팝오버가 화면 경계를 넘어 잘리지 않도록 arrow edge를 고른다.
///
/// 배경: 카드는 폭이 크다(≈480pt). 리더보드/기여자/길드 목록의 카드 팝오버는 `arrowEdge: .leading`
/// 으로 고정돼 행의 **왼쪽**에 떴는데, 좁은 앱 창이 화면 오른쪽에 치우쳐 있으면 카드가 화면 왼쪽
/// 경계를 넘어 **좌측이 잘리고**(닉네임·BADGES·SETS 앞부분) 세로로 눌려 보였다.
///
/// 해결: 호버된 행의 **화면 절대 왼쪽 x**를 구해, 그 왼쪽에 카드 폭만큼 공간이 있으면 왼쪽
/// (leading)으로, 없으면 오른쪽(trailing)으로 띄워 화면 안에 들어오게 한다. 창/화면을 못 찾으면
/// 기존 동작(.leading)을 유지해 최소한 회귀는 없다.
///
/// - Parameter rowWindowMinX: 행의 **창 내부** 왼쪽 x (`GeometryReader`의 `frame(in: .global).minX`).
@MainActor
func adaptiveCardArrowEdge(rowWindowMinX: CGFloat, cardWidth: CGFloat = 490) -> Edge {
    guard let win = NSApp.keyWindow ?? NSApp.mainWindow, let screen = win.screen else {
        return .leading
    }
    // 행의 화면상 왼쪽 x = 창의 화면 x + 행의 창 내부 x (창이 놓인 화면 원점 기준으로 정규화).
    // .global(window 좌표, 상단 원점)과 NSWindow.frame(화면 좌표, 하단 원점)은 x축 방향이 같아 그대로 합산.
    let rowScreenMinX = win.frame.minX + rowWindowMinX - screen.frame.minX
    // 행 왼쪽에 카드 폭만큼 화면 공간이 있으면 왼쪽, 없으면 오른쪽으로 flip.
    return rowScreenMinX >= cardWidth ? .leading : .trailing
}
