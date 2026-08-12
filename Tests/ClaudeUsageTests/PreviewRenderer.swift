import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import ClaudeUsage

/// 시각 검수용 렌더 파이프라인의 공용 도구.
///
/// 왜 필요한가 — 이 앱의 그림 대부분(펫 스프라이트, 트레이너 카드, 도장/아레나/길드 화면)은
/// 클릭으로만 도달하는 창 안에 있어서, 손볼 때마다 GUI를 띄워야 눈으로 확인됐다. 그 dev 실행은
/// 실사용 keychain을 건드리고, 195종 펫처럼 수가 많은 것은 애초에 하나씩 클릭해 볼 수가 없다.
///
/// `ImageRenderer`로 뷰만 PNG로 구우면 앱 없이, 실데이터 없이, 한 번에 전부 확인할 수 있다.
/// 스프라이트 시트 결함은 자동 지표로 판정하면 오탐이 많아 **육안 확인이 정답**이므로
/// (docs/research 및 과거 시도 참조) 이 파이프라인의 목적은 판정이 아니라 **한눈에 늘어놓기**다.
///
///     bash scripts/render-previews.sh          # 전부 굽고 갤러리를 브라우저로 연다
///     bash scripts/render-previews.sh pet      # 펫만
///
/// `PREVIEW_OUT_DIR`이 없으면 모든 프리뷰 테스트는 skip된다 — CI와 일반 `swift test`는 영향 없음.
@MainActor
enum PreviewRenderer {

    /// 출력 루트. 미설정이면 프리뷰 테스트가 통째로 skip된다.
    static var outputRoot: URL? = {
        guard let path = ProcessInfo.processInfo.environment["PREVIEW_OUT_DIR"], !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 프리뷰 테스트 첫 줄에서 호출 — 출력 경로가 없으면 skip시킨다.
    static func requireOutputDir() throws -> URL {
        guard let root = outputRoot else {
            throw XCTSkip("PREVIEW_OUT_DIR 미설정 — 시각 검수 전용 (scripts/render-previews.sh)")
        }
        return root
    }

    // MARK: - 렌더

    /// SwiftUI 뷰를 PNG로 굽고 갤러리 매니페스트에 등록한다.
    ///
    /// - Parameters:
    ///   - width: 지정하면 그 폭으로 고정해 렌더한다. 창 안에 들어가는 뷰는 실제 창 폭을 줘야
    ///            줄바꿈·잘림이 실제와 같아진다(예: 가챠 탭은 최소 폭 560).
    ///   - note: 갤러리에 함께 표시할 설명. 무엇을 봐야 하는지 적어두면 검수가 빨라진다.
    @discardableResult
    static func render(_ view: some View,
                       section: String,
                       title: String,
                       note: String? = nil,
                       width: CGFloat? = nil,
                       scale: CGFloat = 2,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> CGSize {
        let root = try requireOutputDir()
        let sized = Group {
            if let width { AnyView(view.frame(width: width)) } else { AnyView(view) }
        }
        let renderer = ImageRenderer(content: sized)
        renderer.scale = scale
        guard let image = renderer.nsImage else {
            XCTFail("렌더 실패: \(section)/\(title)", file: file, line: line)
            return .zero
        }
        try write(image, root: root, section: section, title: title, note: note)
        return image.size
    }

    /// 실제 창에 올려서 렌더한다 — `ImageRenderer`로는 빈 그림이 나오는 뷰용.
    ///
    /// `ImageRenderer`는 SwiftUI를 오프스크린에서 다시 그리는 별도 경로라 `ScrollView` 안쪽
    /// 콘텐츠가 통째로 비어 나온다(가챠 탭은 전부 최상위 ScrollView라 100% 해당). `GeometryReader`가
    /// 0 크기를 받아 납작해지는 것도 같은 이유다. 여기서는 `NSHostingView`를 실제 창의 contentView로
    /// 올리고 AppKit 렌더 경로로 캡처하므로 앱에서 보는 그림과 같아진다.
    ///
    /// 창은 화면 밖 좌표에 두어 눈에 보이지 않는다. 대신 **보이는 영역만** 캡처되므로,
    /// 스크롤이 필요한 탭은 잘린 채로 찍힌다 — 그게 곧 "실제 창에서 사용자가 보는 화면"이라
    /// 잘림 검수에는 이쪽이 맞다. 전체 콘텐츠를 보고 싶으면 `size.height`를 크게 주면 된다.
    @discardableResult
    static func renderInWindow(_ view: some View,
                               size: CGSize,
                               section: String,
                               title: String,
                               note: String? = nil,
                               warmup: TimeInterval = 0.35,
                               appearance: NSAppearance.Name = .aqua,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> CGSize {
        let root = try requireOutputDir()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // appearance를 명시하지 않으면 창은 시스템 설정을 따르는데, 캡처된 비트맵의 배경은
        // 흰색으로 남는다. 다크 모드 기계에서 찍으면 `.secondary` 같은 시맨틱 색이 흰 글씨로
        // 그려져 흰 배경에 그대로 묻힌다(도장 탭의 도전 조건 줄이 통째로 사라져 보였던 원인).
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .windowBackgroundColor
        // 화면 밖 — 렌더는 되지만 사용자 눈에는 안 띈다.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        // 배경을 **뷰에** 입힌다. cacheDisplay는 뷰가 그린 것만 캡처하고 창 배경은 담지 않아서,
        // SwiftUI 뷰가 자체 배경을 안 그리면 비트맵이 흰색으로 남는다. 다크 모드에서는 흰 글씨가
        // 흰 배경에 묻혀 화면이 통째로 빈 것처럼 보인다.
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        host.layoutSubtreeIfNeeded()
        // 첫 레이아웃 패스만으로는 부족하다. GeometryReader는 1패스에서 0 크기를 보고하고 다음
        // 패스에서야 확정되며, 이미지·비동기 리소스도 첫 패스에 안 붙는 경우가 있다. 너무 짧게
        // 잡으면 GeometryReader를 쓰는 행이 0폭으로 뭉개진 채 찍힌다(도장 탭에서 실제로 그랬다).
        RunLoop.current.run(until: Date().addingTimeInterval(warmup))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("비트맵 생성 실패: \(section)/\(title)", file: file, line: line)
            return .zero
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        try write(image, root: root, section: section, title: title, note: note)
        return size
    }

    /// 이미 만들어진 `NSImage`(스프라이트 컨택트 시트 등)를 그대로 등록한다.
    static func writeImage(_ image: NSImage,
                           section: String,
                           title: String,
                           note: String? = nil) throws {
        try write(image, root: try requireOutputDir(), section: section, title: title, note: note)
    }

    // MARK: - 애니메이션 (GIF)

    /// 뷰를 창에 올린 뒤 시간을 흘리며 연속 캡처해 GIF로 저장한다.
    ///
    /// 정지 컷으로는 애니메이션의 실패가 안 보인다 — 프레임 순서가 뒤집혔는지, 중간에 튀는지,
    /// 반복 이음매가 끊기는지는 움직여봐야 안다. 앱에서 그 확인은 창을 띄우고 타이밍을 기다리는
    /// 일이라 반복이 비싸다.
    ///
    /// 캡처가 실제 애니메이션을 잡는 이유는 창이 살아 있기 때문이다. `TimelineView(.animation)`,
    /// `withAnimation`, `Task.sleep`으로 도는 재생 루프가 전부 RunLoop을 타므로, 프레임 간격만큼
    /// 런루프를 돌려주면 앱에서와 같은 속도로 진행한다.
    ///
    /// GIF를 쓰는 건 도트 그래픽과 잘 맞아서다(256색 팔레트가 제약이 아니라 정확). 갤러리의
    /// `<img>`가 그대로 재생하므로 별도 플레이어가 필요 없다.
    @discardableResult
    static func renderAnimated(_ view: some View,
                               size: CGSize,
                               frameCount: Int,
                               frameInterval: TimeInterval,
                               section: String,
                               title: String,
                               note: String? = nil,
                               warmup: TimeInterval = 0.1,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws -> Int {
        let root = try requireOutputDir()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        host.layoutSubtreeIfNeeded()
        // onAppear에서 시작하는 재생 루프(배틀 등)가 첫 프레임을 잡기 전에 캡처하지 않도록.
        RunLoop.current.run(until: Date().addingTimeInterval(warmup))

        var frames: [NSImage] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            host.displayIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let img = NSImage(size: size)
                img.addRepresentation(rep)
                frames.append(img)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(frameInterval))
        }
        guard !frames.isEmpty else {
            XCTFail("애니메이션 캡처 실패: \(section)/\(title)", file: file, line: line)
            return 0
        }
        try writeGIF(frames, frameDelay: frameInterval, root: root,
                     section: section, title: title, note: note, size: size)
        return frames.count
    }

    /// 이미 만들어둔 프레임 배열을 GIF로 등록한다. 스프라이트처럼 그림이 이미 프레임 단위로
    /// 존재하는 경우 — 창을 띄울 필요 없이 앱과 같은 프레임 간격으로 이어 붙이면 된다.
    static func writeAnimation(_ frames: [NSImage],
                               frameDelay: TimeInterval,
                               section: String,
                               title: String,
                               note: String? = nil) throws {
        guard let first = frames.first else { return }
        try writeGIF(frames, frameDelay: frameDelay, root: try requireOutputDir(),
                     section: section, title: title, note: note, size: first.size)
    }

    private static func writeGIF(_ frames: [NSImage],
                                 frameDelay: TimeInterval,
                                 root: URL,
                                 section: String,
                                 title: String,
                                 note: String?,
                                 size: CGSize) throws {
        let dir = root.appendingPathComponent(slug(section), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(slug(title)).gif"
        let url = dir.appendingPathComponent(filename)

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw NSError(domain: "PreviewRenderer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "GIF destination 생성 실패"])
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],   // 0 = 무한 반복
        ] as CFDictionary)
        for frame in frames {
            guard let cg = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
                                                kCGImagePropertyGIFDelayTime: frameDelay],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "PreviewRenderer", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "GIF 인코딩 실패: \(section)/\(title)"])
        }
        record(section: section, title: title, note: note, path: "\(slug(section))/\(filename)",
               size: size, animated: true, frames: frames.count, root: root)
    }

    private static func write(_ image: NSImage, root: URL, section: String, title: String, note: String?) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PreviewRenderer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "PNG 변환 실패: \(section)/\(title)"])
        }
        let dir = root.appendingPathComponent(slug(section), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = "\(slug(title)).png"
        try png.write(to: dir.appendingPathComponent(filename))
        record(section: section, title: title, note: note, path: "\(slug(section))/\(filename)",
               size: image.size, animated: false, frames: 1, root: root)
    }

    /// 갤러리 생성 스크립트가 읽는 매니페스트. 테스트 실행 순서가 보장되지 않으므로 append만 하고
    /// 정렬은 스크립트가 한다. 실행 전 출력 디렉토리를 비우는 것도 스크립트 담당.
    private static func record(section: String, title: String, note: String?, path: String,
                               size: CGSize, animated: Bool, frames: Int, root: URL) {
        let entry: [String: Any] = [
            "section": section,
            "title": title,
            "note": note ?? "",
            "path": path,
            "width": Int(size.width),
            "height": Int(size.height),
            "animated": animated,
            "frames": frames,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        appendLine(data, to: root.appendingPathComponent("manifest.jsonl"))
    }

    private static func appendLine(_ data: Data, to url: URL) {
        var line = data
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    private static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(mapped).replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: - 컨택트 시트

    /// NSImage 여러 장을 라벨과 함께 격자로 합성한다. 스프라이트처럼 "많고 작은" 것은
    /// SwiftUI 레이아웃보다 직접 그리는 쪽이 셀 크기를 정확히 통제할 수 있다.
    ///
    /// 배경은 반투명 체커보드 — 스프라이트의 투명 영역과 흰/검 픽셀을 구분하기 위한 것이다.
    /// 단색 배경에서는 "테두리가 잘렸는지"와 "원래 투명한지"가 같아 보인다.
    static func contactSheet(rows: [(label: String, images: [NSImage])],
                             cell: CGSize,
                             padding: CGFloat = 8,
                             labelWidth: CGFloat = 150) -> NSImage {
        let maxCols = rows.map(\.images.count).max() ?? 0
        let rowHeight = cell.height + padding * 2
        let width = labelWidth + CGFloat(maxCols) * (cell.width + padding) + padding
        let height = CGFloat(rows.count) * rowHeight + padding
        let canvas = NSImage(size: CGSize(width: max(width, labelWidth + 40), height: max(height, 40)))

        canvas.lockFocus()
        defer { canvas.unlockFocus() }

        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()

        for (i, row) in rows.enumerated() {
            let y = canvas.size.height - CGFloat(i + 1) * rowHeight
            drawChecker(in: NSRect(x: labelWidth, y: y,
                                   width: canvas.size.width - labelWidth - padding, height: rowHeight))
            (row.label as NSString).draw(
                at: NSPoint(x: padding, y: y + rowHeight / 2 - 7),
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white,
                ])
            for (j, img) in row.images.enumerated() {
                let x = labelWidth + CGFloat(j) * (cell.width + padding)
                // 셀 안에서 원본 비율 유지 + 중앙 정렬. 스프라이트를 늘리면 도트가 뭉개진다.
                let scale = min(cell.width / max(img.size.width, 1), cell.height / max(img.size.height, 1), 3)
                let w = img.size.width * scale, h = img.size.height * scale
                NSGraphicsContext.current?.imageInterpolation = .none   // 도트는 nearest neighbor
                img.draw(in: NSRect(x: x + (cell.width - w) / 2,
                                    y: y + padding + (cell.height - h) / 2,
                                    width: w, height: h))
            }
        }
        return canvas
    }

    private static func drawChecker(in rect: NSRect, size: CGFloat = 8) {
        NSColor(calibratedWhite: 0.22, alpha: 1).setFill()
        rect.fill()
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        var y = rect.minY
        var rowIndex = 0
        while y < rect.maxY {
            var x = rect.minX + (rowIndex.isMultiple(of: 2) ? 0 : size)
            while x < rect.maxX {
                NSRect(x: x, y: y, width: min(size, rect.maxX - x), height: min(size, rect.maxY - y)).fill()
                x += size * 2
            }
            y += size
            rowIndex += 1
        }
    }
}
