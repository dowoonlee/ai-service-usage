import AppKit
import SwiftUI

/// 도장 jewel PNG 로더 — `Resources/intersect-jewels/` 안 8개 sprite.
/// PetSprite와 동일하게 SwiftPM 자동생성 bundle + .app Resources 둘 다 fallback.
extension NSImage {
    static func gymJewel(named name: String) -> NSImage? {
        loadResourceImage(name)
    }
    static func mapTile(named name: String) -> NSImage? {
        loadResourceImage(name)
    }
    private static func loadResourceImage(_ name: String) -> NSImage? {
        let bundle: Bundle = {
            if let url = Bundle.main.url(forResource: "ClaudeUsage_ClaudeUsage", withExtension: "bundle"),
               let b = Bundle(url: url) { return b }
            return .module
        }()
        guard let url = bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

// 픽셀 아이콘 렌더러 — SVG path 문자열을 axis-aligned 사각형 집합으로 파싱해서 Canvas에 칠함.
//
// 출처: pixelarticons (MIT) — https://github.com/halfmage/pixelarticons
// 사용한 4개 아이콘: coffee / robot-face / clock / warehouse (24×24 viewBox).
//
// pixelarticons의 path는 모두 axis-aligned rectangle 조합(M/m/h/v/H/V/z)이라
// 단순 파서로 충분. SwiftUI Image는 SVG를 macOS 13에서 지원 안 하고, NSImage(svg) 도
// macOS 14+ 한정이라 우회. 결과는 우리 펫 픽셀 톤과 일관된 1-bit 픽셀 아이콘.

struct PixelIcon {
    let viewBox: CGSize
    let pathData: String

    /// path 문자열을 사각형 배열로 파싱. axis-aligned 가정 — 다른 명령(C, S, A 등)은 무시.
    func rects() -> [CGRect] {
        var result: [CGRect] = []
        var cursor = CGPoint.zero
        var subStart = CGPoint.zero
        var subPoints: [CGPoint] = []

        let scanner = Scanner(string: pathData)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))

        func closeSubpath() {
            let xs = subPoints.map { $0.x }
            let ys = subPoints.map { $0.y }
            if let minX = xs.min(), let maxX = xs.max(),
               let minY = ys.min(), let maxY = ys.max(),
               maxX > minX, maxY > minY {
                result.append(CGRect(x: minX, y: minY,
                                     width: maxX - minX, height: maxY - minY))
            }
            cursor = subStart
            subPoints = [cursor]
        }

        while !scanner.isAtEnd {
            guard let cmd = scanner.scanCharacter() else { break }
            switch cmd {
            case "M":
                let x = scanner.scanDouble() ?? 0
                let y = scanner.scanDouble() ?? 0
                cursor = CGPoint(x: x, y: y)
                subStart = cursor
                subPoints = [cursor]
            case "m":
                let x = scanner.scanDouble() ?? 0
                let y = scanner.scanDouble() ?? 0
                cursor.x += x; cursor.y += y
                subStart = cursor
                subPoints = [cursor]
            case "h":
                let dx = scanner.scanDouble() ?? 0
                cursor.x += dx
                subPoints.append(cursor)
            case "H":
                let x = scanner.scanDouble() ?? 0
                cursor.x = x
                subPoints.append(cursor)
            case "v":
                let dy = scanner.scanDouble() ?? 0
                cursor.y += dy
                subPoints.append(cursor)
            case "V":
                let y = scanner.scanDouble() ?? 0
                cursor.y = y
                subPoints.append(cursor)
            case "L":
                let x = scanner.scanDouble() ?? 0
                let y = scanner.scanDouble() ?? 0
                cursor = CGPoint(x: x, y: y)
                subPoints.append(cursor)
            case "l":
                let dx = scanner.scanDouble() ?? 0
                let dy = scanner.scanDouble() ?? 0
                cursor.x += dx; cursor.y += dy
                subPoints.append(cursor)
            case "z", "Z":
                closeSubpath()
            default:
                // 알 수 없는 명령 — 숫자 인자 흡수해서 다음 명령으로 넘어감.
                _ = scanner.scanDouble()
            }
        }
        return result
    }
}

struct PixelIconView: View {
    let icon: PixelIcon
    var color: Color = .primary

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / icon.viewBox.width
            let scaleY = size.height / icon.viewBox.height
            for r in icon.rects() {
                let scaled = CGRect(
                    x: r.minX * scaleX,
                    y: r.minY * scaleY,
                    width: r.width * scaleX,
                    height: r.height * scaleY
                )
                context.fill(Path(scaled), with: .color(color))
            }
        }
    }
}

/// 도장 뱃지용 보석 모양 — octagonal cushion cut (8각형). 카테고리 색으로 fill, tier 색으로 stroke.
/// 픽셀 RPG 결과 어울리는 angular한 보석 컷.
struct GemShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dy = rect.height * 0.28
        let dx = rect.width * 0.28
        let l = rect.minX, r = rect.maxX, t = rect.minY, b = rect.maxY
        let cx = rect.midX
        p.move(to: CGPoint(x: cx - dx, y: t))
        p.addLine(to: CGPoint(x: cx + dx, y: t))
        p.addLine(to: CGPoint(x: r, y: t + dy))
        p.addLine(to: CGPoint(x: r, y: b - dy))
        p.addLine(to: CGPoint(x: cx + dx, y: b))
        p.addLine(to: CGPoint(x: cx - dx, y: b))
        p.addLine(to: CGPoint(x: l, y: b - dy))
        p.addLine(to: CGPoint(x: l, y: t + dy))
        p.closeSubpath()
        return p
    }
}

/// 좌측에 꼬리가 있는 말풍선 — 도장 관장 대사용.
/// rect 좌측 가운데에 sprite를 가리키는 삼각 tail이 붙은 둥근 사각형.
struct SpeechBubble: Shape {
    var tailWidth: CGFloat = 8
    var tailHeight: CGFloat = 6
    var cornerRadius: CGFloat = 8

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let bodyRect = CGRect(
            x: rect.minX + tailWidth,
            y: rect.minY,
            width: rect.width - tailWidth,
            height: rect.height
        )
        p.addRoundedRect(in: bodyRect,
                         cornerSize: CGSize(width: cornerRadius, height: cornerRadius))
        // tail — 좌측 가운데, sprite 방향.
        let cy = rect.midY
        p.move(to: CGPoint(x: rect.minX, y: cy))
        p.addLine(to: CGPoint(x: rect.minX + tailWidth, y: cy - tailHeight))
        p.addLine(to: CGPoint(x: rect.minX + tailWidth, y: cy + tailHeight))
        p.closeSubpath()
        return p
    }
}

/// 보석 안에 highlight stripe 1줄 — cleared 상태에서 입체감.
struct GemHighlight: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dy = rect.height * 0.28
        let dx = rect.width * 0.28
        p.move(to: CGPoint(x: rect.midX - dx + 2, y: rect.minY + 2))
        p.addLine(to: CGPoint(x: rect.minX + 3, y: rect.minY + dy + 2))
        p.addLine(to: CGPoint(x: rect.minX + 3, y: rect.maxY - dy - 2))
        return p
    }
}

/// 도장 뱃지용 픽셀 sprite — tier별 화려함 표현.
/// localhost = sparkle (단순 반짝) / dev = diamond-gem / staging = gem + sparkle deco /
/// production = gem + crown + sparkles. 모든 sprite는 pixelarticons MIT.
enum BadgePixelIcons {
    static let diamondGem = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: "M7 1h10v2H7zM5 3h2v2H5zm12 0h2v2h-2zm2 2h2v2h-2zm0 8h2v2h-2zm-2 2h2v2h-2zm-2 2h2v2h-2zm-2 2h2v2h-2zm-2 2h2v2h-2zm-2-2h2v2H9zm-2-2h2v2H7zm-2-2h2v2H5zm-2-2h2v2H3zm0-8h2v2H3zM1 7h2v6H1zm20 0h2v6h-2zM3 9h18v2H3zm6-6h2v3H9zM7 6h2v3H7zm8 0h2v3h-2zm-8 5h2v2H7zm2 2h2v3H9zm2 3h2v3h-2zm2-3h2v3h-2zm2-2h2v2h-2zm-2-8h2v3h-2z"
    )
    static let sparkle = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: "M11 1h2v4h-2zm0 22h2v-4h-2zM9 5h2v4H9zm0 14h2v-4H9zm4-14h2v4h-2zm0 14h2v-4h-2zM5 9h4v2H5zm14 0h-4v2h4zM1 11h4v2H1zm22 0h-4v2h4zM5 13h4v2H5zm14 0h-4v2h4z"
    )
    static let crown = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: """
        M3 3h2v12H3zm16 0h2v12h-2zm-8 0h2v2h-2zM9 5h2v2H9zM5 5h2v2H5z
        M3 3h2v2H3zm4 4h2v2H7zm6-2h2v2h-2zm2 2h2v2h-2zm2-2h2v2h-2zM5 15h14v2H5zm-2 4h18v2H3z
        """
    )
}

/// 4 region별 pixelarticons 아이콘. multiple `<path>` element는 d= 문자열을 그냥 이어붙임.
enum RegionPixelIcons {
    static let coffee = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: "M4 4h16v2H4zm0 2h2v8H4zm2 8h10v2H6zm14-8h2v4h-2zm-2 4h2v2h-2zm-2-4h2v8h-2zM2 18h18v2H2z"
    )
    static let robotFace = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: """
        M4 6h16v2H4zm0 14h16v2H4zM2 8h2v12H2zm18 0h2v12h-2z
        M11 4h2v4h-2zm-3 6h2v2H8zm6 0h4v2h-4zm-1-8h4v2h-4zM0 12h2v2H0zm22 0h2v2h-2zm-12 4h4v2h-4zm-2-2h2v2H8zm6 0h2v2h-2z
        """
    )
    static let clock = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: "M6 2h12v2H6zM2 6h2v12H2zm18 0h2v12h-2zm-2-2h2v2h-2zM4 4h2v2H4zm2 18h12v-2H6zm12-2h2v-2h-2zM4 20h2v-2H4zm7-14h2v7h-2zm2 7h2v2h-2zm2 2h2v2h-2z"
    )
    static let warehouse = PixelIcon(
        viewBox: CGSize(width: 24, height: 24),
        pathData: """
        M6 10h12v2H6z
        M6 10h2v10H6zm2 5h8v2H8zm-6 5h20v2H2zm14-10h2v10h-2z
        M2 6h2v16H2z
        M2 6h4v2H2zm4-2h4v2H6zm8 0h4v2h-4zm4 2h4v2h-4zm-8-4h4v2h-4z
        M20 6h2v16h-2z
        """
    )
}
