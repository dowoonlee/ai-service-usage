import AppKit
import SwiftUI

/// 강화 대상 위에서는 일반 마우스의 세로 휠도 가로 이동으로 처리한다.
/// 트랙패드의 가로 제스처와 스크롤바 드래그도 함께 지원한다.
/// 트랙패드의 세로 제스처와, 끝에 닿은 뒤의 휠 입력은 바깥(탭의 세로 스크롤)으로 넘긴다 —
/// 여기서 삼키면 포인터가 목록 위에 있는 동안 페이지가 멈춘 것처럼 보인다.
struct EnhanceTargetScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EnhanceTargetNativeScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = NSHostingView(rootView: AnyView(content().fixedSize()))
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let host = nsView.documentView as? NSHostingView<AnyView> else { return }
        host.rootView = AnyView(content().fixedSize())
        nsView.needsLayout = true
    }
}

private final class EnhanceTargetNativeScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let documentView else { return }
        let viewport = contentView.bounds.size
        let size = documentView.fittingSize
        documentView.setFrameSize(NSSize(width: max(size.width, viewport.width), height: viewport.height))
        let maxX = max(0, documentView.frame.width - viewport.width)
        contentView.scroll(to: NSPoint(x: min(max(0, contentView.bounds.minX), maxX), y: 0))
        reflectScrolledClipView(contentView)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView, documentView.frame.width > contentView.bounds.width else {
            super.scrollWheel(with: event)
            return
        }
        // 대각선 입력은 큰 축 하나만 사용해 두 배로 빨라지는 것을 방지한다.
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        let precise = event.hasPreciseScrollingDeltas
        // 세로→가로 변환은 일반 휠만. 트랙패드·매직마우스의 세로 제스처는 페이지 스크롤이다.
        if precise && !horizontal {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
        let distance = delta * (precise ? 1 : 20)
        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        let current = contentView.bounds.minX
        let x = min(max(0, current - distance), maxX)
        // 휠로 이미 끝에 닿아 더 움직일 수 없으면 페이지 스크롤로 이어지게 한다.
        if !horizontal && x == current {
            nextResponder?.scrollWheel(with: event)
            return
        }
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
}
