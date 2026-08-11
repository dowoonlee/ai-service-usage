import AppKit
import CryptoKit

/// 길드 로고 — 66×44(3:2) 도트 이미지. 국기에서 가장 흔한 비율을 따랐다
/// (태극기·일장기·삼색기 등 = 세로:가로 2:3).
///
/// 저장 형태는 `guilds.logo` text 한 컬럼에 두 가지를 접두사로 구분해 담는다
/// (`office_furniture`가 레이아웃 문자열을 담는 것과 같은 방식):
///   - `"s:<0..9>"`  샘플 로고 — 그림 파일 없이 `sampleImage(_:)`가 절차적으로 그린다.
///   - `"p:<base64>"` 커스텀 로고 — 사용자가 올린 이미지를 66×44로 픽셀화한 PNG.
///
/// 샘플을 인덱스로만 저장하는 이유: 길드 대부분이 기본 로고를 쓰는데 그때마다 2KB짜리
/// base64를 DB·응답·HMAC canonical에 실어 나를 이유가 없다. 해상도를 바꿔도 즉시 재생성된다.
enum GuildLogo {
    /// 로고 픽셀 해상도. 3:2 고정 — 크롭 UI와 표시 뷰가 이 값에서 비율을 파생한다.
    static let pixelWidth = 66
    static let pixelHeight = 44
    static let sampleCount = 10
    /// 문양이 차지하는 반경 비율(캔버스 높이 기준). 값을 키우면 문양이 커지고 여백이 준다.
    private static let symbolScale = 0.38

    /// 커스텀 PNG 원본 바이트 상한. 66×44면 실측 1~3KB라 8KB면 충분히 여유롭다.
    /// 서버(`guild_policy.ts`)의 상한과 반드시 같이 움직여야 한다.
    static let maxCustomBytes = 8 * 1024

    enum Value: Equatable {
        case sample(Int)
        case custom(Data)
    }

    // MARK: - 저장 값 파싱/직렬화

    /// 저장 문자열 → 값. 값이 없거나 깨졌으면 길드 id 해시로 결정론적 샘플을 고른다
    /// (서버가 배정에 실패했거나 구버전 응답이어도 길드마다 일관된 로고가 나오도록).
    static func parse(_ raw: String?, guildID: String) -> Value {
        guard let raw, !raw.isEmpty else { return .sample(fallbackIndex(for: guildID)) }
        if raw.hasPrefix("s:") {
            let n = Int(raw.dropFirst(2)) ?? -1
            return .sample((0..<sampleCount).contains(n) ? n : fallbackIndex(for: guildID))
        }
        if raw.hasPrefix("p:"), let data = Data(base64Encoded: String(raw.dropFirst(2))) {
            return .custom(data)
        }
        return .sample(fallbackIndex(for: guildID))
    }

    static func encode(sample index: Int) -> String { "s:\(index)" }
    static func encode(customPNG data: Data) -> String { "p:\(data.base64EncodedString())" }

    /// 길드 id → 0..<10. SHA256 앞 8바이트를 쓰는 이유는 `hashValue`가 실행마다 달라져
    /// 같은 길드가 실행할 때마다 다른 로고로 보이는 것을 막기 위함.
    static func fallbackIndex(for guildID: String) -> Int {
        let digest = SHA256.hash(data: Data(guildID.utf8))
        let n = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Int(n % UInt64(sampleCount))
    }

    // MARK: - 렌더

    @MainActor private static var cache: [String: NSImage] = [:]

    /// 저장 값 → 표시용 이미지. 결과는 캐시된다(리더보드 행마다 재생성되지 않도록).
    @MainActor
    static func image(for raw: String?, guildID: String) -> NSImage {
        let value = parse(raw, guildID: guildID)
        let key: String
        switch value {
        case .sample(let i): key = "s:\(i)"
        case .custom(let d): key = "p:\(d.count):\(d.prefix(16).map { String($0, radix: 16) }.joined())"
        }
        if let hit = cache[key] { return hit }
        let img: NSImage
        switch value {
        case .sample(let i):  img = sampleImage(i)
        case .custom(let d):  img = NSImage(data: d) ?? sampleImage(fallbackIndex(for: guildID))
        }
        cache[key] = img
        return img
    }

    // MARK: - 샘플 로고 (절차적)

    /// 10종 팔레트. (배경, 배경 밴드, 문양, 문양 그림자) — 모두 0xAARRGGBB.
    /// 도트 팔레트라 채도를 높게 잡고 문양/배경 명도차를 크게 뒀다 — 리더보드 행처럼
    /// 20pt 남짓으로 줄어들 때도 형체가 남아야 한다. band는 bg보다 한 톤만 밝게.
    private static let palettes: [(bg: UInt32, band: UInt32, fg: UInt32, shade: UInt32)] = [
        (0xFF2B3A67, 0xFF334480, 0xFFF2C14E, 0xFFB88A2A),  // 0 방패 — 감청 + 금
        (0xFF7A1F2B, 0xFF902836, 0xFFF5E6D3, 0xFFC7B098),  // 1 검 — 버건디 + 상아
        (0xFF14403A, 0xFF1B524A, 0xFF4FD1A5, 0xFF2E8F72),  // 2 톱니 — 딥틸 + 민트
        (0xFF3A2A5E, 0xFF473472, 0xFFC792EA, 0xFF8B63A8),  // 3 별 — 보라 + 라벤더
        (0xFF6B3410, 0xFF804015, 0xFFFFB454, 0xFFC77F2E),  // 4 불꽃 — 적갈 + 주황
        (0xFF102A43, 0xFF163756, 0xFF62B6FF, 0xFF3B7FB8),  // 5 물결 — 남색 + 하늘
        (0xFF1F3D1A, 0xFF2A4F23, 0xFF9CCC65, 0xFF6B9440),  // 6 산 — 짙은 녹 + 연두
        (0xFF4A1E3D, 0xFF5C264C, 0xFFFF7EB6, 0xFFC25288),  // 7 왕관 — 자주 + 핑크
        (0xFF2E2E38, 0xFF3A3A46, 0xFFE0E0E8, 0xFF9A9AA8),  // 8 번개 — 차콜 + 실버
        (0xFF0F3B4C, 0xFF154C61, 0xFF40E0D0, 0xFF23968C),  // 9 육각 — 청록 + 터콰이즈
    ]

    /// 샘플 로고 한 장을 즉석에서 그린다. 파일 리소스 없음.
    static func sampleImage(_ index: Int) -> NSImage {
        let i = max(0, min(sampleCount - 1, index))
        let p = palettes[i]
        let w = pixelWidth, h = pixelHeight
        var px = [UInt32](repeating: p.bg, count: w * h)

        // 배경 — 좌상단에서 우하단으로 흐르는 대각 밴드. 단색이면 심심하고,
        // 그라데이션은 도트 느낌을 죽여서 2톤 밴드로만 변화를 준다.
        for y in 0..<h {
            for x in 0..<w where ((x + y * 2) / 7) % 2 == 0 {
                px[y * w + x] = p.band
            }
        }

        // 문양 — 정규화 좌표로 판정해 계단(에일리어싱)이 그대로 도트가 되게 둔다.
        let cx = Double(w) / 2, cy = Double(h) / 2
        for y in 0..<h {
            for x in 0..<w {
                // 문양 영역을 세로 기준으로 정규화 (가로로 늘어나지 않게).
                // 0.38 = 문양 지름이 캔버스 높이의 76% — 나머지 24%는 상하 여백이다.
                // 국기가 문장 주위에 여백을 두는 것과 같은 이유로, 꽉 채우면 답답해 보인다.
                let u = (Double(x) + 0.5 - cx) / (Double(h) * symbolScale)
                let v = (Double(y) + 0.5 - cy) / (Double(h) * symbolScale)
                guard symbol(i, u, v) else { continue }
                // 아래쪽 1px은 그림자 톤 — 평면 문양에 최소한의 입체감만.
                let below = symbol(i, u, v + 1.0 / (Double(h) * symbolScale))
                px[y * w + x] = below ? p.fg : p.shade
            }
        }

        // 테두리 1px — 밝은 배경 위에 올려도 로고 경계가 살아있도록.
        for x in 0..<w { px[x] = darken(px[x]); px[(h - 1) * w + x] = darken(px[(h - 1) * w + x]) }
        for y in 0..<h { px[y * w] = darken(px[y * w]); px[y * w + w - 1] = darken(px[y * w + w - 1]) }

        return image(fromBGRA: px, width: w, height: h) ?? NSImage(size: .init(width: w, height: h))
    }

    /// 문양 판정 — (u,v)는 중심 원점, 반지름 1 남짓으로 정규화된 좌표.
    private static func symbol(_ kind: Int, _ u: Double, _ v: Double) -> Bool {
        switch kind {
        case 0:  // 방패 — 위는 사각, 아래는 뾰족하게 좁아짐
            guard abs(u) <= 1, v >= -1, v <= 1 else { return false }
            let halfWidth = v < 0.1 ? 1.0 : 1.0 - (v - 0.1) * 1.1
            return abs(u) <= halfWidth
        case 1:  // 검 한 자루 (날 + 가드 + 손잡이 + 폼멜)
            // 교차한 두 자루로 그리면 이 크기에서 그냥 X표로 읽혀서 한 자루로 세웠다.
            if v >= -0.95, v <= 0.42 {                        // 날 — 끝으로 갈수록 좁아짐
                let taper = v < -0.72 ? (v + 0.95) / 0.23 : 1.0
                return abs(u) <= 0.19 * taper
            }
            if v > 0.42, v <= 0.58 { return abs(u) <= 0.62 }  // 가드
            if v > 0.58, v <= 0.86 { return abs(u) <= 0.14 }  // 손잡이
            if v > 0.86, v <= 1.0 { return abs(u) <= 0.26 }   // 폼멜
            return false
        case 2:  // 톱니바퀴 — 링 + 방사형 이빨, 가운데 축 구멍
            let r = (u * u + v * v).squareRoot()
            let ang = atan2(v, u)
            let tooth = cos(ang * 8) > 0.35 ? 1.0 : 0.82
            return r <= tooth && r >= 0.34
        case 3:  // 5각별 — 꼭짓점 방향에서 반지름이 최대가 되도록
            let r = (u * u + v * v).squareRoot()
            guard r <= 1 else { return false }
            var ang = atan2(v, u) + .pi / 2                   // 꼭짓점 하나를 위로
            let k = 2 * Double.pi / 5
            ang = ang.truncatingRemainder(dividingBy: k)
            if ang < 0 { ang += k }
            let toSpike = abs(ang - k / 2) / (k / 2)          // 1=꼭짓점, 0=골
            return r <= 0.36 + 0.64 * toSpike * toSpike
        case 4:  // 불꽃 — 아래는 둥글게 부풀고 위로 갈수록 한쪽으로 휘며 뾰족해짐
            guard v >= -1, v <= 0.92 else { return false }
            let t = (v + 1) / 1.92                    // 0(끝)~1(밑동)
            let sway = (1 - t) * (1 - t) * 0.42       // 위쪽만 휘게 — 기둥으로 안 보이도록
            let width = 0.06 + pow(t, 1.6) * 0.78
            guard abs(u - sway) <= width else { return false }
            // 밑동을 둥글게 깎아 촛불 심지 같은 직각 밑변을 없앤다.
            if v > 0.5 { return (u * u) / 0.62 + ((v - 0.34) * (v - 0.34)) / 0.34 <= 1 }
            return true
        case 5:  // 물결 3줄
            guard abs(u) <= 1 else { return false }
            let wave = sin(u * 3.4) * 0.26
            return [(-0.52), 0.0, 0.52].contains { abs(v - wave - $0) < 0.15 }
        case 6:  // 산봉우리 두 개
            guard v <= 0.86, v >= -1 else { return false }
            let peak1 = 1.0 - abs(u + 0.34) * 2.6
            let peak2 = 0.72 - abs(u - 0.42) * 2.6
            return v >= -max(peak1, peak2)
        case 7:  // 왕관 — 삼각 3개 + 받침
            guard abs(u) <= 0.95 else { return false }
            if v > 0.42 && v <= 0.86 { return true }                       // 받침
            guard v <= 0.42, v >= -0.9 else { return false }
            let spikes = [(-0.62, 0.62), (0.0, 0.9), (0.62, 0.62)]         // (중심, 높이)
            return spikes.contains { abs(u - $0.0) <= ($0.1 + v) * 0.5 && v >= -$0.1 }
        case 8:  // 번개
            guard abs(v) <= 1 else { return false }
            let shift = v < 0 ? 0.3 : -0.3
            return abs(u + shift + v * 0.55) <= 0.3 - abs(v) * 0.08
        default: // 9 육각형 링
            let q = abs(u), r = abs(v)
            let outer = q * 0.866 + r * 0.5 <= 0.92 && r <= 0.8
            let inner = q * 0.866 + r * 0.5 <= 0.58 && r <= 0.5
            return outer && !inner
        }
    }

    // MARK: - 업로드 이미지 → 픽셀 로고

    /// 크롭 영역을 66×44로 축소해 PNG로 굽는다.
    ///
    /// - Parameters:
    ///   - image: 사용자가 고른 원본
    ///   - crop: 원본 픽셀 좌표계의 3:2 영역 (좌상단 기준, `CropBox`가 만들어 준다)
    ///
    /// 축소는 `.high` 보간(영역 평균)으로 한 번에 내린다. nearest로 내리면 원본의 특정
    /// 1픽셀만 뽑혀 색이 튀고, 축소 후 확대 표시할 때 비로소 nearest를 써야 도트가 각진다.
    static func pixelate(_ image: NSImage, crop: CGRect) -> Data? {
        guard let src = cgImage(from: image) else { return nil }
        let clamped = crop.intersection(CGRect(x: 0, y: 0, width: src.width, height: src.height))
        guard clamped.width >= 1, clamped.height >= 1,
              let cropped = src.cropping(to: clamped) else { return nil }

        let w = pixelWidth, h = pixelHeight
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = NSSize(width: w, height: h)
        return rep.representation(using: .png, properties: [:])
    }

    /// 픽셀화 결과를 확대 미리보기용 NSImage로. 확대는 nearest — 도트 경계를 살린다.
    static func previewImage(fromPNG data: Data) -> NSImage? { NSImage(data: data) }

    // MARK: - 저수준 헬퍼

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func image(fromBGRA px: [UInt32], width: Int, height: Int) -> NSImage? {
        var buf = px
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = buf.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: cs, bitmapInfo: info)
        }), let cg = ctx.makeImage() else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
        return img
    }

    private static func darken(_ c: UInt32) -> UInt32 {
        var out: UInt32 = 0xFF000000
        for shift in stride(from: 16, through: 0, by: -8) {
            let v = UInt32(Double((c >> UInt32(shift)) & 0xFF) * 0.55)
            out |= v << UInt32(shift)
        }
        return out
    }
}
